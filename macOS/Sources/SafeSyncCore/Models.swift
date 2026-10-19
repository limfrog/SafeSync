import Foundation

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    case oneWay, twoWay
    public var title: String { self == .oneWay ? "단방향 백업 →" : "양방향 동기화 ↔" }
}

public struct BackupJob: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name = ""
    public var source = ""
    public var destination = ""
    public var scheduled = false
    public var scheduleTime = "23:00"
    public var mirrorDeletes = true
    public var paused = false
    public var lastScheduledDay: String?
    public var syncMode: SyncMode?
    public var stopped: Bool?
    public var mode: SyncMode { syncMode ?? .oneWay }
    public var cloudProvider: CloudProvider?
    public var cloudAccountID: UUID?
    public var cloudFolderID: String?
    public var destinationTypeText: String { cloudProvider?.title ?? "로컬 / 네트워크 / 동기화 폴더" }
    public init() {}
    public var triggerText: String { scheduled ? "매일 \(scheduleTime)" : "파일 변경 시" }
}
public struct FileStamp: Codable, Equatable, Sendable {
    public var size: Int64
    public var modified: Date
    public var created: Date
    public init(size: Int64, modified: Date, created: Date) { self.size = size; self.modified = modified; self.created = created }
    public init(_ url: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (a[.size] as? NSNumber)?.int64Value ?? 0
        modified = a[.modificationDate] as? Date ?? .distantPast
        created = a[.creationDate] as? Date ?? .distantPast
    }
}
public struct FileRecord: Codable, Sendable {
    public var source: FileStamp
    public var backup: FileStamp
    public var hash: String
}
public struct Manifest: Codable, Sendable {
    public var files: [String: FileRecord] = [:]
    public var sourceRoot: String?
    public var destinationRoot: String?
    public init() {}
}
public struct BackupIssue: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var jobID: UUID
    public var path: String
    public var reason: String
    public var conflict: Bool
    public var source: FileStamp?
    public var backup: FileStamp?
    public var waiting: FileWaitState?
    public var remoteRevision: String?
    public var remoteID: String?
    public init(jobID: UUID, path: String, reason: String, conflict: Bool, source: FileStamp? = nil, backup: FileStamp? = nil, remoteRevision: String? = nil, remoteID: String? = nil, waiting: FileWaitState? = nil) {
        self.jobID = jobID; self.path = path; self.reason = reason; self.conflict = conflict; self.source = source; self.backup = backup; self.remoteRevision = remoteRevision; self.remoteID = remoteID; self.waiting = waiting
    }
}
public struct BackupProgress: Sendable {
    public var path: String
    public var completed: Int
    public var total: Int
    public var size: Int64?
    public var transferred: Int64?
    public var stage: String?
    public init(path: String, completed: Int, total: Int, size: Int64? = nil, transferred: Int64? = nil, stage: String? = nil) { self.path = path; self.completed = completed; self.total = total; self.size = size; self.transferred = transferred; self.stage = stage }
}
public struct BackupResult: Sendable {
    public var evaluatedPaths: Set<String> = []
    public func evaluated(_ path: String) -> Bool {
        evaluatedPaths.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
    }
    public var copied = 0
    public var skipped = 0
    public var removed = 0
    public var issues: [BackupIssue] = []
    public init() {}
}
public struct TrashItem: Identifiable, Codable, Sendable {
    public var id: UUID
    public var path: String
    public var deletedAt: Date
    public var size: Int64
    public var directory: Bool? = nil
}
public enum ConflictAction: String, Codable, CaseIterable, Sendable {
    case overwrite, useBackup, keepBoth, ignore, normalizeDuplicates
    public var title: String {
        switch self {
        case .overwrite: return "원본 → 백업 덮어쓰기"
        case .useBackup: return "백업 → 원본 덮어쓰기"
        case .keepBoth: return "이름 변경 · 둘 다 보관"
        case .ignore: return "이번 동기화에서 제외"
        case .normalizeDuplicates: return "중복 이름만 정리 · 사본 모두 보존"
        }
    }
}
public enum BackupError: LocalizedError {
    case unsafe(String)
    case fileBusy(String)
    public var errorDescription: String? { switch self { case .unsafe(let s), .fileBusy(let s): return s } }
}
public enum Storage {
    public static var applicationDirectory: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["SAFESYNC_TEST_DATA_DIRECTORY"], path.hasPrefix("/private/tmp/") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SafeSync")
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}
