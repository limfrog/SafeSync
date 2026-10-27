import Foundation

public struct DropboxStorage: RemoteStorage {
    public let provider = CloudProvider.dropbox
    let account: CloudAccount
    public init(account: CloudAccount) { self.account = account }
    private func rpc(_ endpoint: String, _ body: Any) async throws -> [String: Any] {
        let (data, _) = try await CloudAuthorization.shared.request(account, url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!, method: "POST", body: HTTP.json(body), headers: ["Content-Type": "application/json"])
        return try HTTP.object(data)
    }
    private func parse(_ json: [String: Any]) throws -> RemoteItem {
        guard let id = json["id"] as? String, let name = json["name"] as? String, let path = json["path_lower"] as? String else { throw BackupError.unsafe("Dropbox 파일 응답이 올바르지 않습니다.") }
        let parent = (path as NSString).deletingLastPathComponent
        return RemoteItem(id: id, name: name, parent: parent == "/" ? "" : parent, folder: json[".tag"] as? String == "folder", size: (json["size"] as? NSNumber)?.int64Value ?? 0, modified: HTTP.date(json["client_modified"] as? String), hash: json["content_hash"] as? String, hashKind: "dropbox", revision: json["rev"] as? String ?? "", locator: path)
    }
    public func children(_ parent: String) async throws -> [RemoteItem] {
        var page = try await rpc("files/list_folder", ["path": parent, "recursive": false, "include_deleted": false]), items: [RemoteItem] = []
        while true {
            items += try (page["entries"] as? [[String: Any]] ?? []).map(parse)
            if page["has_more"] as? Bool != true { return items }
            guard let cursor = page["cursor"] as? String else { throw BackupError.unsafe("Dropbox 목록 커서가 없습니다.") }
            page = try await rpc("files/list_folder/continue", ["cursor": cursor])
        }
    }
    public func metadata(_ id: String) async throws -> RemoteItem? {
        if id.isEmpty { return RemoteItem(id: "dropbox-root-" + account.id.uuidString, name: "Dropbox", parent: "", folder: true, locator: "") }
        do { return try parse(await rpc("files/get_metadata", ["path": id])) }
        catch let error as APIError where error.status == 409 && error.code == "path/not_found" { return nil }
    }
    public func createFolder(name: String, parent: String) async throws -> RemoteItem {
        let result = try await rpc("files/create_folder_v2", ["path": join(parent, name), "autorename": false])
        guard let metadata = result["metadata"] as? [String: Any] else { throw BackupError.unsafe("Dropbox 폴더 응답이 없습니다.") }; return try parse(metadata)
    }
    private func join(_ root: String, _ name: String) -> String { root.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/" + name : root + "/" + name }
    private func content(_ endpoint: String, arguments: Any, bytes: Data) async throws -> [String: Any] {
        let arg = try HTTP.json(arguments)
        // Dropbox requires non-ASCII header characters to be escaped as JSON unicode sequences.
        let string = String(decoding: arg, as: UTF8.self).unicodeScalars.map { scalar -> String in
            if scalar.value < 128 { return String(scalar) }
            if scalar.value <= 0xffff { return String(format: "\\u%04x", scalar.value) }
            let value = scalar.value - 0x10000
            return String(format: "\\u%04x\\u%04x", 0xd800 + (value >> 10), 0xdc00 + (value & 0x3ff))
        }.joined()
        let (data, _) = try await CloudAuthorization.shared.request(account, url: URL(string: "https://content.dropboxapi.com/2/\(endpoint)")!, method: "POST", body: bytes, headers: ["Content-Type": "application/octet-stream", "Dropbox-API-Arg": string])
        return data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" ? [:] : try HTTP.object(data)
    }
    public func upload(file: URL, name: String, parent: String, modified: Date, resumeKey: String, progress: @Sendable (Int64, Int64) -> Void) async throws -> RemoteItem {
        let commit: [String: Any] = ["path": join(parent, name), "mode": "add", "autorename": false, "mute": true, "client_modified": HTTP.dateString(modified)]
        let length = try FileStamp(file).size
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        if length <= 8 * 1024 * 1024 { let item = try parse(await content("files/upload", arguments: commit, bytes: try handle.readToEnd() ?? Data())); progress(length, length); return item }
        let started = try await content("files/upload_session/start", arguments: ["close": false], bytes: Data())
        guard let session = started["session_id"] as? String else { throw BackupError.unsafe("Dropbox 업로드 세션을 열지 못했습니다.") }
        var offset: Int64 = 0
        while offset < length {
            try Task.checkCancellation()
            let bytes = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            guard !bytes.isEmpty else { throw BackupError.unsafe("전송할 사본이 예상보다 짧습니다.") }
            let cursor: [String: Any] = ["session_id": session, "offset": offset]
            if offset + Int64(bytes.count) == length { let item = try parse(await content("files/upload_session/finish", arguments: ["cursor": cursor, "commit": commit], bytes: bytes)); progress(length, length); return item }
            _ = try await content("files/upload_session/append_v2", arguments: ["cursor": cursor, "close": false], bytes: bytes)
            offset += Int64(bytes.count); progress(offset, length)
        }
        throw BackupError.unsafe("Dropbox 전송이 완료되지 않았습니다.")
    }
    public func move(_ item: RemoteItem, name: String, parent: String) async throws -> RemoteItem {
        let result = try await rpc("files/move_v2", ["from_path": item.id, "to_path": join(parent, name), "autorename": false])
        guard let metadata = result["metadata"] as? [String: Any] else { throw BackupError.unsafe("Dropbox 이동 응답이 없습니다.") }; return try parse(metadata)
    }
    public func remove(_ item: RemoteItem) async throws { _ = try await rpc("files/delete_v2", ["path": item.id]) }
    public func download(_ item: RemoteItem, to file: URL) async throws {
        let arg = String(decoding: try HTTP.json(["path": item.id]), as: UTF8.self)
        try await CloudAuthorization.shared.download(account, url: URL(string: "https://content.dropboxapi.com/2/files/download")!, to: file, method: "POST", headers: ["Dropbox-API-Arg": arg])
    }
    public func download(_ item: RemoteItem) async throws -> Data {
        let arg = String(decoding: try HTTP.json(["path": item.id]), as: UTF8.self)
        let (data, _) = try await CloudAuthorization.shared.request(account, url: URL(string: "https://content.dropboxapi.com/2/files/download")!, method: "POST", headers: ["Dropbox-API-Arg": arg]); return data
    }
    public func inventory(root: String, previous: RemoteIndex?) async throws -> RemoteIndex {
        let timing = OperationLog.measure("prepare.remote_catalog_refresh"); defer { timing.end() }
        OperationLog.event("catalog.plan", "remote", total: previous?.nodes.count ?? 0, detail: "full=\(previous?.cursor == nil)")
        var index = previous ?? RemoteIndex(); index.root = root.lowercased()
        var page: [String: Any]
        if let cursor = previous?.cursor {
            do { page = try await rpc("files/list_folder/continue", ["cursor": cursor]) }
            catch let error as APIError where error.status == 409 && error.code == "reset" { return try await inventory(root: root, previous: nil) }
        } else { index.nodes = [:]; page = try await rpc("files/list_folder", ["path": root, "recursive": true, "include_deleted": true]) }
        // Dropbox parents are paths. Use paths as graph node keys, including folders.
        while true {
            for json in page["entries"] as? [[String: Any]] ?? [] {
                guard let path = json["path_lower"] as? String else { continue }
                if json[".tag"] as? String == "deleted" {
                    for key in Array(index.nodes.keys) where key == path || key.hasPrefix(path + "/") { index.nodes.removeValue(forKey: key) }
                } else { index.nodes[path] = try parse(json) }
            }
            index.cursor = page["cursor"] as? String
            guard page["has_more"] as? Bool == true, let cursor = index.cursor else { break }
            page = try await rpc("files/list_folder/continue", ["cursor": cursor])
        }
        return index
    }
}
