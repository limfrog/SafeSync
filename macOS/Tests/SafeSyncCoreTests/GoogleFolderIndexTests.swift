import XCTest
@testable import SafeSyncCore

final class GoogleFolderIndexTests: XCTestCase {
    func testWarmPathAndOverlappingReadsReduceRoundTrips() async throws {
        let drive = Drive(), storage = storage(Drive())
        // Each store owns its cache; another account/store must not inherit IDs.
        let isolated = try await storage.folder(path: "a/b/c/d", root: "managed")
        XCTAssertEqual(isolated, "d")
        let google = self.storage(drive)
        let initial = try await google.folder(path: "a/b/c/d", root: "managed")
        let baseline = await drive.requests
        XCTAssertEqual(initial, "d"); XCTAssertEqual(baseline, 4)
        let warm = try await google.folder(path: "a/b/c/d", root: "managed")
        let after = await drive.requests
        XCTAssertEqual(warm, "d"); XCTAssertEqual(after - baseline, 1)
        await drive.setDelay(true)
        let before = await drive.requests
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await google.folder(path: "a/b/c/d", root: "managed") } }
            var values: [String] = []; for try await value in group { values.append(value) }; return values
        }
        let count = await drive.requests
        XCTAssertEqual(values, Array(repeating: "d", count: 8)); XCTAssertEqual(count - before, 1)
        let leafBefore = await drive.requests
        _ = try await withThrowingTaskGroup(of: [RemoteItem].self) { group in
            for _ in 0..<8 { group.addTask { try await google.children("d") } }
            for try await _ in group { }; return true
        }
        let leafAfter = await drive.requests
        XCTAssertEqual(leafAfter - leafBefore, 1)
        await drive.setDelay(false)
        await drive.add(RemoteItem(id: "fresh", name: "new.txt", parent: "d"))
        let fresh = try await google.children("d")
        XCTAssertTrue(fresh.contains(where: { $0.id == "fresh" }))
    }
    func testMovedFolderAndNewDuplicateCannotAuthorizeCachedMutation() async throws {
        let drive = Drive(), google = storage(drive)
        _ = try await google.folder(path: "a/b/c/d", root: "managed")
        await drive.add(RemoteItem(id: "duplicate", name: "c", parent: "b", folder: true))
        do { _ = try await google.folder(path: "a/b/c/d", root: "managed"); XCTFail("A new duplicate ancestor authorized a cached path") } catch { }
        await drive.remove("duplicate")
        _ = try await google.folder(path: "a/b/c/d", root: "managed")
        await drive.setPagination(true)
        await drive.add(RemoteItem(id: "late", name: "c", parent: "b", folder: true))
        do { _ = try await google.folder(path: "a/b/c/d", root: "managed"); XCTFail("A later-page duplicate was ignored") } catch { }
        let pages = await drive.secondPages
        XCTAssertGreaterThan(pages, 0)
        await drive.setPagination(false); await drive.remove("late")
        _ = try await google.folder(path: "a/b/c/d", root: "managed")
        await drive.add(RemoteItem(id: "d", name: "d", parent: "outside", folder: true))
        let replacement = try await google.folder(path: "a/b/c/d", root: "managed")
        XCTAssertNotEqual(replacement, "d")
        let node = await drive.node(replacement)
        XCTAssertEqual(node?.parent, "c")
        let outsideWrites = await drive.outsideWrites
        XCTAssertEqual(outsideWrites, 0)
    }
    func testFailuresIncompleteBatchesAndCancellationDoNotPoisonReads() async throws {
        let drive = Drive(), google = storage(drive)
        _ = try await google.folder(path: "a/b/c/d", root: "managed")
        await drive.setFailure(true)
        do { _ = try await google.folder(path: "a/b/c/d", root: "managed"); XCTFail("403 became missing") }
        catch let error as APIError { XCTAssertEqual(error.status, 403) }
        await drive.setFailure(false); await drive.setOmit(true)
        do { _ = try await google.folder(path: "a/b/c/d", root: "managed"); XCTFail("An incomplete batch authorized a write") } catch { }
        await drive.setOmit(false); await drive.setDelay(true)
        let canceled = Task { try await google.folder(path: "a/b/c/d", root: "managed") }
        try await Task.sleep(nanoseconds: 5_000_000); canceled.cancel()
        do { _ = try await canceled.value; XCTFail("Cancellation was lost") } catch is CancellationError { }
        await drive.setDelay(false)
        let recovered = try await google.folder(path: "a/b/c/d", root: "managed")
        XCTAssertEqual(recovered, "d")
        let writes = await drive.creates
        XCTAssertEqual(writes, 0)
    }
    func testSeededCatalogAndConcurrentSiblingCreation() async throws {
        let drive = Drive(), google = storage(drive)
        let index = await drive.index()
        try await google.folderIndex.seed(index)
        let folder = try await google.folder(path: "a/b/c/d", root: "managed")
        let requests = await drive.requests
        XCTAssertEqual(folder, "d"); XCTAssertEqual(requests, 1)
        await drive.setDelay(true)
        async let left = google.folder(path: "new/x", root: "managed")
        async let right = google.folder(path: "new/y", root: "managed")
        _ = try await (left, right)
        let nodes = await drive.index(), creates = await drive.creates
        XCTAssertEqual(nodes.nodes.values.filter { $0.parent == "managed" && $0.name == "new" }.count, 1)
        XCTAssertEqual(creates, 3)
    }
    private func storage(_ drive: Drive) -> GoogleDriveStorage {
        GoogleDriveStorage(account: CloudAccount(provider: .googleDrive, name: "synthetic", clientID: "test"), transport: { request, _ in try await drive.handle(request) })
    }
    private actor Drive {
        var nodes: [String: RemoteItem] = [:]
        var requests = 0, creates = 0, secondPages = 0, outsideWrites = 0
        var delay = false, fail = false, omit = false, paginate = false
        init() {
            nodes["managed"] = RemoteItem(id: "managed", name: "Backup", parent: "", folder: true)
            var parent = "managed"
            for name in ["a", "b", "c", "d"] { nodes[name] = RemoteItem(id: name, name: name, parent: parent, folder: true); parent = name }
        }
        func add(_ node: RemoteItem) { nodes[node.id] = node }
        func remove(_ id: String) { nodes.removeValue(forKey: id) }
        func node(_ id: String) -> RemoteItem? { nodes[id] }
        func setDelay(_ value: Bool) { delay = value }
        func setFailure(_ value: Bool) { fail = value }
        func setOmit(_ value: Bool) { omit = value }
        func setPagination(_ value: Bool) { paginate = value }
        func index() -> RemoteIndex { var index = RemoteIndex(); index.root = "managed"; index.nodes = nodes.filter { $0.key != "managed" }; return index }
        private func json(_ item: RemoteItem) -> [String: Any] {
            ["id": item.id, "name": item.name, "parents": [item.parent], "mimeType": item.folder ? "application/vnd.google-apps.folder" : "application/octet-stream", "trashed": false]
        }
        private func read(_ url: URL) -> (Int, [String: Any]) {
            if url.path == "/drive/v3/files" {
                let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
                let parent = query["q"]!.split(separator: "'")[0]
                let matches = nodes.values.filter { $0.parent == parent }
                if paginate && parent == "b" {
                    if query["pageToken"] != nil { secondPages += 1; return (200, ["files": matches.filter { $0.id == "late" }.map(json)]) }
                    return (200, ["files": matches.filter { $0.id != "late" }.map(json), "nextPageToken": "second"])
                }
                return (200, ["files": matches.map(json)])
            }
            return nodes[url.lastPathComponent].map { (200, json($0)) } ?? (404, [:])
        }
        func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests += 1
            if delay { try await Task.sleep(nanoseconds: 35_000_000) }
            let url = request.url!
            if url.path == "/batch/drive/v3" {
                let text = String(data: request.httpBody!, encoding: .utf8)!
                let pattern = try NSRegularExpression(pattern: "GET ([^\\r\\n]+) HTTP/1.1")
                let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                var output = ""
                for (index, match) in matches.enumerated() {
                    if omit && index == matches.count - 1 { continue }
                    let path = String(text[Range(match.range(at: 1), in: text)!])
                    let (status, object) = read(URL(string: "https://www.googleapis.com" + path)!)
                    let body = String(data: try HTTP.json(object), encoding: .utf8)!
                    output += "--reply\r\nContent-Type: application/http\r\nContent-ID: <response-\(index)>\r\n\r\nHTTP/1.1 \(fail && index == 1 ? 403 : status) response\r\nContent-Type: application/json\r\n\r\n\(body)\r\n"
                }
                output += "--reply--\r\n"
                return (Data(output.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "multipart/mixed; boundary=reply"])!)
            }
            if request.httpMethod == "POST" {
                let body = try HTTP.object(request.httpBody!), parent = (body["parents"] as! [String])[0]
                creates += 1; if parent == "outside" || parent == "d" && nodes["d"]?.parent == "outside" { outsideWrites += 1 }
                let node = RemoteItem(id: "created-\(creates)", name: body["name"] as! String, parent: parent, folder: true)
                nodes[node.id] = node
                return (try HTTP.json(json(node)), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let (status, object) = read(url)
            return (try HTTP.json(object), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
