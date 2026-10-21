import Foundation

/// Authority comes from freshly read files at the current execution generation,
/// never from the age or outcome of the issue list the user happens to inspect.
public struct ComparisonReview: Sendable {
    public let job: BackupJob
    public let sessionID: UUID
    public init(job: BackupJob, sessionID: UUID) { self.job = job; self.sessionID = sessionID }
    public func allows(job current: BackupJob, sessionID currentID: UUID?, running: Bool) -> Bool {
        !running && currentID == sessionID && FileComparisons.sameEndpoints(job, current)
    }
}
