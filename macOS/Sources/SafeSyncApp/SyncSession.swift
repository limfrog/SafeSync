import Foundation
import SafeSyncCore

enum WorkspaceTab: String, CaseIterable { case jobs = "백업 작업", sync = "동기화 상태", trash = "휴지통" }
enum SyncDetailTab: String, CaseIterable { case progress = "진행 상세", conflicts = "충돌", waiting = "사용 중", errors = "오류", problems = "문제 해결" }
struct SyncSession: Identifiable {
    let id = UUID()
    let job: BackupJob
    let start = Date()
    var end: Date?
    var outcome = "실행 중"
    var progress: BackupProgress?
    var result: BackupResult?
    var issues: [BackupIssue] = []
    var active: Bool { end == nil }
    var duration: String { let seconds = Int((end ?? Date()).timeIntervalSince(start)); return "\(seconds / 60)분 \(seconds % 60)초" }
}
/// Synchronous engines pause only at progress/file boundaries, retaining their current run.
final class RunPauseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    func setPaused(_ value: Bool) { condition.lock(); paused = value; condition.broadcast(); condition.unlock() }
    func wait() { condition.lock(); defer { condition.unlock() }; while paused && !Task.isCancelled { _ = condition.wait(until: Date().addingTimeInterval(0.1)) } }
}
