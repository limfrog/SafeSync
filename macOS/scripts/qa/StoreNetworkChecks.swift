import AppKit
import Foundation
import SafeSyncCore

func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { precondition(value, "Application network/queue assertion failed", file: file, line: line) }
func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { precondition(a == b, "Expected \(b), got \(a)", file: file, line: line) }
func fail(_ message: String) { fatalError(message) }

actor UploadBoundary {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func reached() -> Bool { entered }
    func release() { continuation?.resume(); continuation = nil }
}

@main @MainActor struct StoreNetworkChecks {
    struct Retry: Decodable { let attempts: Int; let next: Date }
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NSError(domain: "SafeSync.QA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Application fixture timed out"])
    }
    static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        check(Storage.applicationDirectory.path.hasPrefix("/private/tmp/safesync-store-qa."))
        let store = Store(); store.mainVisible = false
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        var scenarios = 0
        for provider in CloudProvider.allCases {
            for mode in [SyncMode.oneWay, .twoWay] {
                for persistent in [false, true] {
                    let (root, original, _, cloud) = try CloudChecks.fixture(provider)
                    var job = original; job.syncMode = mode; job.scheduled = true; job.scheduleTime = "23:59"; job.lastScheduledDay = day.string(from: Date())
                    try CloudChecks.write("retry original", job: job)
                    try Data("unrelated".utf8).write(to: URL(fileURLWithPath: job.source).appendingPathComponent("z.txt"))
                    let account = CloudAccount(provider: provider, name: "isolated", clientID: "test-only")
                    job.cloudAccountID = account.id; store.accounts = [account]; store.jobs = [job]; store.issues = []; store.error = nil
                    store.qaRemoteFactory = { _ in cloud }; store.rebuildWatchers()
                    await cloud.failNextUploads(persistent ? 100 : 1)
                    check(store.run(job, full: true))
                    try await wait { !store.isRunning(job.id) }
                    print("STATE \(provider.rawValue)/\(mode.rawValue)/persistent=\(persistent): runs=\(store.sessions.filter { $0.job.id == job.id }.count), issues=\(store.issues.map { ($0.path, $0.automaticNetworkRetry, $0.reason) }), messages=\(store.messageRows.count), appError=\(store.error ?? "none")")
                    check(store.sessions.filter { $0.job.id == job.id }.count == 2)
                    check(store.messageRows.isEmpty && store.error == nil)
                    checkEqual(await cloud.bytes(name: "z.txt", parent: job.cloudFolderID!), Data("unrelated".utf8))
                    if persistent {
                        check(store.issues.contains { $0.jobID == job.id && $0.automaticNetworkRetry })
                        let retryFile = Storage.applicationDirectory.appendingPathComponent("retries.json")
                        let retries = try JSONDecoder().decode([UUID: Retry].self, from: Data(contentsOf: retryFile))
                        print("BACKOFF attempts=\(retries[job.id]!.attempts), seconds=\(retries[job.id]!.next.timeIntervalSinceNow)")
                        check(retries[job.id]!.attempts >= 2 && retries[job.id]!.next.timeIntervalSinceNow > 20)
                        try await Task.sleep(for: .milliseconds(300)); check(!store.isRunning(job.id))
                    } else {
                        check(!store.issues.contains { $0.jobID == job.id })
                        checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("retry original".utf8))
                    }
                    scenarios += 1; print("PASS app network \(provider.rawValue)/\(mode.rawValue)/persistent=\(persistent): exactly one tail retry, diagnostics-only, backoff/snapshot safety")
                    store.jobs = []; store.rebuildWatchers(); try? FileManager.default.removeItem(at: root)
                }
                for cancel in [false, true] {
                    let (root, original, _, cloud) = try CloudChecks.fixture(provider)
                    var job = original; job.syncMode = mode; job.scheduled = true; job.scheduleTime = "23:59"; job.lastScheduledDay = day.string(from: Date())
                    let source = URL(fileURLWithPath: job.source)
                    try CloudChecks.write("right preserved", job: job, time: 3000)
                    _ = try await cloud.upload(file: source.appendingPathComponent("a.txt"), name: "a.txt", parent: job.cloudFolderID!, modified: Date(timeIntervalSince1970: 3000), resumeKey: "seed", progress: { _, _ in })
                    try CloudChecks.write("left original", job: job, time: 1000)
                    try Data("normal last file".utf8).write(to: source.appendingPathComponent("z.txt"))
                    let account = CloudAccount(provider: provider, name: "isolated", clientID: "test-only"); job.cloudAccountID = account.id
                    store.accounts = [account]; store.jobs = [job]; store.issues = []; store.error = nil; store.qaRemoteFactory = { _ in cloud }; store.rebuildWatchers()
                    let boundary = UploadBoundary()
                    await cloud.setUploadHook { key in if key.contains("|z.txt|") { await boundary.block() } }
                    check(store.run(job, full: true))
                    for _ in 0..<2000 { if await boundary.reached() { break }; try await Task.sleep(for: .milliseconds(20)) }
                    check(await boundary.reached()); let run = store.sessions.first { $0.job.id == job.id }!
                    let review = store.beginReview(run)!; check(store.canUseReview(review))
                    let comparison = try await FileComparisons.read(job: job, path: "a.txt", storage: cloud)
                    for action in [ConflictAction.overwrite, .useBackup, .keepBoth] {
                        check(store.applyDecisions([ResolutionDecision(comparison, action: action)], session: run, review: review))
                        check(store.queuedResolutionCount(job.id) == 1 && store.resolutionState(job.id, path: "a.txt").action == action)
                    }
                    checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("right preserved".utf8))
                    if cancel { store.cancelQueuedResolutions(job.id, paths: ["a.txt"]) }
                    await boundary.release(); try await wait { !store.isRunning(job.id) }
                    check(store.sessions.filter { $0.job.id == job.id }.count == (cancel ? 1 : 2))
                    checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data((cancel ? "right preserved" : "left original").utf8))
                    checkEqual(await cloud.bytes(name: "z.txt", parent: job.cloudFolderID!), Data("normal last file".utf8))
                    if !cancel { check(await cloud.children(job.cloudFolderID!).contains { $0.name.contains("SafeSync-conflict") }) }
                    check(store.queuedResolutionCount(job.id) == 0)
                    scenarios += 1; print("PASS app queue \(provider.rawValue)/\(mode.rawValue)/cancel=\(cancel): live reservation, last choice, no early mutation, preserved copies")
                    store.jobs = []; store.rebuildWatchers(); try? FileManager.default.removeItem(at: root)
                }
            }
        }
        print("PASS \(scenarios) actual Store scheduler/network/deferred-resolution scenarios; no real accounts or user files used")
    }
}
