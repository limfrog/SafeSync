import Foundation

/// Session-only authority; accepted decisions contain the exact compared versions.
public struct DeferredResolutionQueue: Sendable {
    public let job: BackupJob
    public private(set) var decisions: [String: ResolutionDecision] = [:]
    public init(job: BackupJob) { self.job = job }
    public func matches(_ current: BackupJob) -> Bool { FileComparisons.sameEndpoints(job, current) && job.mirrorDeletes == current.mirrorDeletes }
    public mutating func reserve(_ choices: [ResolutionDecision], job current: BackupJob) throws {
        guard matches(current), !choices.isEmpty else { throw BackupError.unsafe("예약할 파일 또는 작업 위치를 다시 확인하세요.") }
        // Validate the complete request before replacing any earlier choice.
        for choice in choices {
            try FileComparisons.validatePath(choice.comparison.path)
            guard FileComparisons.sameEndpoints(choice.comparison.job, current), choice.comparison.allows(choice.action),
                  choice.action == .ignore || choice.comparison.readable else { throw BackupError.unsafe("현재 비교 정보로 예약할 수 없는 처리입니다.") }
        }
        for choice in choices { decisions[choice.comparison.path] = choice }
    }
    public mutating func cancel(paths: Set<String>) { for path in paths { decisions.removeValue(forKey: path) } }
}
