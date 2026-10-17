import XCTest
@testable import SafeSyncCore

final class BackupTests: XCTestCase {
    func fixture() throws -> (URL, BackupJob, BackupEngine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-test-\(UUID())")
        let source = root.appendingPathComponent("source"), backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        var job = BackupJob(); job.name = "테스트"; job.source = source.path; job.destination = backup.path
        return (root, job, BackupEngine(dataDirectory: root.appendingPathComponent("settings")))
    }
    func write(_ text: String, _ url: URL, time: TimeInterval = 1000) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
    }
    func testCopyOverwriteDeleteAndRestore() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source).appendingPathComponent("한글.txt"), dst = URL(fileURLWithPath: job.destination).appendingPathComponent("한글.txt")
        try write("first", src)
        let first = try await engine.run(job); XCTAssertEqual(first.copied, 1)
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "first")
        let again = try await engine.run(job); XCTAssertEqual(again.skipped, 1)
        try write("second", src, time: 2000)
        let second = try await engine.run(job); XCTAssertEqual(second.copied, 1)
        var trash = try await engine.listTrash(job); XCTAssertEqual(trash.count, 1)
        try FileManager.default.removeItem(at: src)
        let deleted = try await engine.run(job); XCTAssertEqual(deleted.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path))
        trash = try await engine.listTrash(job); XCTAssertEqual(trash.count, 2)
        try await engine.restore(trash.first!, job: job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testConflictDoesNotBlockOtherFileAndKeepBoth() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source), dst = URL(fileURLWithPath: job.destination)
        try write("source", src.appendingPathComponent("a"))
        try write("newer backup", dst.appendingPathComponent("a"), time: 3000)
        try write("other", src.appendingPathComponent("b"))
        let result = try await engine.run(job)
        XCTAssertEqual(result.issues.count, 1); XCTAssertEqual(result.copied, 1)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a"), encoding: .utf8), "newer backup")
        try await engine.resolve(result.issues[0], job: job, action: .keepBoth)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a"), encoding: .utf8), "source")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dst.path).contains { $0.contains("SafeSync-conflict") })
    }
    func testDisconnectedSourceDoesNotDeleteBackup() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source).appendingPathComponent("a"), dst = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
        try write("safe", src); _ = try await engine.run(job)
        try FileManager.default.removeItem(atPath: job.source)
        do { _ = try await engine.run(job); XCTFail("Must reject unavailable source") } catch {}
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "safe")
    }
    func testDestinationSymlinkCannotEscape() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source), dst = URL(fileURLWithPath: job.destination), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("safe", src.appendingPathComponent("nested/a"))
        try FileManager.default.createSymbolicLink(at: dst.appendingPathComponent("nested"), withDestinationURL: outside)
        let result = try await engine.run(job)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("a").path))
    }
    func testNestedRootsRejected() throws {
        let (root, job, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var bad = job; bad.destination = job.source
        XCTAssertThrowsError(try BackupEngine.validate(bad))
    }
    func testMirrorOffPreservesDeletedFile() async throws {
        let (root, original, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var job = original; job.mirrorDeletes = false
        let src = URL(fileURLWithPath: job.source).appendingPathComponent("a"), dst = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
        try write("safe", src); _ = try await engine.run(job)
        try FileManager.default.removeItem(at: src); _ = try await engine.run(job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }

    func testExternalDeletionPreserved() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source).appendingPathComponent("a"), dst = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
        try write("safe", src); _ = try await engine.run(job)
        try FileManager.default.removeItem(at: dst); let result = try await engine.run(job)
        XCTAssertEqual(result.copied, 1)
        let items = try await engine.listTrash(job); XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "safe")
    }
    func testRecoveryAfterAtomicExchange() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dst = URL(fileURLWithPath: job.destination), src = URL(fileURLWithPath: job.source).appendingPathComponent("a")
        try write("new", src, time: 2000); try write("new", dst.appendingPathComponent("a"), time: 2000)
        let staging = dst.appendingPathComponent(".safesync-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try write("old", staging.appendingPathComponent("interrupted.data"))
        let trashID = UUID()
        let tx: [String: Any] = ["destination": "a", "temporary": ".safesync-staging/interrupted.data", "expectedHash": try BackupEngine.hash(src), "trash": ["id": trashID.uuidString, "path": "a", "deletedAt": Date().timeIntervalSinceReferenceDate, "size": 3]]
        try JSONSerialization.data(withJSONObject: tx).write(to: staging.appendingPathComponent("interrupted.json"))
        _ = try await engine.run(job)
        let items = try await engine.listTrash(job); XCTAssertEqual(items.count, 1)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent(".safesync-trash/\(trashID).data"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("a"), encoding: .utf8), "new")
    }
    func testCorruptManifestStopsBeforeDeletion() async throws {
        let (root, job, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source).appendingPathComponent("a"), dst = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
        try write("safe", src); _ = try await engine.run(job); try FileManager.default.removeItem(at: src)
        try Data("broken".utf8).write(to: root.appendingPathComponent("settings/manifests/\(job.id).json"))
        do { _ = try await engine.run(job); XCTFail("Corrupt manifest must stop backup") } catch {}
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "safe")
    }
    func testChangedRootsRejected() async throws {
        let (root, original, engine) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: original.source).appendingPathComponent("a")
        try write("safe", src); _ = try await engine.run(original)
        let newSource = root.appendingPathComponent("new-source")
        try FileManager.default.createDirectory(at: newSource, withIntermediateDirectories: true)
        var job = original; job.source = newSource.path
        do { _ = try await engine.run(job); XCTFail("Changed roots must not reuse old manifest") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: job.destination).appendingPathComponent("a").path))
    }
}
