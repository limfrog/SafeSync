import XCTest
@testable import SafeSyncCore

final class GoogleFileAccessTests: XCTestCase {
    func testScopeAndNativeFolderPicker() throws {
        let account = CloudAccount(provider: .googleDrive, name: "test", clientID: "client")
        let url = OAuthPKCE.authorizationURL(account: account, redirect: "http://127.0.0.1:12345/", pkce: try OAuthPKCE(), pickFolder: true)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["scope"], GoogleFileAccess.scope)
        XCTAssertEqual(query["include_granted_scopes"], "false")
        XCTAssertEqual(query["trigger_onepick"], "true")
        XCTAssertEqual(query["allow_folder_selection"], "true")
        for invalid in [nil, "", "https://www.googleapis.com/auth/drive", GoogleFileAccess.scope + " https://www.googleapis.com/auth/drive.readonly"] as [String?] {
            XCTAssertThrowsError(try GoogleFileAccess.validateScope(invalid))
        }
        XCTAssertNoThrow(try GoogleFileAccess.validateScope(GoogleFileAccess.scope))
    }
    func testLegacyAccountAndBaselineRequireExplicitMigration() throws {
        let data = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"provider\":\"googleDrive\",\"name\":\"old\",\"clientID\":\"client\"}".utf8)
        let legacy = try JSONDecoder().decode(CloudAccount.self, from: data)
        XCTAssertThrowsError(try GoogleFileAccess.validateAccount(legacy))
        var job = BackupJob(); job.cloudProvider = .googleDrive; job.cloudFolderID = "old"
        XCTAssertThrowsError(try GoogleFileAccess.validateJob(job))
        job.cloudAccessMode = GoogleFileAccess.mode
        XCTAssertNoThrow(try GoogleFileAccess.validateJob(job))
        job.syncMode = .twoWay
        XCTAssertThrowsError(try GoogleFileAccess.validateJob(job))
    }
    func testManagedFolderMarkerAndInaccessibleRoot() async throws {
        let account = CloudAccount(provider: .googleDrive, name: "test", clientID: "client")
        let storage = GoogleDriveStorage(account: account, transport: { request, _ in
            XCTAssertNotEqual(request.url!.path, "/drive/v3/files/root")
            let body = try HTTP.object(request.httpBody!)
            XCTAssertEqual((body["appProperties"] as? [String: String])?[GoogleFileAccess.folderKey], GoogleFileAccess.mode)
            let response: [String: Any] = ["id": "managed", "name": "Backup", "mimeType": "application/vnd.google-apps.folder", "parents": ["parent"], "appProperties": body["appProperties"]!]
            return (try HTTP.json(response), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let root = try await storage.metadata("root")
        XCTAssertEqual(root?.id, "root")
        let folder = try await storage.createFolder(name: "Backup", parent: "parent")
        XCTAssertEqual(folder.appAccessMode, GoogleFileAccess.mode)
    }
    func testExistingUnmanagedFolderCannotBecomeBackupRoot() async throws {
        let account = CloudAccount(provider: .googleDrive, name: "test", clientID: "client")
        let storage = GoogleDriveStorage(account: account, transport: { request, _ in
            XCTAssertEqual(request.httpMethod, "GET")
            return (try HTTP.json(["id": "old", "name": "Old Backup", "mimeType": "application/vnd.google-apps.folder"]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        var job = BackupJob(); job.cloudProvider = .googleDrive; job.cloudFolderID = "old"; job.cloudAccessMode = GoogleFileAccess.mode
        do { try await storage.validateJobAccess(job); XCTFail("An unmanaged folder received backup authority") } catch { }
    }
}
