import Foundation

/// Store-scoped hints, never permission to write without a fresh ancestry/name check.
actor GoogleFolderIndex {
    struct Key: Hashable { var root: String; var path: String }
    private var chains: [Key: [RemoteItem]] = [:]
    func clear(root: String) { chains = chains.filter { $0.key.root != root } }
    func invalidate(id: String) { chains = chains.filter { !$0.value.contains(where: { $0.id == id }) } }
    func invalidate(root: String, path: String) {
        chains = chains.filter { $0.key.root != root || !($0.key.path == path || $0.key.path.hasPrefix(path + "/")) }
    }
    func chain(root: String, path: String) -> [RemoteItem]? { chains[Key(root: root, path: path)] }
    func remember(root: String, path: String, chain: [RemoteItem]) { chains[Key(root: root, path: path)] = chain }
    func seed(_ index: RemoteIndex) throws {
        clear(root: index.root)
        // A name that cannot be represented as a relative path disables this
        // optimization. The existing comparison policy still decides how to
        // report it; an unrelated empty folder must not add a new failure.
        guard let groups = try? index.groupsByAllPaths() else { return }
        let ambiguous = groups.filter { $0.value.count != 1 }.map(\.key)
        for (path, items) in groups where items.count == 1 && items[0].folder {
            guard !ambiguous.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            var chain = [items[0]], node = items[0], seen: Set<String> = [items[0].id]
            while node.parent != index.root {
                guard let parent = index.nodes[node.parent], parent.folder, seen.insert(parent.id).inserted else { chain = []; break }
                chain.insert(parent, at: 0); node = parent
            }
            if !chain.isEmpty { remember(root: index.root, path: path, chain: chain) }
        }
    }
}

/// Only overlapping read requests share a task. Results and failures are not a TTL cache.
actor GoogleReadFlights<Value: Sendable> {
    private var tasks: [String: (UUID, Task<Value, Error>)] = [:]
    func read(_ key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let entry: (UUID, Task<Value, Error>)
        if let pending = tasks[key] { entry = pending }
        else { entry = (UUID(), Task { try await operation() }); tasks[key] = entry }
        do {
            let result = try await entry.1.value
            if tasks[key]?.0 == entry.0 { tasks.removeValue(forKey: key) }
            try Task.checkCancellation(); return result
        } catch {
            if tasks[key]?.0 == entry.0 { tasks.removeValue(forKey: key) }
            throw error
        }
    }
}

/// Serialize creation of the same folder, without blocking unrelated folders.
actor GoogleFolderCreationGate {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func run<Value: Sendable>(_ key: String, operation: @Sendable () async throws -> Value) async throws -> Value {
        if !held.insert(key).inserted {
            await withCheckedContinuation { waiters[key, default: []].append($0) }
        }
        do { try Task.checkCancellation(); let result = try await operation(); release(key); return result }
        catch { release(key); throw error }
    }
    private func release(_ key: String) {
        if var waiting = waiters[key], !waiting.isEmpty {
            let next = waiting.removeFirst(); waiters[key] = waiting.isEmpty ? nil : waiting; next.resume()
        } else { held.remove(key) }
    }
}

extension GoogleDriveStorage {
    public func ensureFolder(name: String, parent: String) async throws -> RemoteItem {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw BackupError.unsafe("안전하지 않은 클라우드 폴더 이름입니다.") }
        return try await folderCreation.run(parent + "\u{0}" + name) {
            // Never join a read that began before another creator acquired this lock.
            let matches = try await childrenCore(parent).filter { $0.name == name }
            guard matches.count <= 1 else { throw BackupError.unsafe("동일한 이름의 클라우드 폴더가 여러 개입니다: \(name)") }
            if let item = matches.first {
                guard item.folder else { throw BackupError.unsafe("폴더 이름을 파일이 사용 중입니다: \(name)") }; return item
            }
            try Task.checkCancellation()
            let created = try await createFolder(name: name, parent: parent)
            let confirmed = try await childrenCore(parent).filter { $0.name == name }
            guard confirmed.count == 1, confirmed[0].folder, confirmed[0].id == created.id else { throw BackupError.unsafe("Google Drive 폴더 생성 충돌이 발생했습니다. 기존 사본을 보존합니다.") }
            return confirmed[0]
        }
    }
    public func folder(path: String, root: String) async throws -> String {
        let parts = path.split(separator: "/").map(String.init), normalized = parts.joined(separator: "/")
        guard !parts.contains("."), !parts.contains("..") else { throw BackupError.unsafe("안전하지 않은 클라우드 경로입니다.") }
        if !parts.isEmpty, root != "root", let chain = await folderIndex.chain(root: root, path: normalized),
           let cached = try await checkedFolder(root: root, path: normalized, chain: chain) { return cached }
        var parent = root, prefix = "", chain: [RemoteItem] = []
        for part in parts {
            try Task.checkCancellation()
            let item = try await ensureFolder(name: part, parent: parent)
            chain.append(item); parent = item.id; prefix = prefix.isEmpty ? part : prefix + "/" + part
            await folderIndex.remember(root: root, path: prefix, chain: chain)
        }
        return parent
    }
    private func checkedFolder(root: String, path: String, chain: [RemoteItem]) async throws -> String? {
        let rootURL = HTTP.url("https://www.googleapis.com/drive/v3/files/" + root,
                               query: ["fields": "id,name,mimeType,trashed", "supportsAllDrives": "true"])
        let urls = [rootURL] + chain.map { node in
            HTTP.url("https://www.googleapis.com/drive/v3/files", query: [
                "q": "'\(node.parent)' in parents and trashed = false", "pageSize": "1000",
                "fields": "nextPageToken,files(id,name,mimeType)", "supportsAllDrives": "true", "includeItemsFromAllDrives": "true"])
        }
        let responses = try await folderReads.read(root + "\u{0}" + path) { try await folderBatch(urls) }
        guard let rootData = responses[0] else { await folderIndex.clear(root: root); throw BackupError.unsafe("백업 루트가 삭제되었거나 접근할 수 없습니다.") }
        let rootJSON = try HTTP.object(rootData), rootItem = try parse(rootJSON)
        guard rootItem.id == root, rootItem.folder, rootJSON["trashed"] as? Bool != true else {
            await folderIndex.clear(root: root); throw BackupError.unsafe("백업 루트가 변경되었습니다. 기존 백업을 보존합니다.")
        }
        for (offset, node) in chain.enumerated() {
            guard let data = responses[offset + 1] else { await folderIndex.invalidate(id: node.id); return nil }
            let page = try HTTP.object(data)
            let items: [RemoteItem]
            if let next = page["nextPageToken"] as? String, !next.isEmpty { items = try await childrenCore(node.parent) }
            else {
                guard let files = page["files"] as? [[String: Any]] else { throw BackupError.unsafe("폴더 목록 응답이 누락되었습니다.") }
                items = try files.map(parse)
            }
            let matches = items.filter { $0.name == node.name }
            guard matches.count <= 1 else { await folderIndex.invalidate(id: node.id); throw BackupError.unsafe("동일한 이름의 클라우드 폴더가 여러 개입니다: \(node.name)") }
            guard matches.count == 1, matches[0].id == node.id, matches[0].folder else {
                await folderIndex.invalidate(id: node.id); return nil
            }
        }
        return chain.last?.id
    }
    private func folderBatch(_ urls: [URL]) async throws -> [Data?] {
        var result: [Data?] = []
        for start in stride(from: 0, to: urls.count, by: 100) {
            let chunk = Array(urls[start..<min(start + 100, urls.count)]), boundary = "safesync_" + UUID().uuidString
            var body = ""
            for (index, url) in chunk.enumerated() {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                body += "--\(boundary)\r\nContent-Type: application/http\r\nContent-ID: <\(index)>\r\n\r\nGET \(components.percentEncodedPath)?\(components.percentEncodedQuery ?? "") HTTP/1.1\r\n\r\n"
            }
            body += "--\(boundary)--\r\n"
            let (data, response) = try await request(url: URL(string: "https://www.googleapis.com/batch/drive/v3")!, method: "POST", body: Data(body.utf8), headers: ["Content-Type": "multipart/mixed; boundary=\(boundary)"])
            guard response.statusCode == 200 else { throw APIError(status: response.statusCode, summary: "Google Drive 폴더 일괄 확인 실패") }
            guard let type = response.value(forHTTPHeaderField: "Content-Type"),
                  let boundaryRange = type.range(of: "boundary=", options: .caseInsensitive) else { throw BackupError.unsafe("폴더 일괄 확인 응답 경계가 없습니다.") }
            let responseBoundary = String(type[boundaryRange.upperBound...]).split(separator: ";").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) ?? ""
            guard !responseBoundary.isEmpty, let text = String(data: data, encoding: .utf8) else { throw BackupError.unsafe("폴더 일괄 확인 응답이 올바르지 않습니다.") }
            var answers = [Data?](repeating: nil, count: chunk.count), seen: Set<Int> = []
            let idPattern = try NSRegularExpression(pattern: "Content-ID:\\s*<response-([0-9]+)>", options: .caseInsensitive)
            let statusPattern = try NSRegularExpression(pattern: "HTTP/[0-9](?:\\.[0-9])?\\s+([0-9]{3})")
            func match(_ pattern: NSRegularExpression, _ part: String) -> String? {
                guard let match = pattern.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)), let range = Range(match.range(at: 1), in: part) else { return nil }
                return String(part[range])
            }
            for part in text.components(separatedBy: "--" + responseBoundary) {
                guard let id = match(idPattern, part), let index = Int(id) else { continue }
                guard index < chunk.count, seen.insert(index).inserted,
                      let statusString = match(statusPattern, part), let status = Int(statusString) else { throw BackupError.unsafe("폴더 일괄 확인 응답이 중복되거나 누락되었습니다.") }
                if status == 404 { continue }
                guard status == 200 else { throw APIError(status: status, summary: "Google Drive 폴더 확인 실패") }
                guard let jsonStart = part.firstIndex(of: "{") else { throw BackupError.unsafe("폴더 확인 응답 내용이 없습니다.") }
                let json = Data(part[jsonStart...].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
                _ = try HTTP.object(json); answers[index] = json
            }
            guard seen.count == chunk.count else { throw BackupError.unsafe("폴더 일괄 확인 응답이 누락되었습니다.") }
            result += answers
        }
        return result
    }
}
