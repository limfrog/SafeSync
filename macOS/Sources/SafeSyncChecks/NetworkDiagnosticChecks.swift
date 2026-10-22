import Foundation
import SafeSyncCore

// Diagnostic reproduction, not an assertion that the current UX is correct.
struct NetworkDiagnosticChecks {
    static func run() async throws {
        for provider in CloudProvider.allCases {
            let (root, original, engine, cloud) = try CloudChecks.fixture(provider)
            defer { try? FileManager.default.removeItem(at: root) }
            for mode in [SyncMode.oneWay, .twoWay] {
                var job = original; job.id = UUID(); job.syncMode = mode
                let source = root.appendingPathComponent(mode.rawValue)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                job.source = source.path
                try Data("retry original".utf8).write(to: source.appendingPathComponent("a.txt"))
                try Data("unrelated".utf8).write(to: source.appendingPathComponent("z.txt"))
                // Separate roots avoid reusing the previous mode's files.
                let remoteRoot = try await cloud.createFolder(name: mode.rawValue, parent: original.cloudFolderID!)
                job.cloudFolderID = remoteRoot.locator
                await cloud.failNextUploads(1)
                let coordinator = SyncCoordinator(dataDirectory: root.appendingPathComponent("coordinator-" + mode.rawValue))
                let first = if mode == .twoWay { try await coordinator.run(job, storage: cloud) } else { try await engine.run(job, storage: cloud) }
                check(first.issues.contains { $0.path == "a.txt" && !$0.conflict && $0.waiting == nil })
                checkEqual(await cloud.bytes(name: "z.txt", parent: remoteRoot.locator), Data("unrelated".utf8))
                checkEqual(await cloud.bytes(name: "a.txt", parent: remoteRoot.locator), nil)
                print("ENGINE-ONLY \(provider.rawValue)/\(mode.rawValue): one-time HTTP 503 recorded before application retry; unrelated file succeeds")
                let recovered = if mode == .twoWay { try await coordinator.run(job, storage: cloud) } else { try await engine.run(job, storage: cloud) }
                check(recovered.issues.isEmpty)
                checkEqual(await cloud.bytes(name: "a.txt", parent: remoteRoot.locator), Data("retry original".utf8))
                print("ENGINE-ONLY \(provider.rawValue)/\(mode.rawValue): next invocation recovers safely; application scheduling is checked separately")
            }
        }
        var job = BackupJob(); job.source = "/source"; job.destination = "/backup"
        let generation = UUID(), review = ComparisonReview(job: job, sessionID: generation)
        checkFalse(review.allows(job: job, sessionID: generation, running: true))
        print("ENGINE-ONLY comparison authority: direct active writes remain blocked; deferred queue authority is tested separately")
        print("DIAGNOSTIC COMPLETE: 4 provider/mode cases; this is not an application/UI health assertion; cloud data is simulated")
    }
}
