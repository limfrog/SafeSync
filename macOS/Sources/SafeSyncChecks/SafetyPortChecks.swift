import Foundation
import Darwin
import SafeSyncCore

/// All paths and remote items are disposable fixtures. No user configuration or
/// credential store is read, and MemoryCloud never sends an HTTP request.
struct SafetyPortChecks {
    private static func legacy(_ url: URL) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object.removeValue(forKey: "sourceIdentity")
        object.removeValue(forKey: "destinationIdentity")
        object.removeValue(forKey: "remoteRootIdentity")
        var files = object["files"] as! [String: [String: Any]]
        for path in Array(files.keys) { files[path]?.removeValue(forKey: "verificationVersion") }
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
    }

    static func run() async throws {
        let fm = FileManager.default, tests = BackupTests()
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
            let a = URL(fileURLWithPath: job.source).appendingPathComponent("a")
            let b = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
            try tests.write("AAAA", a); _ = try await engine.run(job)
            let stamp = try FileStamp(a)
            try tests.write("BBBB", a)
            checkEqual(try FileStamp(a), stamp)
            let result = try await engine.run(job, changedPaths: ["a"])
            checkEqual(result.copied, 0); checkEqual(result.skipped, 0); checkEqual(result.issues.count, 1)
            check(result.issues[0].conflict); checkEqual(try String(contentsOf: b, encoding: .utf8), "AAAA")
            print("PASS safety port: same metadata with different bytes remains a conflict")
            try tests.write("AAAA", a)
            let identical = try await engine.run(job, changedPaths: ["a"])
            checkEqual(identical.skipped, 1); check(identical.issues.isEmpty)
            print("PASS safety port: genuinely identical bytes skip without a false conflict")
        }
        for replacingSource in [true, false] {
            let (root, job, engine) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
            try tests.write("safe", URL(fileURLWithPath: job.source).appendingPathComponent("a"))
            _ = try await engine.run(job)
            let changed = URL(fileURLWithPath: replacingSource ? job.source : job.destination)
            let held = root.appendingPathComponent("retained-original")
            try fm.moveItem(at: changed, to: held); try fm.createDirectory(at: changed, withIntermediateDirectories: true)
            do { _ = try await engine.run(job); fail("Replaced root must be rejected") } catch {}
            let preserved = replacingSource ? URL(fileURLWithPath: job.destination).appendingPathComponent("a") : held.appendingPathComponent("a")
            checkEqual(try String(contentsOf: preserved, encoding: .utf8), "safe")
            check(try fm.contentsOfDirectory(atPath: changed.path).isEmpty)
            print("PASS safety port: replaced \(replacingSource ? "source" : "backup") root cannot inherit deletion authority")
        }
        for substituteLink in [false, true] {
            let (root, job, engine) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
            let nested = URL(fileURLWithPath: job.source).appendingPathComponent("nested")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            try tests.write("safe", nested.appendingPathComponent("a")); _ = try await engine.run(job)
            try fm.moveItem(at: nested, to: root.appendingPathComponent("retained-nested"))
            if substituteLink { try fm.createSymbolicLink(at: nested, withDestinationURL: root.appendingPathComponent("retained-nested")) }
            else { try tests.write("not a directory", nested) }
            do { _ = try await engine.run(job, changedPaths: ["nested/a"]) } catch {}
            let backup = URL(fileURLWithPath: job.destination).appendingPathComponent("nested/a")
            checkEqual(try String(contentsOf: backup, encoding: .utf8), "safe")
            print("PASS safety port: \(substituteLink ? "symlink" : "non-directory") ancestor is not an inferred deletion")
        }
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
            let a = URL(fileURLWithPath: job.source).appendingPathComponent("a")
            try tests.write("safe", a); _ = try await engine.run(job)
            let manifest = root.appendingPathComponent("settings/manifests/\(job.id).json")
            try legacy(manifest); try fm.removeItem(at: a)
            let result = try await engine.run(job)
            checkEqual(result.removed, 0); check(!result.issues.isEmpty)
            checkEqual(try String(contentsOf: URL(fileURLWithPath: job.destination).appendingPathComponent("a"), encoding: .utf8), "safe")
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            check((record["files"] as! [String: Any])["a"] != nil)
            print("PASS safety port: legacy missing-source record and backup are retained for review")
        }
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
            let a = URL(fileURLWithPath: job.source).appendingPathComponent("a")
            try tests.write("safe", a); _ = try await engine.run(job)
            try legacy(root.appendingPathComponent("settings/manifests/\(job.id).json"))
            let result = try await engine.run(job, changedPaths: [])
            checkEqual(result.skipped, 1); check(result.issues.isEmpty)
            try fm.removeItem(at: a)
            let deleted = try await engine.run(job, changedPaths: ["a"])
            checkEqual(deleted.removed, 1); check(deleted.issues.isEmpty)
            print("PASS safety port: legacy present source is verified once before later deletion")
        }
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
            let a = URL(fileURLWithPath: job.source).appendingPathComponent("a")
            let backup = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
            try tests.write("safe", a); _ = try await engine.run(job)
            try fm.removeItem(at: a); try fm.removeItem(at: backup)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try tests.write("external", backup.appendingPathComponent("external"))
            let result = try await engine.run(job)
            checkEqual(result.removed, 0); check(!result.issues.isEmpty)
            checkEqual(try String(contentsOf: backup.appendingPathComponent("external"), encoding: .utf8), "external")
            print("PASS safety port: replacement backup directory is never archived as a deleted file")
        }
        for provider in CloudProvider.allCases {
            do {
                let (root, job, engine, cloud) = try CloudChecks.fixture(provider); defer { try? fm.removeItem(at: root) }
                try CloudChecks.write("AAAA", job: job); _ = try await engine.run(job, storage: cloud)
                try CloudChecks.write("BBBB", job: job)
                let result = try await engine.run(job, storage: cloud, changedPaths: ["a.txt"])
                checkEqual(result.skipped, 0); checkEqual(result.issues.count, 1); check(result.issues[0].conflict)
                checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("AAAA".utf8))
                print("PASS safety port \(provider.title): same metadata cannot hide different bytes")
            }
            do {
                let (root, job, engine, cloud) = try CloudChecks.fixture(provider); defer { try? fm.removeItem(at: root) }
                try CloudChecks.write("safe", job: job); _ = try await engine.run(job, storage: cloud)
                try legacy(root.appendingPathComponent("settings/cloud/manifests/\(job.id).json"))
                try fm.removeItem(at: URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"))
                let result = try await engine.run(job, storage: cloud)
                checkEqual(result.removed, 0); check(!result.issues.isEmpty)
                checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("safe".utf8))
                print("PASS safety port \(provider.title): legacy absent source never authorizes cloud deletion")
            }
            do {
                let (root, job, engine, cloud) = try CloudChecks.fixture(provider); defer { try? fm.removeItem(at: root) }
                try CloudChecks.write("safe", job: job); _ = try await engine.run(job, storage: cloud)
                await cloud.setRootIdentity("replacement-root")
                do { _ = try await engine.run(job, storage: cloud); fail("Changed cloud root must be rejected") } catch {}
                checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("safe".utf8))
                print("PASS safety port \(provider.title): cloud folder identity change is rejected")
            }
            do {
                let (root, job, engine, cloud) = try CloudChecks.fixture(provider); defer { try? fm.removeItem(at: root) }
                try CloudChecks.write("safe", job: job); _ = try await engine.run(job, storage: cloud)
                let file = URL(fileURLWithPath: job.source).appendingPathComponent("a.txt")
                try fm.removeItem(at: file)
                await cloud.onTrashUpload { try? Data("returned".utf8).write(to: file) }
                let result = try await engine.run(job, storage: cloud)
                checkEqual(result.removed, 0)
                checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("safe".utf8))
                checkEqual(try String(contentsOf: file, encoding: .utf8), "returned")
                print("PASS safety port \(provider.title): source reappearance during network await cancels deletion")
            }
            do {
                let (root, job, engine, cloud) = try CloudChecks.fixture(provider); defer { try? fm.removeItem(at: root) }
                try CloudChecks.write("safe", job: job); _ = try await engine.run(job, storage: cloud)
                let source = URL(fileURLWithPath: job.source), retained = root.appendingPathComponent("retained-source")
                try fm.removeItem(at: source.appendingPathComponent("a.txt"))
                await cloud.onTrashUpload {
                    try? FileManager.default.moveItem(at: source, to: retained)
                    try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                }
                do { _ = try await engine.run(job, storage: cloud) } catch {}
                check(fm.fileExists(atPath: retained.path))
                checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("safe".utf8))
                print("PASS safety port \(provider.title): source root swap during network await preserves remote backup")
            }
        }
        print("19 safety port integration scenarios passed (isolated filesystem and in-memory cloud)")
    }
}
