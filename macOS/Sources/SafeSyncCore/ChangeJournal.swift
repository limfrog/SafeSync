import Foundation

public struct ChangeJournal: Codable, Sendable {
    public var sequence: UInt64 = 1
    public var pending: [String: UInt64] = [:]
    public var fullScanGeneration: UInt64? = 1
    public var eventID: UInt64?
    public var lastFullScan: Date?
    public init() {}
    public mutating func record(paths: [String], eventID: UInt64?, requireFull: Bool) {
        sequence &+= 1
        for path in paths { pending[path] = sequence }
        if requireFull { fullScanGeneration = sequence }
        if let eventID { self.eventID = max(self.eventID ?? 0, eventID) }
    }
    // Time away alone is not evidence of lost events. Explicit recovery, a missing
    // checkpoint or an unhealthy watcher still requests a complete inventory.
    public func needsFullScan(now: Date = Date()) -> Bool { fullScanGeneration != nil || lastFullScan == nil }
    public mutating func acknowledge(through checkpoint: UInt64, full: Bool, retry: [String], now: Date = Date()) {
        pending = pending.filter { $0.value > checkpoint }
        if full {
            if let generation = fullScanGeneration, generation <= checkpoint { fullScanGeneration = nil }
            lastFullScan = now
        }
        if !retry.isEmpty { record(paths: retry, eventID: nil, requireFull: false) }
    }
}
public extension SourceScanner {
    static func reconcile(root: URL, known: [String: FileStamp], changed: Set<String>) throws -> [String: FileStamp] {
        if changed.contains("") { return try files(root) }
        let fm = FileManager.default
        let rootGuard = try LocalRootGuard(root.path)
        var result = known
        for path in changed.sorted() {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw BackupError.unsafe("잘못된 변경 경로입니다.") }
            let candidate = root.appendingPathComponent(path)
            // Failed metadata access must not be interpreted as deletion.
            let values: URLResourceValues
            do { values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) }
            catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                    guard try rootGuard.confirmedMissing(path) else { throw BackupError.fileBusy("변경 확인 중 원본이 다시 나타났습니다.") }
                    for key in Array(result.keys) where key == path || key.hasPrefix(path + "/") { result.removeValue(forKey: key) }; continue
                }
                throw error
            }
            if values.isSymbolicLink == true { continue }
            _ = try file(root, path: path)
            for key in Array(result.keys) where key == path || key.hasPrefix(path + "/") { result.removeValue(forKey: key) }
            if values.isDirectory == true { for (relative, stamp) in try files(candidate) { result[path + "/" + relative] = stamp } }
            else if values.isRegularFile == true { result[path] = try FileStamp(candidate) }
        }
        // Readability of the root is checked even when no file changed.
        guard fm.isReadableFile(atPath: root.path) else { throw BackupError.unsafe("원본 위치를 읽을 수 없습니다.") }
        try rootGuard.verify()
        return result
    }
}

public enum BackupScanPolicy {
    public static func requiresFullScan(explicit: Bool, watcherReady: Bool, journal: ChangeJournal, network: Bool, now: Date = Date()) -> Bool {
        explicit || !watcherReady || journal.needsFullScan(now: now) || network
    }
}
