import XCTest
@testable import SafeSyncCore

final class GoogleTrashTests: XCTestCase {
    func testArchiveDisposalUsesTrashWhileTemporaryCleanupKeepsDelete() async throws {
        let calls = Calls(); let account = CloudAccount(provider:.googleDrive,name:"test",clientID:"client")
        let storage = GoogleDriveStorage(account:account,transport: { request,_ in
            await calls.append(request.httpMethod ?? "")
            XCTAssertEqual(request.url!.path,"/drive/v3/files/archive")
            if request.httpMethod == "PATCH" {
                let body = try HTTP.object(request.httpBody!)
                XCTAssertEqual(body["trashed"] as? Bool,true)
                let query = Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value ?? "")})
                XCTAssertEqual(query["supportsAllDrives"],"true")
                return (try HTTP.json(["id":"archive","trashed":true]),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }
            return (Data(),HTTPURLResponse(url:request.url!,statusCode:204,httpVersion:nil,headerFields:nil)!)
        })
        let item = RemoteItem(id:"archive",name:"batch",parent:"trash",folder:true)
        try await storage.discardTrash(item)
        try await storage.remove(item)
        let recorded = await calls.values; XCTAssertEqual(recorded,["PATCH","DELETE"])
    }
    func testUnconfirmedTrashCannotFallBackToPermanentDeletion() async throws {
        for result in [["id":"archive","trashed":false],["id":"wrong","trashed":true]] as [[String:Any]] {
            let calls = Calls(), response = try HTTP.json(result)
            let storage = GoogleDriveStorage(account:CloudAccount(provider:.googleDrive,name:"test",clientID:"client"),transport: { request,_ in
                await calls.append(request.httpMethod ?? "")
                return (response,HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
            do { try await storage.discardTrash(RemoteItem(id:"archive",name:"batch",parent:"trash",folder:true));XCTFail("Unconfirmed trash succeeded") } catch { }
            let recorded = await calls.values;XCTAssertEqual(recorded,["PATCH"])
        }
    }
    func testRejectedTrashCannotFallBackToPermanentDeletion() async throws {
        let calls = Calls()
        let storage = GoogleDriveStorage(account:CloudAccount(provider:.googleDrive,name:"test",clientID:"client"),transport: { request,_ in
            await calls.append(request.httpMethod ?? "")
            throw APIError(status:403,summary:"forbidden")
        })
        do { try await storage.discardTrash(RemoteItem(id:"archive",name:"batch",parent:"trash",folder:true));XCTFail("Forbidden trash succeeded") } catch { }
        let recorded = await calls.values;XCTAssertEqual(recorded,["PATCH"])
    }
    actor Calls { var values:[String] = [];func append(_ value:String){values.append(value)} }
}
