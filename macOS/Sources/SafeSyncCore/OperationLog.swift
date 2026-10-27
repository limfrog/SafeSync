import Foundation
import CryptoKit

/// Bounded asynchronous diagnostics. Never serialize paths, URLs, headers,
/// request/response bodies, credentials or localized error messages.
public final class OperationLog: @unchecked Sendable {
    public static let fileLimit = 8 * 1024 * 1024
    public static let fileCount = 8
    private static let configurationLock = NSLock()
    private static var configured: OperationLog?
    @TaskLocal public static var run: Run?
    private let queue = DispatchQueue(label: "SafeSync.operation-log", qos: .utility)
    private let lock = NSLock()
    private let directory: URL
    private let session = UUID().uuidString
    private let key = SymmetricKey(size: .bits256)
    private var pending = 0, dropped = 0, part = 0, size = 0
    private var output: FileHandle?
    private var summary: FileHandle?, summaryPart = 0, summarySize = 0
    private var disabled = false
    public static func start(directory: URL, version: String) -> OperationLog {
        let log = OperationLog(directory: directory)
        configurationLock.lock(); configured = log; configurationLock.unlock()
        log.write("session.start", "application", detail: version); return log
    }
    private init(directory: URL) { self.directory = directory.appendingPathComponent("logs/operations") }
    private static var current: OperationLog? {
        configurationLock.lock(); defer { configurationLock.unlock() }; return configured
    }
    private func tag(_ value: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
    public static func event(_ event: String, _ operation: String, path: String? = nil, bytes: Int64? = nil,
                             completed: Int? = nil, total: Int? = nil, status: Int? = nil,
                             ms: Double? = nil, error: Error? = nil, detail: String? = nil) {
        (run?.log ?? current)?.write(event, operation, context: run, path: path, bytes: bytes, completed: completed,
                                    total: total, status: status, ms: ms, error: error, detail: detail)
    }
    private func write(_ event: String, _ operation: String, context: Run? = nil, path: String? = nil,
                       bytes: Int64? = nil, completed: Int? = nil, total: Int? = nil, status: Int? = nil,
                       ms: Double? = nil, error: Error? = nil, detail: String? = nil) {
        var entry: [String: Any] = ["Schema": 1, "Utc": HTTP.dateString(Date(), fractional: true), "Session": session,
                                    "Event": event, "Operation": operation]
        if let context { entry["Run"] = context.id }
        if let path, !path.isEmpty { entry["File"] = tag(path) }
        if let bytes { entry["Bytes"] = bytes }; if let completed { entry["Completed"] = completed }
        if let total { entry["Total"] = total }; if let status { entry["Status"] = status }
        if let ms { entry["Ms"] = ms }; if let detail { entry["Detail"] = detail }
        if let error { entry["Error"] = String(describing: type(of: error)); entry["Code"] = (error as NSError).code }
        lock.lock()
        guard pending < 8192 else { dropped += 1; lock.unlock(); return }
        pending += 1; lock.unlock()
        queue.async { [self, entry] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            guard !disabled else { return }
            do {
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]); data.append(10)
                if output == nil || size + data.count > Self.fileLimit { try rotate() }
                lock.lock(); let lost = dropped; dropped = 0; lock.unlock()
                if lost > 0 {
                    var loss = try JSONSerialization.data(withJSONObject: ["Schema": 1, "Event": "log.dropped", "Count": lost, "Session": session]); loss.append(10)
                    try output?.write(contentsOf: loss); size += loss.count
                }
                try output?.write(contentsOf: data); size += data.count
                try writeSummary(data, entry: entry)
            } catch { disabled = true; try? output?.close(); output = nil }
        }
    }
    private func rotate() throws {
        try output?.close()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Diagnostic-\(Int(Date().timeIntervalSince1970))-\(session.prefix(8))-\(String(format: "%04d", part)).jsonl")
        part += 1
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        output = try FileHandle(forWritingTo: url); size = 0
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("Diagnostic-") && $0.pathExtension == "jsonl" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (i, file) in files.enumerated() where file != url {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if i >= Self.fileCount || date < Date().addingTimeInterval(-14 * 86400) { try? FileManager.default.removeItem(at: file) }
        }
    }
    private func writeSummary(_ data: Data, entry: [String: Any]) throws {
        let event = entry["Event"] as? String ?? "", operation = entry["Operation"] as? String ?? ""
        guard ["session.start", "run.start", "run.result", "run.error", "run.end", "prepare.phase", "prepare.ready", "prepare.plan", "transfer.first"].contains(event) || operation == "application.initialize" || (entry["Run"] == nil && event == "span.end" && operation.hasPrefix("prepare.")) else { return }
        if summary == nil || summarySize + data.count > Self.fileLimit {
            try summary?.close()
            let url = directory.appendingPathComponent("Summary-\(Int(Date().timeIntervalSince1970))-\(session.prefix(8))-\(String(format: "%04d", summaryPart)).jsonl")
            summaryPart += 1; summarySize = 0
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            summary = try FileHandle(forWritingTo: url)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("Summary-") && $0.pathExtension == "jsonl" }
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (i, file) in files.enumerated() where file != url {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if i >= 2 || date < Date().addingTimeInterval(-14 * 86400) { try? FileManager.default.removeItem(at: file) }
            }
        }
        try summary?.write(contentsOf: data); summarySize += data.count
    }
    public func flush() { queue.sync { try? output?.synchronize(); try? summary?.synchronize() } }
    public func close() {
        Self.configurationLock.lock(); if Self.configured === self { Self.configured = nil }; Self.configurationLock.unlock()
        queue.sync { try? output?.synchronize(); try? output?.close(); try? summary?.synchronize(); try? summary?.close(); output = nil; summary = nil; disabled = true }
    }
    public static func measure(_ operation: String, path: String? = nil, bytes: Int64? = nil) -> Span {
        Span(log: run?.log ?? current, context: run, operation: operation, path: path, bytes: bytes)
    }
    public final class Span: @unchecked Sendable {
        private let log: OperationLog?, context: Run?, operation: String, path: String?, bytes: Int64?
        private let start = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock(); private var ended = false
        fileprivate init(log: OperationLog?, context: Run?, operation: String, path: String?, bytes: Int64?) {
            self.log = log; self.context = context; self.operation = operation; self.path = path; self.bytes = bytes
            context?.starting(operation)
            log?.write("span.start", operation, context: context, path: path, bytes: bytes)
        }
        public func end() {
            lock.lock(); guard !ended else { lock.unlock(); return }; ended = true; lock.unlock()
            let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
            context?.note(operation, ms: ms)
            log?.write("span.end", operation, context: context, path: path, bytes: bytes, ms: ms)
        }
        deinit { end() }
    }
    public final class Run: @unchecked Sendable {
        fileprivate let log: OperationLog, id = UUID().uuidString
        private let lock = NSLock()
        private var stage = "", stageStart = ProcessInfo.processInfo.systemUptime
        private var totals: [String: Double] = [:]
        private var prepared = false, uploading = false
        private let started = ProcessInfo.processInfo.systemUptime
        fileprivate init(_ log: OperationLog) { self.log = log }
        public func progress(_ p: BackupProgress) {
            let known = Set(["이전 전송 복구 확인", "클라우드 변경 목록 확인", "양쪽 폴더 전체 목록 확인", "완료"])
            let label = p.stage ?? (known.contains(p.path) ? p.path : "file.compare")
            if label == "file.compare" { starting("file.begin") }
            lock.lock(); let now = ProcessInfo.processInfo.systemUptime
            if stage != label { if !stage.isEmpty { totals[stage, default: 0] += (now - stageStart) * 1000 }; stage = label; stageStart = now }
            lock.unlock()
            log.write("stage", "backup", context: self, path: p.path, bytes: p.transferred, completed: p.completed, total: p.total, detail: label)
        }
        fileprivate func starting(_ operation: String) {
            lock.lock(); defer { lock.unlock() }
            if !prepared && ["file.begin", "file.total", "file.stable_copy_and_hash"].contains(operation) {
                prepared = true; log.write("prepare.ready", "backup", context: self, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
            if !uploading && operation == "file.upload" {
                uploading = true; log.write("transfer.first", "backup", context: self, ms: (ProcessInfo.processInfo.systemUptime - started) * 1000)
            }
        }
        fileprivate func note(_ operation: String, ms: Double) {
            lock.lock(); defer { lock.unlock() }
            if !prepared && operation.hasPrefix("prepare.") { log.write("prepare.phase", operation, context: self, ms: ms) }
        }
        fileprivate func finish() {
            lock.lock(); if !stage.isEmpty { totals[stage, default: 0] += (ProcessInfo.processInfo.systemUptime - stageStart) * 1000 }; let summary = totals; lock.unlock()
            for (label, ms) in summary { log.write("reported_stage.wall", "backup", context: self, ms: ms, detail: label) }
        }
    }
    public static func withRun(_ job: BackupJob, full: Bool, operation: () async throws -> BackupResult) async throws -> BackupResult {
        if run != nil || current == nil { return try await operation() }
        let context = Run(current!), start = ProcessInfo.processInfo.systemUptime
        return try await $run.withValue(context) {
            context.log.write("run.start", "backup", context: context,
                              detail: "job=\(context.log.tag(job.id.uuidString));provider=\(job.cloudProvider?.rawValue ?? "local");mode=\(job.mode.rawValue);full=\(full)")
            do {
                let result = try await operation()
                for issue in result.issues { event("file.error", "backup", path: issue.path, detail: issue.automaticNetworkRetry ? "network_retry" : issue.conflict ? "conflict" : issue.waiting != nil ? "locked" : "review_or_retry") }
                event("run.result", "backup", completed: result.copied, total: result.skipped,
                      detail: "copied=\(result.copied);skipped=\(result.skipped);trash=\(result.removed);issues=\(result.issues.count)")
                context.finish(); event("run.end", "backup", ms: (ProcessInfo.processInfo.systemUptime - start) * 1000, detail: "returned"); return result
            } catch {
                context.finish(); event("run.error", "backup", ms: (ProcessInfo.processInfo.systemUptime - start) * 1000, error: error); throw error
            }
        }
    }
    public static func endpoint(_ url: URL) -> String {
        let p = url.path
        if p.contains("/token") { return "oauth.token" }
        if (url.host ?? "").hasSuffix("googleapis.com") {
            if p.contains("/upload/") { return "drive.upload" }
            if p == "/batch/drive/v3" { return "drive.batch" }
            if p.contains("/changes") { return "drive.changes" }
            if p == "/drive/v3/files" { return "drive.list_or_create" }
            if p.hasPrefix("/drive/v3/files/") { return "drive.file" }; return "drive.other"
        }
        let routes = ["/2/files/list_folder": "dropbox.list", "/2/files/list_folder/continue": "dropbox.changes", "/2/files/get_metadata": "dropbox.metadata", "/2/files/download": "dropbox.download", "/2/files/move_v2": "dropbox.move", "/2/files/upload_session/start": "dropbox.upload.start", "/2/files/upload_session/append_v2": "dropbox.upload.append", "/2/files/upload_session/finish": "dropbox.upload.finish"]
        return routes[p] ?? "dropbox.other"
    }
}
