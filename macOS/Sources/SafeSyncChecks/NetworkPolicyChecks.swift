import Foundation
import Darwin
import SafeSyncCore

struct NetworkPolicyChecks {
    static func run() async throws {
        for status in [408,429,500,502,503,504,401,403,409,507] {
            let error = HTTP.responseError(status: status, url: URL(string: "https://api.dropboxapi.com/2/files/upload")!, data: Data())
            checkEqual(NetworkFailurePolicy.isTransient(error), [408,429,500,502,503,504].contains(status))
        }
        for code in [URLError.timedOut, .networkConnectionLost, .notConnectedToInternet] { check(NetworkFailurePolicy.isTransient(URLError(code))) }
        for code in [URLError.cancelled, .serverCertificateUntrusted, .userAuthenticationRequired, .badURL] { checkFalse(NetworkFailurePolicy.isTransient(URLError(code))) }
        checkFalse(NetworkFailurePolicy.isTransient(CancellationError()))
        check(NetworkFailurePolicy.isTransient(POSIXError(.ENETDOWN)))
        checkFalse(NetworkFailurePolicy.isTransient(POSIXError(.ENOSPC)))
        checkFalse(NetworkFailurePolicy.isTransient(POSIXError(.EACCES)))
        let issue = FileAccess.issue(URLError(.timedOut), jobID: UUID(), path: "a.txt")
        check(issue.automaticNetworkRetry && issue.handling == "자동 재시도" && !issue.conflict && issue.waiting == nil)
        let roundtrip = try JSONDecoder().decode(BackupIssue.self, from: JSONEncoder().encode(issue))
        check(roundtrip.automaticNetworkRetry)
        let tests = BackupTests(), (root, job, _) = try tests.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try tests.write("left", URL(fileURLWithPath: job.source).appendingPathComponent("a"))
        try tests.write("right", URL(fileURLWithPath: job.destination).appendingPathComponent("a"))
        let snapshot = try await FileComparisons.read(job: job, path: "a")
        var queue = DeferredResolutionQueue(job: job)
        try queue.reserve([ResolutionDecision(snapshot, action: .overwrite)], job: job)
        try queue.reserve([ResolutionDecision(snapshot, action: .useBackup)], job: job)
        check(queue.decisions.count == 1 && queue.decisions["a"]?.action == .useBackup)
        try queue.reserve([ResolutionDecision(snapshot, action: .keepBoth)], job: job)
        checkEqual(queue.decisions["a"]?.action, .keepBoth)
        var changed = job; changed.destination += "-changed"
        do { try queue.reserve([ResolutionDecision(snapshot, action: .overwrite)], job: changed); fail("Changed endpoint accepted") } catch {}
        checkEqual(queue.decisions["a"]?.action, .keepBoth)
        var unsafe = snapshot; unsafe.path = "../outside"
        do { try queue.reserve([ResolutionDecision(unsafe, action: .ignore)], job: job); fail("Unsafe path accepted") } catch {}
        queue.cancel(paths: ["a"]); check(queue.decisions.isEmpty)
        let session = UUID(), review = ComparisonReview(job: job, sessionID: session)
        check(review.allowsReservation(job: job, sessionID: session, running: true))
        checkFalse(review.allows(job: job, sessionID: session, running: true))
        checkFalse(review.allowsReservation(job: changed, sessionID: session, running: true))
        checkFalse(review.allowsReservation(job: job, sessionID: UUID(), running: true))
        print("PASS network policy: transient/permanent/cancel/TLS classification, persisted diagnostics, last-choice queue, path/binding guards, direct-write isolation")
    }
}
