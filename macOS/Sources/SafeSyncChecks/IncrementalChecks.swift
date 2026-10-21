import Foundation
import SafeSyncCore

struct IncrementalChecks {
    static func run() async throws {
        var journal = ChangeJournal()
        journal.record(paths: ["a"], eventID: 10, requireFull: false)
        let checkpoint = journal.sequence
        journal.record(paths: ["a", "b"], eventID: 11, requireFull: false)
        journal.acknowledge(through: checkpoint, full: true, retry: [])
        checkEqual(Set(journal.pending.keys), Set(["a", "b"])); checkEqual(journal.eventID, 11)
        journal.acknowledge(through: journal.sequence, full: false, retry: ["failed"])
        checkEqual(Set(journal.pending.keys), Set(["failed"])); check(!journal.needsFullScan())
        let persisted = try JSONDecoder().decode(ChangeJournal.self, from: JSONEncoder().encode(journal))
        checkEqual(persisted.pending, journal.pending)
        check(!journal.needsFullScan(now: Date().addingTimeInterval(8 * 86400)))
        check(!journal.needsFullScan(now: Date().addingTimeInterval(365 * 86400)))
        journal.record(paths: [], eventID: 12, requireFull: true); check(journal.needsFullScan())
        print("PASS durable change queue retains in-flight events without age-only full rescans")
        let (root, job, engine) = try BackupTests().fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let src = URL(fileURLWithPath: job.source), dst = URL(fileURLWithPath: job.destination), tests = BackupTests()
        try FileManager.default.createDirectory(at: src.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try tests.write("first", src.appendingPathComponent("nested/a"))
        try tests.write("other", src.appendingPathComponent("b"))
        _ = try await engine.run(job)
        try tests.write("changed", src.appendingPathComponent("nested/a"), time: 2000)
        let update = try await engine.run(job, changedPaths: ["nested"])
        checkEqual(update.copied, 1); checkEqual(update.skipped, 0)
        checkEqual(try String(contentsOf: dst.appendingPathComponent("nested/a"), encoding: .utf8), "changed")
        try FileManager.default.removeItem(at: src.appendingPathComponent("nested"))
        let deleted = try await engine.run(job, changedPaths: ["nested"]); checkEqual(deleted.removed, 1)
        check(FileManager.default.fileExists(atPath: dst.appendingPathComponent("b").path))
        let noChanges = try await engine.run(job, changedPaths: []); checkEqual(noChanges.copied, 0); checkEqual(noChanges.skipped, 0)
        print("PASS incremental nested change, directory deletion and no-change run without unrelated file comparisons")
        let old = try await engine.listTrash(job)
        let cleaned = try await engine.pruneTrash(job, retentionDays: 100, now: Date().addingTimeInterval(101 * 86400)); checkEqual(cleaned, old.count)
        let remaining = try await engine.listTrash(job); check(remaining.isEmpty)
        print("PASS local retention removes only expired trash after recovery")
        let pkce = try OAuthPKCE()
        checkEqual(pkce.verifier.count, 43); checkEqual(pkce.challenge.count, 43); check(pkce.state != pkce.verifier)
        let account = CloudAccount(provider: .googleDrive, name: "test", clientID: "test-client")
        let url = OAuthPKCE.authorizationURL(account: account, redirect: "http://127.0.0.1:12345/", pkce: pkce)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        checkEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        checkEqual(query.first { $0.name == "state" }?.value, pkce.state)
        print("PASS OAuth PKCE and anti-forgery parameters")
    }
}
