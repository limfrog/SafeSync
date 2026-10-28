import XCTest
@testable import SafeSyncCore

final class GoogleModifiedTimeTests: XCTestCase {
    func testMovingAndRenamingPreserveSourceTimeInsteadOfServerTime() async throws {
        let original = Date(timeIntervalSince1970: 1000.123)
        for parent in ["staging", "destination", "archive"] {
            let storage = GoogleDriveStorage(account: CloudAccount(provider: .googleDrive, name: "fixture", clientID: "fixture"), transport: { request, _ in
                XCTAssertEqual(request.httpMethod, "PATCH")
                let body = try HTTP.object(request.httpBody!)
                // Model Drive's metadata update: omitted modifiedTime becomes server time.
                let modified = body["modifiedTime"] as? String ?? HTTP.dateString(Date(timeIntervalSince1970: 9000), fractional: true)
                return (try HTTP.json(["id":"file", "name":body["name"]!, "parents":[parent], "size":"3", "modifiedTime":modified, "version":"2", "md5Checksum":"abc"]), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
            let moved = try await storage.move(RemoteItem(id:"file",name:"temporary",parent:"staging",size:3,modified:original,hash:"abc",hashKind:"md5"),name:"final.txt",parent:parent)
            XCTAssertEqual(moved.modified.timeIntervalSince1970, original.timeIntervalSince1970, accuracy:0.001)
            XCTAssertLessThan(moved.modified, Date(timeIntervalSince1970:2000))
        }
    }
}
