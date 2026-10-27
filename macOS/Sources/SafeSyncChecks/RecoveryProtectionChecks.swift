import Foundation
import SafeSyncCore

enum RecoveryProtectionChecks {
    static func run() async throws {
        for provider in CloudProvider.allCases {
            let (root, original, engine, cloud) = try CloudChecks.fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            var job = original; job.massMinimum = 3; job.massPercent = 30
            let source = URL(fileURLWithPath: job.source), directory = root.appendingPathComponent("settings")
            for i in 0..<8 { let file = source.appendingPathComponent("\(i).txt"); try Data("old \(i)".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: file.path) }
            let first = try await engine.run(job, storage: cloud); checkEqual(first.copied, 8)
            for i in 0..<4 { let file = source.appendingPathComponent("\(i).txt"); try Data("new \(i)".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: file.path) }
            do { _ = try await engine.run(job, storage: cloud); check(false) } catch is MassChangeBlocked { }
            checkEqual(await cloud.bytes(name: "0.txt", parent: job.cloudFolderID!), Data("old 0".utf8))
            guard let proposal = try MassChanges.pending(directory: directory, job: job) else { throw BackupError.unsafe("Missing mass proposal") }
            try MassChanges.approve(directory: directory, job: job, fingerprint: proposal.fingerprint)
            let next = try await engine.run(job, storage: cloud); checkEqual(next.copied, 4); check(next.issues.isEmpty)
            let verified = try await engine.verifyBackup(job,storage:cloud); checkEqual(verified.count,8);check(verified.allSatisfy{$0.status == "정상"})
            let items = try await engine.listTrash(job, storage: cloud); checkEqual(items.count, 4); checkEqual(Set(items.compactMap(\.batchID)).count, 1)
            check(try await engine.verifyTrash(items[0], job: job, storage: cloud))
            await cloud.setDigest(name: "payload", kind: "sha256", hash: "corrupt")
            do { try await engine.restore([items[0]], job: job, storage: cloud); check(false) } catch { }
            checkEqual(await cloud.bytes(name: "0.txt", parent: job.cloudFolderID!), Data("new 0".utf8))
            print("PASS \(provider.title): mass change blocked before writes, exact approval, grouped archive, streamed restore verification and corrupt-copy refusal")
        }
        let fixture = BackupTests()
        let (root,original,_) = try fixture.fixture(); defer { try? FileManager.default.removeItem(at:root) }
        var job = original;job.syncMode = .twoWay;job.massMinimum = 3;job.massPercent = 30
        let state = root.appendingPathComponent("state"), left = URL(fileURLWithPath:job.source), right = URL(fileURLWithPath:job.destination)
        for i in 0..<8 { try fixture.write("old \(i)",left.appendingPathComponent("\(i).txt")) }
        let sync = SyncCoordinator(dataDirectory:state); _ = try await sync.run(job)
        let verified = try await sync.verifyBackup(job);checkEqual(verified.count,8);check(verified.allSatisfy{$0.status == "정상"})
        for i in 0..<4 { try FileManager.default.removeItem(at:right.appendingPathComponent("\(i).txt")) }
        do { _ = try await sync.run(job);check(false) } catch is MassChangeBlocked { }
        for i in 0..<8 { check(FileManager.default.fileExists(atPath:left.appendingPathComponent("\(i).txt").path)) }
        guard let proposal = try MassChanges.pending(directory:state,job:job) else { throw BackupError.unsafe("Missing reverse delete review") }
        try MassChanges.approve(directory:state,job:job,fingerprint:proposal.fingerprint)
        let result = try await sync.run(job);checkEqual(result.removed,4);check(result.issues.isEmpty)
        print("PASS two-way mass reverse deletion blocks before mutations and current backup verifies without replacing originals")
    }
}
