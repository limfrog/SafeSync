import Foundation
import SafeSyncCore

private actor FolderWire {
    var posts: [URLRequest] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func request(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let data: Data
        if request.httpMethod == "POST" {
            posts.append(request)
            if fail { throw URLError(.notConnectedToInternet) }
            let body = try HTTP.object(request.httpBody!)
            data = try HTTP.json(["id": "created-folder", "name": body["name"]!, "parents": body["parents"]!, "mimeType": body["mimeType"]!, "version": "1"])
        } else { data = try HTTP.json(["files": []]) }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func requests() -> [URLRequest] { posts }
}

struct FolderCreationChecks {
    static func run() async throws {
        for provider in CloudProvider.allCases {
            let cloud = MemoryCloud(provider), root = provider == .googleDrive ? "root" : ""
            let folder = try await CloudFolderCreation.create(name: "  새 백업 폴더  ", parent: root, storage: cloud)
            check(folder.folder); checkEqual(folder.name, "새 백업 폴더"); checkEqual(folder.parent, root)
            let child = try await CloudFolderCreation.create(name: "하위 폴더", parent: folder.locator, storage: cloud)
            checkEqual(child.parent, folder.locator)
            do { _ = try await CloudFolderCreation.create(name: "새 백업 폴더", parent: root, storage: cloud); fail("Duplicate folder must be rejected") } catch { }
            checkEqual(await cloud.children(root).count, 1)
        }
        print("PASS cloud folder creation uses current parent, trims Korean names and rejects duplicate folders")

        do {
            for name in ["", "  ", ".", "..", "a/b", "a\\b", "a\u{0}b", ".SafeSync-staging"] {
                do { _ = try CloudFolderCreation.validatedName(name); fail("Unsafe folder name accepted") } catch { }
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-folder-check-\(UUID())")
            try Data("test".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
            for provider in CloudProvider.allCases {
                let cloud = MemoryCloud(provider), root = provider == .googleDrive ? "root" : ""
                _ = try await cloud.upload(file: file, name: "existing", parent: root, modified: Date(), resumeKey: "test")
                do { _ = try await CloudFolderCreation.create(name: "existing", parent: root, storage: cloud); fail("Duplicate file name must be rejected") } catch { }
                checkEqual(await cloud.children(root).count, 1)
            }
            print("PASS unsafe/reserved folder names and collisions with existing files are rejected")
        }
        do {
            let account = CloudAccount(provider: .googleDrive, name: "test", clientID: "test")
            let wire = FolderWire()
            let storage = GoogleDriveStorage(account: account, transport: { request, _ in try await wire.request(request) })
            let folder = try await CloudFolderCreation.create(name: "실제 요청 검사", parent: "chosen-parent-id", storage: storage)
            checkEqual(folder.id, "created-folder"); checkEqual(folder.parent, "chosen-parent-id"); check(folder.folder)
            let requests = await wire.requests(); checkEqual(requests.count, 1)
            let body = try HTTP.object(requests[0].httpBody!)
            checkEqual(body["parents"] as? [String], ["chosen-parent-id"])
            checkEqual(body["mimeType"] as? String, "application/vnd.google-apps.folder")
            checkEqual(body["name"] as? String, "실제 요청 검사")
            checkEqual(requests[0].url?.path, "/drive/v3/files")
            print("PASS Google Drive adapter sends folder MIME type and selected parent and returns selectable folder ID (mock HTTP)")
        }
        do {
            let account = CloudAccount(provider: .googleDrive, name: "test", clientID: "test"), wire = FolderWire(fail: true)
            let storage = GoogleDriveStorage(account: account, transport: { request, _ in try await wire.request(request) })
            do { _ = try await CloudFolderCreation.create(name: "new", parent: "parent", storage: storage); fail("Creation failure must propagate") }
            catch let error as URLError { checkEqual(error.code, .notConnectedToInternet) }
            checkEqual(await wire.requests().count, 1)
            print("PASS folder creation failure surfaces to picker without automatically repeating the mutation")
        }
        print("4 folder creation checks passed")
    }
}
