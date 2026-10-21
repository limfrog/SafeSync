import Foundation
import SafeSyncCore

struct ComparisonReviewChecks {
    static func run() async throws {
        var job = BackupJob(); job.source = "/source"; job.destination = "Drive / chosen"
        job.cloudProvider = .googleDrive; job.cloudAccountID = UUID(); job.cloudFolderID = "folder-1"
        let current = UUID(), olderIssueRun = UUID()
        let review = ComparisonReview(job: job, sessionID: current)
        check(review.allows(job: job, sessionID: current, running: false))
        print("PASS review: freshly read current generation permits an older issue list")
        checkFalse(review.allows(job: job, sessionID: olderIssueRun, running: false))
        print("PASS review: different execution generation revokes authority")
        checkFalse(review.allows(job: job, sessionID: current, running: true))
        print("PASS review: active execution blocks application")
        checkFalse(review.allows(job: job, sessionID: nil, running: false))
        print("PASS review: missing execution generation cannot authorize writes")
        for field in 0..<8 {
            var changed = job
            switch field {
            case 0: changed.id = UUID()
            case 1: changed.source = "/other"
            case 2: changed.destination = "Drive / other"
            case 3: changed.cloudProvider = .dropbox
            case 4: changed.cloudAccountID = UUID()
            case 5: changed.cloudFolderID = "folder-2"
            case 6: changed.mode = .twoWay
            default: changed.cloudProvider = nil; changed.cloudAccountID = nil; changed.cloudFolderID = nil
            }
            checkFalse(review.allows(job: changed, sessionID: current, running: false))
            print("PASS review: changed endpoint field \(field) cannot inherit authority")
        }
        let tests = BackupTests(), fm = FileManager.default
        let (root, localJob, _) = try tests.fixture(); defer { try? fm.removeItem(at: root) }
        let source = URL(fileURLWithPath: localJob.source).appendingPathComponent("a")
        let backup = URL(fileURLWithPath: localJob.destination).appendingPathComponent("a")
        try tests.write("source", source); try tests.write("backup", backup)
        let checked = ComparisonReview(job: localJob, sessionID: current)
        check(checked.allows(job: localJob, sessionID: current, running: false))
        let comparison = try await FileComparisons.read(job: localJob, path: "a")
        let coordinator = SyncCoordinator(dataDirectory: root.appendingPathComponent("state"))
        let result = try await coordinator.apply([ResolutionDecision(comparison, action: .overwrite)], job: localJob)
        check(result.issues.isEmpty); checkEqual(try String(contentsOf: backup, encoding: .utf8), "source")
        let engine = BackupEngine(dataDirectory: root.appendingPathComponent("state"))
        check(try await engine.listTrash(localJob).contains { $0.path == "a" })
        print("PASS review: rechecked explicit overwrite applies and preserves previous backup in trash")
        let stale = try await FileComparisons.read(job: localJob, path: "a")
        try tests.write("changed externally", backup)
        do { _ = try await coordinator.apply([ResolutionDecision(stale, action: .overwrite)], job: localJob); fail("Stale file comparison applied") } catch {}
        checkEqual(try String(contentsOf: backup, encoding: .utf8), "changed externally")
        print("PASS review: file changed after comparison remains intact")
        print("14 comparison review integration scenarios passed")
    }
}
