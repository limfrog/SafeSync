import Foundation
import Darwin
import SafeSyncCore

enum TwoWayChecks {
    static func run() async throws {
        let t = BackupTests()
        do {
            let (root, original, _) = try t.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            var job = original; job.syncMode = .twoWay
            let a = URL(fileURLWithPath: job.source), b = URL(fileURLWithPath: job.destination)
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            try t.write("left", a.appendingPathComponent("left")); try t.write("right", b.appendingPathComponent("right"))
            try FileManager.default.createDirectory(at: a.appendingPathComponent("empty"), withIntermediateDirectories: true)
            let first = try await sync.run(job); check(first.issues.isEmpty); checkEqual(first.copied, 3)
            checkEqual(try String(contentsOf: a.appendingPathComponent("right"), encoding: .utf8), "right")
            check(FileManager.default.fileExists(atPath: b.appendingPathComponent("empty").path))
            print("PASS two-way initial union copies both directions and empty directories")
            try t.write("backup edit with older timestamp", b.appendingPathComponent("left"), time: 1)
            let reverse = try await sync.run(job); check(reverse.issues.isEmpty)
            checkEqual(try String(contentsOf: a.appendingPathComponent("left"), encoding: .utf8), "backup edit with older timestamp")
            var sourceJob = job; sourceJob.destination = job.source
            let trash = try await BackupEngine(dataDirectory: root.appendingPathComponent("state")).listTrash(sourceJob); checkEqual(trash.count, 1)
            print("PASS two-way baseline detects backup edit independent of clock and preserves old source in source trash")
            try t.write("source concurrent", a.appendingPathComponent("left"), time: 9000); try t.write("backup concurrent", b.appendingPathComponent("left"), time: 2)
            let conflict = try await sync.run(job); checkEqual(conflict.issues.count, 1); check(conflict.issues[0].conflict)
            let repeated = try await sync.run(job); checkEqual(repeated.issues.count, 1)
            print("PASS two-way simultaneous edits remain conflicts without advancing common baseline")
            let comparison = try await FileComparisons.read(job: job, path: "left")
            _ = try await sync.apply([ResolutionDecision(comparison, action: .useBackup)], job: job)
            let resolved = try await sync.run(job); check(resolved.issues.isEmpty)
            checkEqual(try String(contentsOf: a.appendingPathComponent("left"), encoding: .utf8), "backup concurrent")
            try FileManager.default.removeItem(at: b.appendingPathComponent("right"))
            let deleted = try await sync.run(job); check(deleted.issues.isEmpty); checkEqual(deleted.removed, 1)
            checkFalse(FileManager.default.fileExists(atPath: a.appendingPathComponent("right").path))
            print("PASS explicit reverse conflict choice and verified backup deletion propagate safely")
            // Replacing a root with an empty directory must not delete the surviving copy.
            try FileManager.default.moveItem(at: b, to: root.appendingPathComponent("disconnected")); try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            do { _ = try await sync.run(job); fail("Root identity changed") } catch {}
            check(FileManager.default.fileExists(atPath: a.appendingPathComponent("left").path))
            print("PASS two-way replaced/unavailable root cannot authorize deletions")
        }
        do {
            let (root, job, _) = try t.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let a = URL(fileURLWithPath: job.source), b = URL(fileURLWithPath: job.destination)
            for name in ["one", "two"] { try t.write("source " + name, a.appendingPathComponent(name)); try t.write("backup " + name, b.appendingPathComponent(name)) }
            let first = try await FileComparisons.read(job: job, path: "one"), second = try await FileComparisons.read(job: job, path: "two")
            // Same size and modified timestamp: checksum validation still catches the change.
            try t.write("source NEW", a.appendingPathComponent("two"))
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            do { _ = try await sync.apply([ResolutionDecision(first, action: .overwrite), ResolutionDecision(second, action: .overwrite)], job: job); fail("Stale batch accepted") } catch {}
            checkEqual(try String(contentsOf: b.appendingPathComponent("one"), encoding: .utf8), "backup one")
            _ = try await sync.apply([ResolutionDecision(first, action: .ignore)], job: job)
            checkEqual(try String(contentsOf: b.appendingPathComponent("one"), encoding: .utf8), "backup one")
            print("PASS entire conflict selection preflight prevents partial changes and ignore preserves both copies")
        }
        for provider in CloudProvider.allCases {
            let (root, original, _, storage) = try CloudChecks.fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            var job = original; job.syncMode = .twoWay
            try CloudChecks.write("initial", job: job)
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            let initial = try await sync.run(job, storage: storage); check(initial.issues.isEmpty)
            let old = await storage.children(job.cloudFolderID!).first { $0.name == "a.txt" }!
            await storage.remove(old)
            let upload = root.appendingPathComponent("external"); try Data("remote edit".utf8).write(to: upload)
            _ = try await storage.upload(file: upload, name: "a.txt", parent: job.cloudFolderID!, modified: Date(timeIntervalSince1970: 1), resumeKey: "external")
            let reversed = try await sync.run(job, storage: storage); check(reversed.issues.isEmpty)
            checkEqual(try String(contentsOf: URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"), encoding: .utf8), "remote edit")
            try FileManager.default.removeItem(at: URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"))
            let removed = try await sync.run(job, storage: storage); check(removed.issues.isEmpty); checkEqual(removed.removed, 1)
            check(await storage.children(job.cloudFolderID!).allSatisfy { $0.name != "a.txt" })
            print("PASS \(provider.title) two-way upload, external edit download, checksum validation and deletion to remote trash")
        }
        do {
            let (root, job, engine, cloud) = try CloudChecks.fixture(.googleDrive); defer { try? FileManager.default.removeItem(at: root) }
            try CloudChecks.write("same", job: job)
            let file = URL(fileURLWithPath: job.source).appendingPathComponent("a.txt")
            for _ in 0..<2 { _ = try await cloud.upload(file: file, name: "a.txt", parent: "root", modified: Date(), resumeKey: "duplicate") }
            let same = try await engine.run(job, storage: cloud); check(same.issues.isEmpty); checkEqual(same.skipped, 1)
            try CloudChecks.write("different", job: job)
            let different = try await engine.run(job, storage: cloud); checkEqual(different.issues.count, 1); check(different.issues[0].conflict)
            let c = try await FileComparisons.read(job: job, path: "a.txt", storage: cloud)
            checkEqual(c.candidates.count, 2)
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            _ = try await sync.apply([ResolutionDecision(c, action: .normalizeDuplicates)], job: job, storage: cloud)
            let copies = await cloud.children("root"); checkEqual(copies.count, 2); checkEqual(copies.filter { $0.name == "a.txt" }.count, 1)
            check(copies.contains { $0.name.contains("SafeSync-conflict") })
            print("PASS Drive identical duplicates skip upload; differing duplicates conflict; normalization preserves every ID and copy")
        }
        do {
            let (root, job, _) = try t.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let a = URL(fileURLWithPath: job.source), b = URL(fileURLWithPath: job.destination)
            try t.write("lock", a.appendingPathComponent("busy")); try t.write("other", a.appendingPathComponent("other"))
            let fd = Darwin.open(a.appendingPathComponent("busy").path, O_RDWR); check(fd >= 0); checkEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            let busy = try await sync.run(job); checkEqual(busy.issues.count, 1); check(busy.issues[0].waiting != nil); checkFalse(busy.issues[0].conflict)
            check(FileManager.default.fileExists(atPath: b.appendingPathComponent("other").path))
            flock(fd, LOCK_UN); Darwin.close(fd)
            let retry = try await sync.run(job); check(retry.issues.isEmpty)
            print("PASS two-way busy file waits independently and succeeds after unlock")
        }
        do {
            let (root, job, local) = try t.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let folder = URL(fileURLWithPath: job.source).appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            _ = try await sync.run(job); try FileManager.default.removeItem(at: folder)
            let deleted = try await sync.run(job); checkEqual(deleted.removed, 1)
            let trash = try await local.listTrash(job); checkEqual(trash.count, 1); check(trash[0].directory == true)
            try await local.restore(trash[0], job: job)
            check(FileManager.default.fileExists(atPath: URL(fileURLWithPath: job.destination).appendingPathComponent("empty").path))
            print("PASS two-way empty folder deletion retains a recoverable directory trash entry")
        }
        do {
            let (root, job, engine, cloud) = try CloudChecks.fixture(.googleDrive); defer { try? FileManager.default.removeItem(at: root) }
            let parent1 = await cloud.createFolder(name: "folder", parent: "root"), parent2 = await cloud.createFolder(name: "folder", parent: "root")
            let folder = URL(fileURLWithPath: job.source).appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("a"); try Data("same".utf8).write(to: file)
            for parent in [parent1, parent2] { _ = try await cloud.upload(file: file, name: "a", parent: parent.id, modified: Date(), resumeKey: "nested") }
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            let result = try await sync.run(job, storage: cloud); check(result.issues.isEmpty)
            try FileManager.default.removeItem(at: file)
            let missing = try await sync.run(job, storage: cloud); check(missing.issues.contains { $0.path == "folder/a" && $0.conflict })
            checkEqual(await cloud.children(parent1.id).count, 1); checkEqual(await cloud.children(parent2.id).count, 1)
            let c = try await FileComparisons.read(job: job, path: "folder/a", storage: cloud)
            _ = try await sync.apply([ResolutionDecision(c, action: .normalizeDuplicates)], job: job, storage: cloud)
            checkEqual(await cloud.children(parent1.id).count, 1); checkEqual(await cloud.children(parent2.id).count, 1)
            checkEqual(await cloud.children("root").filter { $0.folder }.count, 2)
            _ = engine
            print("PASS duplicate parent folders preserve all children and never grant automatic deletion authority")
        }
        do {
            let (root, job, engine, cloud) = try CloudChecks.fixture(.googleDrive); defer { try? FileManager.default.removeItem(at: root) }
            let folder = URL(fileURLWithPath: job.source).appendingPathComponent("empty")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            _ = try await sync.run(job, storage: cloud); try FileManager.default.removeItem(at: folder)
            let deleted = try await sync.run(job, storage: cloud); checkEqual(deleted.removed, 1)
            let trash = try await engine.listTrash(job, storage: cloud); checkEqual(trash.count, 1); check(trash[0].directory == true)
            try await engine.restore(trash, job: job, storage: cloud)
            check(await cloud.children("root").contains { $0.name == "empty" && $0.folder })
            print("PASS remote empty folder deletion and ID-preserving directory trash restore")
        }
        do {
            let (root, job, _) = try t.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let source = URL(fileURLWithPath: job.source), target = URL(fileURLWithPath: job.destination)
            try t.write("unchanged", source.appendingPathComponent("cancel"))
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
            let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
            let worker = Task.detached {
                try await sync.run(job, progress: { p in
                    if p.stage == "양방향 비교·반영" { started.signal(); _ = proceed.wait(timeout: .now() + 5) }
                })
            }
            let reached = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + 5) == .success) }
            }
            check(reached); worker.cancel(); proceed.signal()
            do { _ = try await worker.value; fail("Canceled sync continued") } catch is CancellationError {} catch { throw error }
            checkFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("cancel").path))
            let resumed = try await sync.run(job); check(resumed.issues.isEmpty); checkEqual(resumed.copied, 1)
            print("PASS two-way cancellation at a file boundary prevents mutation and releases the persistent lease for retry")
        }
        var portable = BackupJob(); portable.name = "two-way"; portable.source = "/tmp/source"; portable.destination = "/tmp/dest"; portable.syncMode = .twoWay; portable.stopped = true
        let decoded = try JobListCodec.decode(JobListCodec.encode([portable])); checkEqual(decoded.Jobs[0].SyncMode, "TwoWay")
        let planned = try JobListCodec.plan(decoded, replacing: []); checkEqual(planned.jobs[0].mode, .twoWay); checkEqual(planned.jobs[0].stopped, true)
        print("PASS Windows job-list round-trip preserves TwoWay mode")
    }
}
