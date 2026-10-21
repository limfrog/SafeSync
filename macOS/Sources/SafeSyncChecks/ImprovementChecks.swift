import Foundation
import Darwin
import SafeSyncCore

private actor DriveWire {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest, accepted: Set<Int>) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let isStart = request.url!.query?.contains("resumable") == true
        let headers = isStart ? ["Location": "https://www.googleapis.com/upload/session-test"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
        let bytes = try HTTP.json(["id": "test-id", "name": "test", "size": "0", "version": "1"])
        return (bytes, response)
    }
    func snapshot() -> [URLRequest] { requests }
}

struct ImprovementChecks {
    static func run() async throws {
        let tests = BackupTests()
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let source = URL(fileURLWithPath: job.source), target = URL(fileURLWithPath: job.destination)
            try tests.write("first", source.appendingPathComponent("a"))
            _ = try await engine.run(job)
            try tests.write("replacement", source.appendingPathComponent("a"), time: 2000)
            try tests.write("independent", source.appendingPathComponent("b"))
            let fd = Darwin.open(source.appendingPathComponent("a").path, O_RDWR)
            check(fd >= 0); checkEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            let locked = try await engine.run(job, changedPaths: ["a", "b"])
            checkEqual(locked.copied, 1); checkEqual(locked.issues.count, 1); check(locked.issues[0].waiting != nil)
            checkEqual(try String(contentsOf: target.appendingPathComponent("a"), encoding: .utf8), "first")
            print("PASS locked source waits without blocking independent files or overwriting prior backup")
            let deferred = try await engine.run(job, changedPaths: ["a"], deferredPaths: ["a"])
            check(deferred.evaluatedPaths.isEmpty); check(deferred.issues.isEmpty)
            flock(fd, LOCK_UN); Darwin.close(fd)
            let retried = try await engine.run(job, changedPaths: ["a"])
            checkEqual(retried.copied, 1); check(retried.issues.isEmpty)
            checkEqual(try String(contentsOf: target.appendingPathComponent("a"), encoding: .utf8), "replacement")
            print("PASS deferred automatic retry and immediate retry after source unlock")
        }
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let source = URL(fileURLWithPath: job.source).appendingPathComponent("a"), target = URL(fileURLWithPath: job.destination).appendingPathComponent("a")
            try tests.write("original", source); _ = try await engine.run(job)
            try tests.write("replacement", source, time: 2000)
            let fd = Darwin.open(target.path, O_RDWR); check(fd >= 0); checkEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
            let locked = try await engine.run(job)
            check(locked.issues.first?.waiting != nil); checkEqual(locked.copied, 0)
            flock(fd, LOCK_UN); Darwin.close(fd)
            checkEqual(try String(contentsOf: target, encoding: .utf8), "original")
            print("PASS locked destination preserves previous backup")
        }
        do {
            let now = Date(timeIntervalSince1970: 1000)
            var waiting = FileWaitState(now: now)
            checkEqual(waiting.nextAttempt, now.addingTimeInterval(30))
            waiting.attempted(now: now); checkEqual(waiting.nextAttempt, now.addingTimeInterval(60))
            for _ in 0..<10 { waiting.attempted(now: now) }
            checkEqual(waiting.nextAttempt, now.addingTimeInterval(300)); checkEqual(waiting.firstWait, now)
            var issue = BackupIssue(jobID: UUID(), path: "한글", reason: "busy", conflict: false, waiting: waiting)
            let restored = try JSONDecoder().decode(BackupIssue.self, from: JSONEncoder().encode(issue))
            checkEqual(restored.waiting?.attempts, waiting.attempts)
            issue.waiting = nil
            let old = try JSONDecoder().decode(BackupIssue.self, from: JSONEncoder().encode(issue))
            check(old.waiting == nil)
            checkFalse(FileAccess.isBusy(POSIXError(.EACCES)))
            check(FileAccess.isBusy(NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: POSIXError(.EBUSY)])))
            print("PASS persistent per-file wait history, capped backoff and previous issue format compatibility")
        }
        do {
            var journal = ChangeJournal(); journal.acknowledge(through: journal.sequence, full: true, retry: [])
            checkFalse(BackupScanPolicy.requiresFullScan(explicit: false, watcherReady: true, journal: journal, network: false))
            check(BackupScanPolicy.requiresFullScan(explicit: true, watcherReady: true, journal: journal, network: false))
            check(BackupScanPolicy.requiresFullScan(explicit: false, watcherReady: false, journal: journal, network: false))
            check(BackupScanPolicy.requiresFullScan(explicit: false, watcherReady: true, journal: journal, network: true))
            journal.record(paths: [], eventID: nil, requireFull: true)
            check(BackupScanPolicy.requiresFullScan(explicit: false, watcherReady: true, journal: journal, network: false))
            print("PASS manual incremental policy retains explicit, history-loss and network full-scan fallbacks")
        }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-wire-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let wire = DriveWire(), file = root.appendingPathComponent("test")
            let account = CloudAccount(provider: .googleDrive, name: "wire", clientID: "test")
            let storage = GoogleDriveStorage(account: account, dataDirectory: root, transport: { request, accepted in try await wire.send(request, accepted: accepted) })
            let binary = Data([0, 255, 13, 10, 128]); try binary.write(to: file)
            _ = try await storage.upload(file: file, name: "한글\".bin", parent: "parent", modified: Date(), resumeKey: "small")
            var requests = await wire.snapshot(); checkEqual(requests.count, 1)
            let request = requests[0], body = request.httpBody!
            check(request.url!.query!.contains("multipart")); check(body.range(of: binary) != nil)
            check(body.range(of: Data("한글\\\".bin".utf8)) != nil)
            check(request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/related; boundary="))
            print("PASS Google Drive small binary/Unicode file uses one multipart request")
            try Data(repeating: 1, count: 5 * 1024 * 1024 + 1).write(to: file)
            _ = try await storage.upload(file: file, name: "large", parent: "parent", modified: Date(), resumeKey: "large")
            requests = await wire.snapshot(); checkEqual(requests.count, 3)
            check(requests[1].url!.query!.contains("resumable")); checkEqual(requests[2].httpMethod, "PUT")
            checkEqual(requests[2].value(forHTTPHeaderField: "Content-Range"), "bytes 0-5242880/5242881")
            print("PASS Google Drive large files retain resumable upload path")
        }
        do {
            let (root, job, engine, cloud) = try CloudChecks.fixture(.googleDrive)
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["a.txt", "b.txt", "c.txt", "d.txt"] {
                try tests.write("identical", URL(fileURLWithPath: job.source).appendingPathComponent(name))
            }
            await cloud.setDelay(30_000_000)
            let first = try await engine.run(job, storage: cloud)
            checkEqual(first.copied, 4); check(first.issues.isEmpty)
            checkEqual(await cloud.peakUploads(), 2)
            for name in ["a.txt", "b.txt", "c.txt", "d.txt"] { checkEqual(await cloud.bytes(name: name, parent: job.cloudFolderID!), Data("identical".utf8)) }
            print("PASS Google Drive bounded parallel uploads preserve identical-content files with separate snapshots")
            try tests.write("updated-a", URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"), time: 2000)
            try tests.write("updated-b", URL(fileURLWithPath: job.source).appendingPathComponent("b.txt"), time: 2000)
            await cloud.setFailName("a.txt")
            let failed = try await engine.run(job, storage: cloud, changedPaths: ["a.txt", "b.txt"])
            checkEqual(failed.copied, 1); checkEqual(failed.issues.count, 1)
            checkEqual(await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!), Data("identical".utf8))
            checkEqual(await cloud.bytes(name: "b.txt", parent: job.cloudFolderID!), Data("updated-b".utf8))
            print("PASS parallel upload failure isolates one file and preserves its previous version")
        }
        do {
            let (root, job, engine, cloud) = try CloudChecks.fixture(.googleDrive)
            defer { try? FileManager.default.removeItem(at: root) }
            try tests.write("first", URL(fileURLWithPath: job.source).appendingPathComponent("a.txt"))
            try tests.write("second", URL(fileURLWithPath: job.source).appendingPathComponent("b.txt"))
            await cloud.setDelay(500_000_000)
            let worker = Task { try await engine.run(job, storage: cloud) }
            for _ in 0..<100 {
                if await cloud.peakUploads() == 2 { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            worker.cancel()
            do { _ = try await worker.value; fail("Cancelled parallel uploads must stop") } catch is CancellationError { }
            await cloud.setDelay(0)
            let retry = try await engine.run(job, storage: cloud)
            checkEqual(retry.copied, 2); check(retry.issues.isEmpty)
            print("PASS parallel cancellation waits for children, releases lease and permits safe retry")
        }
        do {
            let (root, job, engine) = try tests.fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let source = URL(fileURLWithPath: job.source), backup = URL(fileURLWithPath: job.destination)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup.appendingPathComponent("folder"), withIntermediateDirectories: true)
            try tests.write("source", source.appendingPathComponent("folder/conflict"))
            try tests.write("newer", backup.appendingPathComponent("folder/conflict"), time: 3000)
            let conflict = try await engine.run(job); checkEqual(conflict.issues.count, 1)
            try FileManager.default.removeItem(at: source.appendingPathComponent("folder"))
            let removed = try await engine.run(job, changedPaths: ["folder"])
            check(removed.evaluated("folder/conflict")); checkFalse(removed.evaluated("unrelated/conflict"))
            checkEqual(try String(contentsOf: backup.appendingPathComponent("folder/conflict"), encoding: .utf8), "newer")
            print("PASS incremental directory deletion clears stale issues without discarding untracked backups or unrelated conflicts")
        }
        try await watcherCheck()
        print("12 improvement checks passed")
    }
}

@MainActor private func watcherCheck() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-events-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var paths: [String] = []
    let watcher = FolderWatcher(paths: [root.path], since: nil) { events in paths += events.map(\.path) }
    guard watcher.isOperational else {
        checkFalse(await watcher.flushPendingEvents())
        check(BackupScanPolicy.requiresFullScan(explicit: false, watcherReady: false, journal: ChangeJournal(), network: false))
        print("PASS unavailable FSEvents service requests full scan (live event delivery unavailable in this shell)")
        return
    }
    checkFalse(watcher.historyReady)
    try Data("new file".utf8).write(to: root.appendingPathComponent("pending.txt"))
    checkFalse(await watcher.flushPendingEvents())
    check(BackupScanPolicy.requiresFullScan(explicit: false, watcherReady: false, journal: ChangeJournal(), network: false))
    // The daemon subscription is asynchronous. A fresh stream must request a
    // conservative inventory, not pretend that an empty first flush is complete.
    // Separately prove real delivery and replay completion, with a bounded wait.
    for _ in 0..<50 {
        if watcher.historyReady && paths.contains(where: { $0.hasSuffix("/pending.txt") }) { break }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await watcher.flushPendingEvents()
    }
    check(watcher.historyReady)
    check(paths.contains { $0.hasSuffix("/pending.txt") })
    check(await watcher.flushPendingEvents())
    print("PASS real FSEvents startup requests a safe inventory, completes replay and delivers live changes without blocking main callbacks")
}
