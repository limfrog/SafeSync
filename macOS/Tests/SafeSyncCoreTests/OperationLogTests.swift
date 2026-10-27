import XCTest
@testable import SafeSyncCore

final class OperationLogTests: XCTestCase {
    func testBackupTraceCorrelationAndPrivacy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("private-source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("secret-payload".utf8).write(to: source.appendingPathComponent("private-name.txt"))
        var job = BackupJob(); job.name = "private-job"; job.source = source.path; job.destination = target.path
        let engine = BackupEngine(dataDirectory: root.appendingPathComponent("data"))
        let log = OperationLog.start(directory: root, version: "test")
        defer { log.close() }
        let first = try await OperationLog.withRun(job, full: true) {
            let result = try await engine.run(job, fullScan: true)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<20 { group.addTask { OperationLog.event("parallel", "test", path: "private-name.txt") } }
            }
            OperationLog.event("file.error", "test", error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-token https://secret/session"]))
            return result
        }
        XCTAssertEqual(first.copied, 1)
        let second = try await OperationLog.withRun(job, full: false) { try await engine.run(job, changedPaths: []) }
        XCTAssertEqual(second.copied, 0); XCTAssertTrue(second.issues.isEmpty)
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("logs/operations"), includingPropertiesForKeys: nil)
        let text = try files.filter { $0.lastPathComponent.hasPrefix("Diagnostic-") }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        let summary = try files.filter { $0.lastPathComponent.hasPrefix("Summary-") }.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        XCTAssertTrue(summary.contains("prepare.ready")); XCTAssertTrue(summary.contains("prepare.phase"))
        for secret in ["private-source", "private-name", "private-job", "secret-payload", "secret-token", "https://secret"] { XCTAssertFalse(text.contains(secret)) }
        let rows = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(rows.filter { $0["Event"] as? String == "run.end" }.count, 2)
        let parallel = rows.filter { $0["Event"] as? String == "parallel" }
        XCTAssertEqual(parallel.count, 20)
        XCTAssertEqual(Set(parallel.compactMap { $0["Run"] as? String }).count, 1)
        XCTAssertEqual(Set(parallel.compactMap { $0["File"] as? String }).count, 1)
        XCTAssertTrue(rows.contains { $0["Operation"] as? String == "prepare.source_scan" })
        XCTAssertTrue(rows.contains { $0["Operation"] as? String == "prepare.state_load" })
        XCTAssertTrue(rows.compactMap { $0["Ms"] as? Double }.allSatisfy { $0 >= 0 })
        XCTAssertEqual(OperationLog.endpoint(URL(string: "https://www.googleapis.com/upload/drive/v3/files/private?upload_id=secret")!), "drive.upload")
    }
    func testRotationAndBrokenLogFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-log-limit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("logs/operations")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<12 {
            let file = folder.appendingPathComponent("Diagnostic-old-\(i).jsonl")
            try Data("old".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86400)], ofItemAtPath: file.path)
        }
        let log = OperationLog.start(directory: root, version: "test")
        for i in 0..<6000 { OperationLog.event("volume", "test", detail: String(repeating: "x", count: 2000)); if i % 200 == 0 { log.flush() } }
        log.close()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertGreaterThanOrEqual(files.count, 2); XCTAssertLessThanOrEqual(files.count, OperationLog.fileCount)
        XCTAssertFalse(files.contains { $0.lastPathComponent.hasPrefix("Diagnostic-old-") })
        for file in files { XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, OperationLog.fileLimit) }
        let broken = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not-directory".utf8).write(to: broken.appendingPathComponent("logs"))
        let failedLog = OperationLog.start(directory: broken, version: "test")
        OperationLog.event("test", "broken"); failedLog.flush(); failedLog.close()
    }
}
