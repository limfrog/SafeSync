import XCTest
@testable import SafeSyncCore

final class RecoveryProtectionTests: XCTestCase {
    func testMassBlockApprovalStaleAndGroupedVerifiedRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("backup"), state = root.appendingPathComponent("state")
        for folder in [source,target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var job = BackupJob(); job.name = "protection"; job.source = source.path; job.destination = target.path; job.massMinimum = 3; job.massPercent = 30
        for i in 0..<8 { try Data("old \(i)".utf8).write(to: source.appendingPathComponent("\(i).txt")); try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: source.appendingPathComponent("\(i).txt").path) }
        let engine = BackupEngine(dataDirectory: state)
        let first = try await engine.run(job, fullScan: true); XCTAssertEqual(first.copied, 8)
        let verified = try await engine.verifyBackup(job); XCTAssertEqual(verified.count,8); XCTAssertTrue(verified.allSatisfy { $0.status == "정상" })
        for i in 0..<4 { try Data("new \(i)".utf8).write(to: source.appendingPathComponent("\(i).txt")); try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: source.appendingPathComponent("\(i).txt").path) }
        do { _ = try await engine.run(job, fullScan: true); XCTFail("Mass changes ran without review") } catch is MassChangeBlocked { }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("0.txt"), encoding: .utf8), "old 0")
        let proposal = try XCTUnwrap(MassChanges.pending(directory: state, job: job)); XCTAssertEqual(proposal.changes.count, 4)
        try MassChanges.approve(directory: state, job: job, fingerprint: proposal.fingerprint)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2001)], ofItemAtPath: source.appendingPathComponent("0.txt").path)
        do { _ = try await engine.run(job, fullScan: true); XCTFail("Stale approval ran") } catch is MassChangeBlocked { }
        let updated = try XCTUnwrap(MassChanges.pending(directory: state, job: job)); try MassChanges.approve(directory: state, job: job, fingerprint: updated.fingerprint)
        let result = try await engine.run(job, fullScan: true); XCTAssertEqual(result.copied, 4); XCTAssertTrue(result.issues.isEmpty)
        let trash = try await engine.listTrash(job); XCTAssertEqual(trash.count, 4); XCTAssertEqual(Set(trash.compactMap(\.batchID)).count, 1)
        XCTAssertNil(try MassChanges.pending(directory: state, job: job))
        let known = try await engine.verifyTrash(trash[0], job: job); XCTAssertTrue(known)
        let corrupt = target.appendingPathComponent(".safesync-trash/\(trash[0].id).data")
        var bytes = try Data(contentsOf: corrupt); bytes[0] ^= 1; try bytes.write(to: corrupt)
        let before = try Data(contentsOf: target.appendingPathComponent(trash[0].path))
        do { try await engine.restore(trash[0], job: job); XCTFail("Corrupt archive restored") } catch { }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(trash[0].path)), before)
        try await engine.restore(trash[1], job: job)
        XCTAssertTrue(try String(contentsOf: target.appendingPathComponent(trash[1].path), encoding: .utf8).hasPrefix("old "))
    }
    func testLegacyJobDefaultsAndMassProposalBinding() throws {
        var job = try JSONDecoder().decode(BackupJob.self, from: Data("{\"id\":\"\(UUID())\",\"name\":\"legacy\",\"source\":\"/tmp/s\",\"destination\":\"/tmp/d\",\"scheduled\":false,\"scheduleTime\":\"23:00\",\"mirrorDeletes\":true,\"paused\":false}".utf8))
        XCTAssertTrue(job.protectMassChanges); XCTAssertEqual(job.massMinimum, 100); XCTAssertEqual(job.massPercent, 20)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-proposal-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        job.massMinimum = 1; job.massPercent = 1
        let change = MassChange(path: "a", side: "원본", action: "삭제", before: "x", after: "missing")
        XCTAssertThrowsError(try MassChanges.check(directory: root, job: job, baseline: 1, changes: [change], roots: "root1"))
        let proposal = try XCTUnwrap(MassChanges.pending(directory: root, job: job)); job.destination = "/tmp/other"
        XCTAssertThrowsError(try MassChanges.approve(directory: root, job: job, fingerprint: proposal.fingerprint))
    }
    func testCurrentBackupVerificationDetectsCorruptionWithoutSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-verify-\(UUID())"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), backup = root.appendingPathComponent("backup")
        for folder in [source,backup] { try FileManager.default.createDirectory(at: folder,withIntermediateDirectories:true) }
        try Data("original".utf8).write(to:source.appendingPathComponent("a"))
        var job = BackupJob(); job.name = "verify";job.source = source.path;job.destination = backup.path
        let engine = BackupEngine(dataDirectory:root.appendingPathComponent("state")); _ = try await engine.run(job,fullScan:true)
        try Data("corrupt!".utf8).write(to:backup.appendingPathComponent("a"));try FileManager.default.removeItem(at:source)
        let rows = try await engine.verifyBackup(job);XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].status,"실패")
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("a")),Data("corrupt!".utf8))
    }
}
