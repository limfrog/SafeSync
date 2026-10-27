import Foundation
import CryptoKit

public enum RecoveryBatch {
    @TaskLocal public static var id: String?
    public static func withRun<T>(_ operation: () throws -> T) rethrows -> T {
        if id != nil { return try operation() }; return try $id.withValue(UUID().uuidString, operation: operation)
    }
    public static func withRun<T>(_ operation: () async throws -> T) async rethrows -> T {
        if id != nil { return try await operation() }; return try await $id.withValue(UUID().uuidString, operation: operation)
    }
}
public struct MassChange: Codable, Sendable, Identifiable {
    public var path: String, side: String, action: String, before: String, after: String
    public var id: String { path + "\u{1f}" + side }
}
public struct MassChangeProposal: Codable, Identifiable, Sendable {
    public var jobID: UUID, binding: String, fingerprint: String, baseline: Int, created: Date, changes: [MassChange]
    public var id: String { fingerprint }
}
public struct MassChangeBlocked: LocalizedError, Sendable {
    public var count: Int, baseline: Int
    public var errorDescription: String? { "대량 변경 보호: 기존 \(baseline)개 중 \(count)개 파일의 변경·삭제를 보류했습니다. 작업 관리의 대량 변경 검토에서 확인하세요." }
}
public enum MassChanges {
    private static func url(_ directory: URL, _ job: BackupJob, _ suffix: String = "") -> URL { directory.appendingPathComponent("mass-change/\(job.id)\(suffix).json") }
    private static func binding(_ job: BackupJob) -> String {
        [job.id.uuidString, job.source, job.destination, job.mode.rawValue, job.cloudProvider?.rawValue ?? "local", job.cloudAccountID?.uuidString ?? "", job.cloudFolderID ?? "", job.cloudAccessMode ?? "", String(job.mirrorDeletes), String(job.massMinimum), String(job.massPercent)].joined(separator: "\u{1f}")
    }
    public static func pending(directory: URL, job: BackupJob) throws -> MassChangeProposal? {
        guard job.protectMassChanges, FileManager.default.fileExists(atPath: url(directory,job).path) else { return nil }
        let proposal = try Storage.load(MassChangeProposal.self, from: url(directory,job))
        return proposal.jobID == job.id && proposal.binding == binding(job) ? proposal : nil
    }
    public static func blocked(directory: URL, job: BackupJob) -> Bool { FileManager.default.fileExists(atPath: url(directory,job).path) }
    public static func approve(directory: URL, job: BackupJob, fingerprint: String) throws {
        guard let proposal = try pending(directory: directory, job: job), proposal.fingerprint == fingerprint else { throw BackupError.unsafe("검토 중 변경 목록 또는 작업 위치가 달라졌습니다. 다시 확인하세요.") }
        try Storage.save(proposal, to: url(directory,job,"-approval"))
    }
    public static func stamp(_ value: FileStamp?) -> String {
        guard let value else { return "missing" }; return "\(value.size)|\(value.modified.timeIntervalSince1970)|\(value.created.timeIntervalSince1970)"
    }
    public static func differences(prior: [String: FileStamp], current: [String: FileStamp], side: String, deletion: Bool) -> [MassChange] {
        prior.compactMap { path, old in
            let value = current[path]; guard value != old, value != nil || deletion else { return nil }
            return MassChange(path: path, side: side, action: value == nil ? "삭제" : "변경", before: stamp(old), after: stamp(value))
        }
    }
    public static func localStamps(root: URL, paths: Set<String>) throws -> [String: FileStamp] {
        var output: [String: FileStamp] = [:]
        for path in paths {
            try FileComparisons.validatePath(path)
            try Task.checkCancellation(); if !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { continue }; let file = try SourceScanner.file(root, path: path)
            if FileManager.default.fileExists(atPath: file.path), (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true { output[path] = try FileStamp(file) }
        }
        return output
    }
    public static func check(directory: URL, job: BackupJob, baseline: Int, changes: [MassChange], roots: String) throws {
        if !job.protectMassChanges { for suffix in ["","-approval"] { let path = url(directory,job,suffix); if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) } }; return }
        guard (1...1_000_000).contains(job.massMinimum), (1...100).contains(job.massPercent) else { throw BackupError.unsafe("대량 변경 기준은 1~1,000,000개, 1~100%입니다.") }
        func clear() throws { for suffix in ["", "-approval"] { let path = url(directory,job,suffix); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } } }
        let count = Set(changes.map(\.path)).count
        guard baseline >= job.massMinimum, count >= job.massMinimum, count * 100 >= baseline * job.massPercent else { try clear(); return }
        let ordered = changes.sorted { ($0.path,$0.side) < ($1.path,$1.side) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = binding(job), body = Data((key+roots).utf8) + (try encoder.encode(ordered))
        let fingerprint = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let approval = url(directory,job,"-approval")
        if FileManager.default.fileExists(atPath: approval.path) {
            let allowed = try Storage.load(MassChangeProposal.self, from: approval); try FileManager.default.removeItem(at: approval)
            if allowed.jobID == job.id, allowed.binding == key, allowed.fingerprint == fingerprint { try clear(); return }
        }
        try Storage.save(MassChangeProposal(jobID: job.id, binding: key, fingerprint: fingerprint, baseline: baseline, created: Date(), changes: ordered), to: url(directory,job))
        throw MassChangeBlocked(count: count, baseline: baseline)
    }
}
