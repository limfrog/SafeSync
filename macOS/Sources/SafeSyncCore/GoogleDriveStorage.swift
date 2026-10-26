import Foundation
import CryptoKit

public struct GoogleDriveStorage: RemoteStorage {
    public let provider = CloudProvider.googleDrive
    let account: CloudAccount
    let dataDirectory: URL
    public typealias Transport = @Sendable (URLRequest, Set<Int>) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport?
    let folderIndex = GoogleFolderIndex()
    let childReads = GoogleReadFlights<[RemoteItem]>()
    let folderReads = GoogleReadFlights<[Data?]>()
    let folderCreation = GoogleFolderCreationGate()
    private let fields = "id,name,parents,mimeType,size,modifiedTime,createdTime,md5Checksum,sha256Checksum,version,trashed,appProperties"
    public init(account: CloudAccount, dataDirectory: URL = Storage.applicationDirectory, transport: Transport? = nil) {
        self.account = account; self.dataDirectory = dataDirectory; self.transport = transport
    }
    func request(url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], accepted: Set<Int> = Set(200...299)) async throws -> (Data, HTTPURLResponse) {
        if let transport {
            var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = body
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            return try await transport(request, accepted)
        }
        return try await CloudAuthorization.shared.request(account, url: url, method: method, body: body, headers: headers, accepted: accepted)
    }
    func api(_ path: String, method: String = "GET", query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
        var q = query; q["supportsAllDrives"] = "true"
        let (data, _) = try await request(url: HTTP.url("https://www.googleapis.com/drive/v3/" + path, query: q), method: method, body: try body.map(HTTP.json), headers: ["Content-Type": "application/json"])
        return data.isEmpty ? [:] : try HTTP.object(data)
    }
    func parse(_ json: [String: Any]) throws -> RemoteItem {
        guard let id = json["id"] as? String, let name = json["name"] as? String else { throw BackupError.unsafe("Google Drive 파일 응답이 올바르지 않습니다.") }
        let sha = json["sha256Checksum"] as? String, md5 = json["md5Checksum"] as? String
        var item = RemoteItem(id: id, name: name, parent: (json["parents"] as? [String])?.first ?? "", folder: json["mimeType"] as? String == "application/vnd.google-apps.folder", size: Int64(json["size"] as? String ?? "0") ?? 0, modified: HTTP.date(json["modifiedTime"] as? String), hash: sha ?? md5, hashKind: sha != nil ? "sha256" : md5 != nil ? "md5" : nil, revision: json["version"] as? String ?? "", created: json["createdTime"] == nil ? nil : HTTP.date(json["createdTime"] as? String))
        item.appAccessMode = (json["appProperties"] as? [String: String])?[GoogleFileAccess.folderKey]
        return item
    }
    private func escaped(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") }
    public func children(_ parent: String) async throws -> [RemoteItem] {
        try await childReads.read(parent) { try await childrenCore(parent) }
    }
    func childrenCore(_ parent: String) async throws -> [RemoteItem] {
        var result: [RemoteItem] = [], next: String?
        repeat {
            var query = ["q": "'\(escaped(parent))' in parents and trashed = false", "fields": "nextPageToken,files(\(fields))", "pageSize": "1000", "includeItemsFromAllDrives": "true"]
            if let next { query["pageToken"] = next }
            let page = try await api("files", query: query)
            result += try (page["files"] as? [[String: Any]] ?? []).map(parse)
            next = page["nextPageToken"] as? String
        } while next != nil
        return result
    }
    public func metadata(_ id: String) async throws -> RemoteItem? {
        if id == "root" { return RemoteItem(id: "root", name: "내 드라이브 · 허용된 폴더", parent: "", folder: true) }
        do { let json = try await api("files/" + id, query: ["fields": fields]); return json["trashed"] as? Bool == true ? nil : try parse(json) }
        catch let error as APIError where error.status == 404 { return nil }
    }
    public func createFolder(name: String, parent: String) async throws -> RemoteItem {
        try parse(await api("files", method: "POST", query: ["fields": fields], body: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [parent], "appProperties": [GoogleFileAccess.folderKey: GoogleFileAccess.mode]]))
    }
    public func validateJobAccess(_ job: BackupJob) async throws {
        _ = try await validatedJobFolder(job)
    }
    func validatedJobFolder(_ job: BackupJob) async throws -> RemoteItem {
        try GoogleFileAccess.validateAccount(account); try GoogleFileAccess.validateJob(job)
        guard let id = job.cloudFolderID, id != "root", let folder = try await metadata(id), folder.folder, folder.appAccessMode == GoogleFileAccess.mode else {
            throw BackupError.unsafe("SafeSync 제한 권한으로 만든 전용 백업 폴더를 선택하세요. 이전 백업은 보존됩니다.")
        }
        return folder
    }
    private struct UploadSession: Codable { var url: String; var hash: String; var size: Int64; var modified: Date?; var parent: String? }
    public func upload(file: URL, name: String, parent: String, modified: Date, resumeKey: String, progress: @Sendable (Int64, Int64) -> Void) async throws -> RemoteItem {
        let size = try FileStamp(file).size
        if size <= 5 * 1024 * 1024 {
            try Task.checkCancellation()
            let boundary = "SafeSync-" + UUID().uuidString
            let metadata: [String: Any] = ["name": name, "parents": [parent], "modifiedTime": HTTP.dateString(modified, fractional: true)]
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body.append(try HTTP.json(metadata))
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(try Data(contentsOf: file))
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            let (data, _) = try await request(url: HTTP.url("https://www.googleapis.com/upload/drive/v3/files", query: ["uploadType": "multipart", "fields": fields, "supportsAllDrives": "true"]), method: "POST", body: body, headers: ["Content-Type": "multipart/related; boundary=\(boundary)"])
            let item = try parse(HTTP.object(data)); progress(size, size); return item
        }
        let digest = try BackupEngine.hash(file)
        let key = SHA256.hash(data: Data((account.id.uuidString + resumeKey).utf8)).map { String(format: "%02x", $0) }.joined()
        let record = dataDirectory.appendingPathComponent("uploads/\(key).json")
        var stored: UploadSession?
        if FileManager.default.fileExists(atPath: record.path) {
            let previous = try Storage.load(UploadSession.self, from: record)
            if previous.hash == digest && previous.size == size && previous.modified == modified && previous.parent == parent { stored = previous }
        }
        func valid(_ url: String) throws -> URL {
            guard let parsed = URL(string: url), parsed.scheme == "https", let host = parsed.host, host == "www.googleapis.com" || host.hasSuffix(".googleapis.com") else { throw BackupError.unsafe("업로드 세션 주소가 Google API 주소가 아닙니다.") }; return parsed
        }
        var offset: Int64 = 0
        if let previous = stored {
            let (data, response) = try await request(url: valid(previous.url), method: "PUT", body: Data(), headers: ["Content-Range": "bytes */\(size)"], accepted: [200, 201, 308, 404, 410])
            if response.statusCode == 200 || response.statusCode == 201 { let item = try parse(HTTP.object(data)); try? FileManager.default.removeItem(at: record); progress(size, size); return item }
            if response.statusCode == 308 { offset = receivedOffset(response) }
            else { stored = nil }
        }
        if stored == nil {
            let body: [String: Any] = ["name": name, "parents": [parent], "modifiedTime": HTTP.dateString(modified, fractional: true)]
            let (_, response) = try await request(url: HTTP.url("https://www.googleapis.com/upload/drive/v3/files", query: ["uploadType": "resumable", "fields": fields, "supportsAllDrives": "true"]), method: "POST", body: HTTP.json(body), headers: ["Content-Type": "application/json", "X-Upload-Content-Type": "application/octet-stream", "X-Upload-Content-Length": String(size)])
            guard let location = response.value(forHTTPHeaderField: "Location") else { throw BackupError.unsafe("Google Drive 업로드 세션이 없습니다.") }
            _ = try valid(location)
            stored = UploadSession(url: location, hash: digest, size: size, modified: modified, parent: parent)
            try Storage.save(stored!, to: record)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        }
        let url = try valid(stored!.url), handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        repeat {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let bytes = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            let range = size == 0 ? "bytes */0" : "bytes \(offset)-\(offset + Int64(bytes.count) - 1)/\(size)"
            let (data, response) = try await request(url: url, method: "PUT", body: bytes, headers: ["Content-Type": "application/octet-stream", "Content-Range": range], accepted: [200, 201, 308])
            if response.statusCode != 308 {
                let item = try parse(HTTP.object(data)); try? FileManager.default.removeItem(at: record); progress(size, size); return item
            }
            let next = receivedOffset(response)
            guard next > offset, next <= size else { throw BackupError.unsafe("Google Drive 전송 위치가 올바르지 않습니다.") }; offset = next; progress(offset, size)
        } while offset < size
        throw BackupError.unsafe("Google Drive 전송 완료를 확인할 수 없습니다.")
    }
    private func receivedOffset(_ response: HTTPURLResponse) -> Int64 {
        guard let range = response.value(forHTTPHeaderField: "Range"), let end = Int64(range.split(separator: "-").last ?? "") else { return 0 }; return end + 1
    }
    public func move(_ item: RemoteItem, name: String, parent: String) async throws -> RemoteItem {
        var query = ["fields": fields]
        if item.parent != parent { query["addParents"] = parent; query["removeParents"] = item.parent }
        let moved = try parse(await api("files/" + item.id, method: "PATCH", query: query, body: ["name": name]))
        if item.folder { await folderIndex.invalidate(id: item.id) }
        return moved
    }
    public func remove(_ item: RemoteItem) async throws {
        _ = try await api("files/" + item.id, method: "DELETE")
        if item.folder { await folderIndex.invalidate(id: item.id) }
    }
    public func download(_ item: RemoteItem, to file: URL) async throws {
        if transport != nil { try await download(item).write(to: file, options: .atomic); return }
        try await CloudAuthorization.shared.download(account, url: HTTP.url("https://www.googleapis.com/drive/v3/files/" + item.id, query: ["alt": "media", "supportsAllDrives": "true"]), to: file)
    }
    public func download(_ item: RemoteItem) async throws -> Data {
        let (data, _) = try await request(url: HTTP.url("https://www.googleapis.com/drive/v3/files/" + item.id, query: ["alt": "media", "supportsAllDrives": "true"])); return data
    }
    public func inventory(root: String, previous: RemoteIndex?) async throws -> RemoteIndex {
        await folderIndex.clear(root: root)
        guard let rootItem = try await metadata(root), rootItem.folder else { throw BackupError.unsafe("Google Drive 백업 폴더에 접근할 수 없습니다.") }
        var index = previous ?? RemoteIndex(); index.root = rootItem.id
        if previous?.cursor == nil {
            let cursor = try await api("changes/startPageToken")
            index.cursor = cursor["startPageToken"] as? String
            index.nodes = [:]
            var queue = [rootItem.id]
            while !queue.isEmpty {
                let parent = queue.removeFirst()
                for item in try await children(parent) { index.nodes[item.id] = item; if item.folder { queue.append(item.id) } }
            }
        }
        guard let cursor = index.cursor else { throw BackupError.unsafe("Google Drive 변경 토큰을 읽지 못했습니다.") }
        var token = cursor, expand: Set<String> = []
        while true {
            let page: [String: Any]
            do { page = try await api("changes", query: ["pageToken": token, "fields": "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(fields)))", "pageSize": "1000", "includeItemsFromAllDrives": "true"]) }
            catch let error as APIError where error.status == 410 { return try await inventory(root: root, previous: nil) }
            for change in page["changes"] as? [[String: Any]] ?? [] {
                guard let id = change["fileId"] as? String else { continue }
                if change["removed"] as? Bool == true { index.nodes.removeValue(forKey: id); continue }
                if let json = change["file"] as? [String: Any] {
                    if json["trashed"] as? Bool == true { index.nodes.removeValue(forKey: id) }
                    else { let item = try parse(json); if item.folder && index.nodes[id] == nil { expand.insert(id) }; index.nodes[id] = item }
                }
            }
            if let next = page["nextPageToken"] as? String { token = next }
            else { index.cursor = page["newStartPageToken"] as? String ?? token; break }
        }
        // Only retain nodes reachable below the selected backup root.
        var reachable: Set<String> = [rootItem.id], changed = true
        while changed { changed = false; for node in index.nodes.values where reachable.contains(node.parent) && !reachable.contains(node.id) { reachable.insert(node.id); changed = true } }
        var queue = Array(expand.intersection(reachable))
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for item in try await children(parent) { if item.folder && index.nodes[item.id] == nil { queue.append(item.id) }; index.nodes[item.id] = item; reachable.insert(item.id) }
        }
        index.nodes = index.nodes.filter { reachable.contains($0.key) }
        try await folderIndex.seed(index)
        return index
    }
}
