import Foundation
import CryptoKit
import Security

public enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case dropbox, googleDrive
    public var title: String { self == .dropbox ? "Dropbox API" : "Google Drive API" }
}
public struct CloudAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: CloudProvider
    public var name: String
    public var clientID: String
    public var accessMode: String?
    public init(provider: CloudProvider, name: String, clientID: String) { id = UUID(); self.provider = provider; self.name = name; self.clientID = clientID; accessMode = provider == .googleDrive ? GoogleFileAccess.mode : nil }
}
public struct CloudSecret: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var clientSecret: String
    public var expiresAt: Date
    public var grantedScope: String?
    public var googleAccountID: String?
    public init(accessToken: String = "", refreshToken: String = "", clientSecret: String = "", expiresAt: Date = .distantPast) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.clientSecret = clientSecret; self.expiresAt = expiresAt
    }
}
public enum CredentialVault {
    private static let service = "io.limfrog.SafeSync.macOS.oauth"
    public static func save(_ secret: CloudSecret, account: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.uuidString]
        let data = try JSONEncoder().encode(secret)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw BackupError.unsafe("Keychain 저장 실패 (\(added)).") }
        } else if status != errSecSuccess { throw BackupError.unsafe("Keychain 갱신 실패 (\(status)).") }
    }
    public static func read(account: UUID) throws -> CloudSecret {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else { throw BackupError.unsafe("클라우드 계정을 다시 연결하세요. Keychain 상태: \(status)") }
        return try JSONDecoder().decode(CloudSecret.self, from: data)
    }
    public static func delete(account: UUID) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account.uuidString] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackupError.unsafe("Keychain 삭제 실패 (\(status)).") }
    }
}
public struct RemoteItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var parent: String
    public var folder: Bool
    public var size: Int64
    public var modified: Date
    public var created: Date?
    public var hash: String?
    public var hashKind: String?
    public var revision: String
    public var locator: String
    public var appAccessMode: String?
    public init(id: String, name: String, parent: String, folder: Bool = false, size: Int64 = 0, modified: Date = .distantPast, hash: String? = nil, hashKind: String? = nil, revision: String = "", locator: String? = nil, created: Date? = nil) {
        self.id = id; self.name = name; self.parent = parent; self.folder = folder; self.size = size; self.modified = modified; self.created = created; self.hash = hash; self.hashKind = hashKind; self.revision = revision; self.locator = locator ?? id
    }
    public var stamp: FileStamp { FileStamp(size: size, modified: modified, created: created ?? .distantPast) }
}
public struct RemoteIndex: Codable, Sendable {
    public var nodes: [String: RemoteItem] = [:]
    public var cursor: String?
    public var root = ""
    public init() {}
    public func groupsByPath() throws -> [String: [RemoteItem]] {
        var result: [String: [RemoteItem]] = [:]
        for node in nodes.values where !node.folder {
            guard !node.name.isEmpty, !node.name.contains("/"), node.name != ".", node.name != ".." else { throw BackupError.unsafe("백업 경로로 해석할 수 없는 클라우드 파일 이름이 있습니다.") }
            var current = node, components = [node.name], visited: Set<String> = [node.id]
            while current.parent != root {
                guard let parent = nodes[current.parent], !visited.contains(parent.id) else { components = []; break }
                guard !parent.name.contains("/"), parent.name != ".", parent.name != ".." else { throw BackupError.unsafe("백업 경로로 해석할 수 없는 클라우드 폴더 이름이 있습니다.") }
                visited.insert(parent.id); components.insert(parent.name, at: 0); current = parent
            }
            if components.isEmpty || components.first?.hasPrefix(".safesync-") == true { continue }
            let path = components.joined(separator: "/")
            result[path, default: []].append(node)
        }
        return result
    }
    public func filesByPath() throws -> [String: RemoteItem] {
        let groups = try groupsByPath()
        guard !groups.values.contains(where: { $0.count > 1 }) else { throw BackupError.unsafe("클라우드에 이름이 같은 파일이 중복되어 있습니다.") }
        return groups.compactMapValues { $0.first }
    }

    /// Returns files and folders from the already refreshed catalog without
    /// issuing one network request per directory. Orphans are ignored because
    /// they are outside the selected root and therefore cannot authorize a
    /// local deletion.
    public func groupsByAllPaths() throws -> [String: [RemoteItem]] {
        var result: [String: [RemoteItem]] = [:]
        for node in nodes.values {
            guard !node.name.isEmpty, !node.name.contains("/"), node.name != ".", node.name != ".." else {
                throw BackupError.unsafe("백업 경로로 해석할 수 없는 클라우드 항목 이름이 있습니다.")
            }
            var current = node, components = [node.name], visited: Set<String> = [node.id]
            while current.parent != root {
                guard let parent = nodes[current.parent], !visited.contains(parent.id) else { components = []; break }
                guard !parent.name.contains("/"), parent.name != ".", parent.name != ".." else {
                    throw BackupError.unsafe("백업 경로로 해석할 수 없는 클라우드 폴더 이름이 있습니다.")
                }
                visited.insert(parent.id); components.insert(parent.name, at: 0); current = parent
            }
            if components.isEmpty || components.first?.hasPrefix(".safesync-") == true { continue }
            result[components.joined(separator: "/"), default: []].append(node)
        }
        return result
    }

}
public protocol RemoteStorage: Sendable {
    var provider: CloudProvider { get }
    func children(_ parent: String) async throws -> [RemoteItem]
    func metadata(_ id: String) async throws -> RemoteItem?
    func createFolder(name: String, parent: String) async throws -> RemoteItem
    func ensureFolder(name: String, parent: String) async throws -> RemoteItem
    func folder(path: String, root: String) async throws -> String
    func upload(file: URL, name: String, parent: String, modified: Date, resumeKey: String, progress: @Sendable (Int64, Int64) -> Void) async throws -> RemoteItem
    func move(_ item: RemoteItem, name: String, parent: String) async throws -> RemoteItem
    func remove(_ item: RemoteItem) async throws
    func download(_ item: RemoteItem, to file: URL) async throws
    func download(_ item: RemoteItem) async throws -> Data
    func inventory(root: String, previous: RemoteIndex?) async throws -> RemoteIndex
}
public extension RemoteStorage {
    func download(_ item: RemoteItem, to file: URL) async throws { try await download(item).write(to: file, options: .atomic) }
    func upload(file: URL, name: String, parent: String, modified: Date, resumeKey: String) async throws -> RemoteItem { try await upload(file: file, name: name, parent: parent, modified: modified, resumeKey: resumeKey, progress: { _, _ in }) }

    func ensureFolder(name: String, parent: String) async throws -> RemoteItem {
        let matches = try await children(parent).filter { provider == .dropbox ? $0.name.caseInsensitiveCompare(name) == .orderedSame : $0.name == name }
        guard matches.count <= 1 else { throw BackupError.unsafe("동일한 이름의 클라우드 폴더가 여러 개입니다: \(name)") }
        if let item = matches.first { guard item.folder else { throw BackupError.unsafe("폴더 이름을 파일이 사용 중입니다: \(name)") }; return item }
        return try await createFolder(name: name, parent: parent)
    }
    func folder(path: String, root: String) async throws -> String {
        var parent = root
        for component in path.split(separator: "/") {
            guard component != "..", component != "." else { throw BackupError.unsafe("안전하지 않은 클라우드 경로입니다.") }
            parent = try await ensureFolder(name: String(component), parent: parent).locator
        }
        return parent
    }
}
public enum ContentHash {
    public static func compute(_ file: URL, kind: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        if kind == "dropbox" {
            var outer = SHA256()
            while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { try Task.checkCancellation(); outer.update(data: Data(SHA256.hash(data: block))) }
            return outer.finalize().map { String(format: "%02x", $0) }.joined()
        }
        if kind == "md5" {
            var hash = Insecure.MD5()
            while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { try Task.checkCancellation(); hash.update(data: block) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try BackupEngine.hash(file)
    }
    public static func verify(_ item: RemoteItem, file: URL) throws {
        guard let hash = item.hash, let kind = item.hashKind, item.size == (try FileStamp(file)).size, try compute(file, kind: kind) == hash else { throw BackupError.unsafe("클라우드 파일의 크기 또는 서버 체크섬 검증에 실패했습니다. 기존 백업을 보존합니다.") }
    }
}
public enum SourceScanner {
    public static func files(_ source: URL) throws -> [String: FileStamp] {
        let timing = OperationLog.measure("prepare.source_scan"); defer { timing.end() }
        let fm = FileManager.default, root = source.standardizedFileURL.resolvingSymlinksInPath()
        var error: Error?, result: [String: FileStamp] = [:]
        guard let scan = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey], errorHandler: { _, failure in error = failure; return false }) else { throw BackupError.unsafe("원본을 읽을 수 없습니다.") }
        for case let url as URL in scan {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true { scan.skipDescendants(); continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { throw BackupError.unsafe("원본 밖의 파일은 처리할 수 없습니다.") }
            let ownData = Storage.applicationDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            if resolved.path == ownData || resolved.path.hasPrefix(ownData + "/") { scan.skipDescendants(); continue }
            let path = String(resolved.path.dropFirst(root.path.count + 1))
            if path.split(separator: "/").first?.hasPrefix(".safesync-") == true { scan.skipDescendants(); continue }
            if values.isRegularFile == true { result[path] = try FileStamp(url) }
        }
        if let error { throw error }; return result
    }
    public static func file(_ root: URL, path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), !path.isEmpty else { throw BackupError.unsafe("잘못된 파일 경로입니다.") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath(), file = base.appendingPathComponent(path)
        guard file.resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { throw BackupError.unsafe("원본 밖의 파일은 처리할 수 없습니다.") }
        var cursor = base
        for component in path.split(separator: "/") { cursor.appendPathComponent(String(component)); if try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw BackupError.unsafe("심볼릭 링크는 처리하지 않습니다.") } }
        return file
    }
}
