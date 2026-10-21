import AppKit
import SwiftUI
import SafeSyncCore
import CoreServices

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    var openAppWindow: ((String) -> Void)?
    @Published var workspace: WorkspaceTab = .jobs
    @Published var detailTab: SyncDetailTab = .progress
    @Published var sessions: [SyncSession] = []
    @Published var sessionSelection: UUID?
    @Published var followLatest = true
    @Published var problemSelection: UUID?
    @Published var deleteRequest: BackupJob?
    private var pauseGates: [UUID: RunPauseGate] = [:]
    private let coordinator = SyncCoordinator()
    var selectedSession: SyncSession? { sessions.first { $0.id == sessionSelection } }
    func canRepair(_ session: SyncSession) -> Bool {
        !session.active && sessions.first(where: { $0.job.id == session.job.id })?.id == session.id &&
        jobs.contains { FileComparisons.sameEndpoints($0, session.job) } && running[session.job.id] == nil && !busyTrash && !isImportingJobList
    }
    func isRunning(_ id: UUID) -> Bool { running[id] != nil }
    func canBeginReview(_ session: SyncSession) -> Bool {
        jobs.contains { FileComparisons.sameEndpoints($0, session.job) } && running[session.job.id] == nil &&
        sessions.first(where: { $0.job.id == session.job.id })?.active == false && !busyTrash && !isImportingJobList
    }
    func beginReview(_ session: SyncSession) -> ComparisonReview? {
        guard canBeginReview(session), let current = sessions.first(where: { $0.job.id == session.job.id }),
              let job = jobs.first(where: { FileComparisons.sameEndpoints($0, session.job) }) else { return nil }
        return ComparisonReview(job: job, sessionID: current.id)
    }
    func canUseReview(_ review: ComparisonReview) -> Bool {
        guard let job = jobs.first(where: { $0.id == review.job.id }), !busyTrash, !isImportingJobList else { return false }
        let latest = sessions.first(where: { $0.job.id == job.id })
        return review.allows(job: job, sessionID: latest?.id, running: running[job.id] != nil || latest?.active == true)
    }
    func navigate(_ tab: WorkspaceTab) { workspace = tab; if tab == .trash { loadTrash() } }
    func showProblems(_ issue: BackupIssue? = nil) { workspace = .sync; detailTab = .problems; problemSelection = issue?.id }
    @Published var validatingCloud = false
    @Published var cloudValidationReport: String?
    @Published var accounts: [CloudAccount] = []
    @Published var jobs: [BackupJob] = []
    @Published var selection: UUID?
    @Published var statuses: [UUID: String] = [:]
    @Published var progress: [UUID: BackupProgress] = [:]
    @Published var issues: [BackupIssue] = []
    @Published var activity: [String] = []
    @Published var error: String?
    @Published var mainVisible = true
    @Published var isImportingJobList = false
    @Published var editing: BackupJob?
    @Published var trash: [TrashItem] = []
    @Published var trashJob: BackupJob?
    @Published var busyTrash = false
    private var trashGeneration = UUID()
    @Published private var running: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var hiddenCompanions: [NSWindow] = []
    private var tickCount = 0
    private var watchers: [UUID: FolderWatcher] = [:]
    private var journals: [UUID: ChangeJournal] = [:]
    private struct RetryState: Codable { var attempts = 0; var next: Date = .distantPast }
    private var retries: [UUID: RetryState] = [:]
    private let engine = BackupEngine()
    private let cloudEngine = CloudBackupEngine()
    private var configurationUsable = true
    var selected: BackupJob? { jobs.first { $0.id == selection } }
    var runningCount: Int { running.count }
    var canImportJobList: Bool { configurationUsable && running.isEmpty && !busyTrash && !validatingCloud && !isImportingJobList }
    let accountsURL = Storage.applicationDirectory.appendingPathComponent("accounts.json")
    let settingsURL = Storage.applicationDirectory.appendingPathComponent("jobs.json")
    let issuesURL = Storage.applicationDirectory.appendingPathComponent("issues.json")
    init() {
        do {
            if FileManager.default.fileExists(atPath: accountsURL.path) { accounts = try Storage.load([CloudAccount].self, from: accountsURL) }
            if FileManager.default.fileExists(atPath: settingsURL.path) { jobs = try Storage.load([BackupJob].self, from: settingsURL) }
            if FileManager.default.fileExists(atPath: issuesURL.path) { issues = try Storage.load([BackupIssue].self, from: issuesURL) }
        } catch { configurationUsable = false; self.error = "저장된 설정을 읽을 수 없어 자동 실행을 중지했습니다: \(error.localizedDescription)" }
        do {
            let retryURL = Storage.applicationDirectory.appendingPathComponent("retries.json")
            if FileManager.default.fileExists(atPath: retryURL.path) { retries = try Storage.load([UUID: RetryState].self, from: retryURL) }
            for job in jobs {
                let url = journalURL(job.id)
                journals[job.id] = FileManager.default.fileExists(atPath: url.path) ? try Storage.load(ChangeJournal.self, from: url) : ChangeJournal()
            }
        } catch { configurationUsable = false; self.error = "변경 기록을 읽을 수 없어 자동 실행을 중지했습니다: \(error.localizedDescription)" }
        let knownIDs = Set(jobs.map(\.id))
        issues = issues.filter { knownIDs.contains($0.jobID) }
        retries = retries.filter { knownIDs.contains($0.key) }
        installWindowPolicy()
        rebuildWatchers()
        log("SafeSync \(AppInformation.version) 시작")
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    func log(_ text: String) { activity.insert("\(Date().formatted(date: .omitted, time: .standard))  \(text)", at: 0); activity = Array(activity.prefix(300)) }
    private func persist() throws {
        guard configurationUsable else { throw BackupError.unsafe("기존 설정 오류를 해결한 뒤 앱을 다시 실행하세요.") }
        try Storage.save(accounts, to: accountsURL)
        try Storage.save(jobs, to: settingsURL)
        try Storage.save(issues, to: issuesURL)
    }
    func save() {
        do { try persist() }
        catch { configurationUsable = false; self.error = "설정 저장 실패로 자동 실행을 중지했습니다: \(error.localizedDescription)" }
    }
    func upsert(_ job: BackupJob) throws {
        guard configurationUsable, !isImportingJobList else { throw BackupError.unsafe("설정을 읽을 수 없거나 작업 목록을 가져오는 중입니다.") }
        try BackupEngine.validate(job)
        guard running[job.id] == nil else { throw BackupError.unsafe("실행 중인 작업은 완료 후 수정하세요.") }
        for other in jobs where other.id != job.id {
            if (job.mode == .twoWay || other.mode == .twoWay), BackupEngine.overlaps(BackupEngine.canonical(job.source), BackupEngine.canonical(other.source)) { throw BackupError.unsafe("양방향 작업의 원본 위치는 다른 작업의 원본과 겹칠 수 없습니다.") }
            if job.cloudProvider == nil, BackupEngine.overlaps(BackupEngine.canonical(job.destination), BackupEngine.canonical(other.source)) { throw BackupError.unsafe("백업 위치가 다른 작업의 원본과 겹칩니다.") }
            if other.cloudProvider == nil, BackupEngine.overlaps(BackupEngine.canonical(other.destination), BackupEngine.canonical(job.source)) { throw BackupError.unsafe("원본 위치가 다른 작업의 백업과 겹칩니다.") }
            if job.cloudProvider != nil || other.cloudProvider != nil {
                if job.cloudProvider != nil, job.cloudAccountID == other.cloudAccountID, (job.cloudFolderID == other.cloudFolderID || job.destination.hasPrefix(other.destination + " / ") || other.destination.hasPrefix(job.destination + " / ")) { throw BackupError.unsafe("다른 작업이 같은 클라우드 폴더를 사용 중입니다.") }
                continue
            }
            let target = BackupEngine.canonical(job.destination)
            if BackupEngine.overlaps(target, BackupEngine.canonical(other.destination)) || BackupEngine.overlaps(target, BackupEngine.canonical(other.source)) || BackupEngine.overlaps(BackupEngine.canonical(job.source), BackupEngine.canonical(other.destination)) {
                throw BackupError.unsafe("다른 작업의 원본·백업 경로와 겹칩니다. 서로 분리된 폴더를 선택하세요.")
            }
        }
        let originalJobs = jobs, originalIssues = issues
        var savedID = job.id
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            var updated = job
            if !FileComparisons.sameEndpoints(jobs[i], job) { updated.id = UUID(); updated.paused = true; updated.stopped = nil; savedID = updated.id }
            jobs[i] = updated
        } else { jobs.append(job) }
        let known = Set(jobs.map(\.id)); issues.removeAll { !known.contains($0.jobID) }
        do { try persist() } catch { jobs = originalJobs; issues = originalIssues; throw error }
        selection = savedID; rebuildWatchers(); log("작업 저장: \(job.name)")
    }
    func removeSelected() {
        guard !isImportingJobList, let job = selected else { return }
        guard running[job.id] == nil else { error = "작업 관리에서 작업 종료 후 삭제하세요. 백업 파일은 보존합니다."; return }
        deleteRequest = job
    }
    func confirmDelete() {
        guard let job = deleteRequest, running[job.id] == nil else { return }
        jobs.removeAll { $0.id == job.id }; rebuildWatchers(); issues.removeAll { $0.jobID == job.id }; selection = nil; deleteRequest = nil; save()
    }
    func stopSelected() {
        guard let id = selection, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].stopped = true; jobs[i].paused = false; running[id]?.cancel(); pauseGates[id]?.setPaused(false); statuses[id] = "종료 대기"; save()
    }
    func togglePause() {
        guard !isImportingJobList, let id = selection, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].stopped == true { jobs[i].stopped = false; jobs[i].paused = false; save(); run(jobs[i]); return }
        jobs[i].paused.toggle(); pauseGates[id]?.setPaused(jobs[i].paused)
        statuses[id] = jobs[i].paused ? "일시정지" : (running[id] == nil ? "대기 중" : "실행 중")
        if let index = sessions.firstIndex(where: { $0.job.id == id && $0.active }) { sessions[index].outcome = jobs[i].paused ? "일시정지" : "실행 중" }
        save()
    }
    @discardableResult func run(_ requested: BackupJob, full: Bool = false, automatic: Bool = false, decisions: [ResolutionDecision]? = nil) -> Bool {
        var job = requested
        if !automatic, job.stopped == true { job.stopped = false; if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].stopped = false }; save() }
        if automatic && job.stopped == true { return false }
        guard configurationUsable, !isImportingJobList, running[job.id] == nil, !job.paused, !busyTrash else { return false }
        if job.cloudProvider != nil, !accounts.contains(where: { $0.id == job.cloudAccountID && $0.provider == job.cloudProvider }) {
            statuses[job.id] = "계정 연결 필요"
            if !automatic { error = "클라우드 계정을 연결하고 작업 수정에서 계정과 백업 폴더를 선택하세요." }
            return false
        }
        statuses[job.id] = "변경 기록 확인 중"; log("\(job.name): 백업 시작")
        let engine = self.engine, cloudEngine = self.cloudEngine, coordinator = self.coordinator
        let remoteStorage: (any RemoteStorage)?
        do { remoteStorage = job.cloudProvider == nil ? nil : try remote(job) }
        catch { statuses[job.id] = "오류"; self.error = error.localizedDescription; return false }
        let retention = max(1, UserDefaults.standard.object(forKey: "trashRetentionDays") as? Int ?? 100)
        let runJob = job
        let gate = RunPauseGate(); pauseGates[job.id] = gate
        let session = SyncSession(job: job), runID = session.id
        sessions.insert(session, at: 0); if followLatest { sessionSelection = runID }
        let updateProgress: @Sendable (BackupProgress) -> Void = { [weak self] p in
            gate.wait()
            Task { @MainActor in
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == runID && $0.active }) else { return }
                self.progress[runJob.id] = p; self.sessions[i].progress = p
            }
        }
        running[job.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if let i = self.sessions.firstIndex(where: { $0.id == runID }), self.sessions[i].end == nil {
                    self.sessions[i].end = Date(); self.sessions[i].outcome = self.statuses[job.id] ?? "중단됨"
                    self.sessions[i].issues = self.issues.filter { $0.jobID == job.id }
                }
                self.pauseGates.removeValue(forKey: job.id)
            }
            let watcherReady = await self.watchers[job.id]?.flushPendingEvents() ?? false
            guard !Task.isCancelled else { self.running.removeValue(forKey: job.id); return }
            let journal = self.journals[job.id] ?? ChangeJournal(), checkpoint = journal.sequence
            let doFull = BackupScanPolicy.requiresFullScan(explicit: full, watcherReady: watcherReady, journal: journal,
                network: self.isNetwork(job.source) || (job.cloudProvider == nil && self.isNetwork(job.destination)))
            let changedPaths = doFull ? nil : Set(journal.pending.keys)
            let deferredPaths = automatic ? Set(self.waitingIssues.filter { $0.jobID == job.id && ($0.waiting?.nextAttempt ?? .distantPast) > Date() }.map(\.path)) : []
            self.statuses[job.id] = doFull ? "전체 검사 중" : "변경 파일 검사 중"
            let worker = Task.detached {
                if let decisions { return try await coordinator.apply(decisions, job: runJob, storage: remoteStorage, progress: updateProgress) }
                if runJob.mode == .twoWay { return try await coordinator.run(runJob, storage: remoteStorage, deferredPaths: deferredPaths, progress: updateProgress) }
                if let remoteStorage { return try await cloudEngine.run(job, storage: remoteStorage, fullScan: doFull, changedPaths: changedPaths, deferredPaths: deferredPaths, progress: updateProgress) }
                return try await engine.run(job, fullScan: doFull, changedPaths: changedPaths, deferredPaths: deferredPaths, progress: updateProgress)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                let previousIssues: [BackupIssue] = self.issues.filter { $0.jobID == job.id }
                self.issues.removeAll { $0.jobID == job.id && !deferredPaths.contains($0.path) && ((doFull && decisions == nil) || $0.path.isEmpty || result.evaluated($0.path)) }
                let newIssues = result.issues.filter { issue in !previousIssues.contains { old in self.sameIssue(old, issue) } }
                if !newIssues.isEmpty, self.mainVisible, UserDefaults.standard.bool(forKey: "errorSound") { NSSound(named: "Basso")?.play() }
                self.issues.append(contentsOf: result.issues.map { (issue: BackupIssue) -> BackupIssue in
                    var stable = issue
                    if let previous = previousIssues.first(where: { old in old.path == issue.path && (self.sameIssue(old, issue) || (old.waiting != nil && issue.waiting != nil)) }) {
                        stable.id = previous.id
                        if var waiting = previous.waiting, issue.waiting != nil { waiting.attempted(); stable.waiting = waiting }
                    }
                    return stable
                })
                if let i = self.sessions.firstIndex(where: { $0.id == runID }) { self.sessions[i].result = result }
                let remaining = self.issues.filter { $0.jobID == job.id }
                let waitingCount = remaining.filter { $0.waiting != nil }.count
                self.statuses[job.id] = remaining.isEmpty ? "완료" : (waitingCount == remaining.count ? "사용 중 대기 \(waitingCount)" : "확인 필요 \(remaining.count)")
                if remaining.isEmpty, self.mainVisible, UserDefaults.standard.bool(forKey: "completionSound"),
                   !automatic || result.copied + result.removed > 0 { NSSound(named: "Glass")?.play() }
                self.log("\(job.name): 복사 \(result.copied), 건너뜀 \(result.skipped), 휴지통 \(result.removed), 확인 \(result.issues.count)")
                if result.issues.isEmpty {
                    do {
                        let pruned = if let remoteStorage { try await cloudEngine.pruneTrash(job, storage: remoteStorage, retentionDays: retention) } else { try await engine.pruneTrash(job, retentionDays: retention) }
                        if job.mode == .twoWay || decisions != nil {
                            var originalTrash = job; originalTrash.destination = job.source; originalTrash.cloudProvider = nil
                            _ = try await engine.pruneTrash(originalTrash, retentionDays: retention)
                        }
                        if pruned > 0 { self.log("보관기간이 지난 휴지통 파일 \(pruned)개 정리") }
                    } catch { self.log("휴지통 자동 정리 보류: \(error.localizedDescription)") }
                }
                var current = self.journals[job.id] ?? journal
                if decisions == nil { current.acknowledge(through: checkpoint, full: doFull, retry: self.issues.filter { $0.jobID == job.id }.map(\.path)) }
                self.journals[job.id] = current; self.saveJournal(job.id)
                if self.issues.contains(where: { $0.jobID == job.id && !$0.conflict }) { self.scheduleRetry(job.id) } else { self.retries.removeValue(forKey: job.id); self.saveRetries() }
                self.save()
            } catch is CancellationError { self.statuses[job.id] = self.jobs.first(where: { $0.id == job.id })?.stopped == true ? "중단됨" : "일시정지"; self.log("\(job.name): 중지됨, 다음 실행에서 재검사") }
            catch {
                do {
                    self.statuses[job.id] = "오류"; self.log("\(job.name): \(error.localizedDescription)")
                    if !self.issues.contains(where: { $0.jobID == job.id && $0.path.isEmpty && $0.reason == error.localizedDescription }) {
                        self.issues.append(BackupIssue(jobID: job.id, path: "", reason: error.localizedDescription, conflict: false))
                        self.error = error.localizedDescription
                    }
                    self.scheduleRetry(job.id); self.save()
                }
            }
            self.running.removeValue(forKey: job.id)
        }
        return true
    }
    func applyJobList(_ plan: JobListImportPlan) throws -> URL {
        guard configurationUsable, running.isEmpty, !busyTrash, !validatingCloud else { throw BackupError.unsafe("작업이 시작되었습니다. 완료된 뒤 다시 가져오세요.") }
        watchers.removeAll()
        let backupURL: URL
        do {
            backupURL = try JobListFiles.replace(plan, current: jobs, settingsURL: settingsURL, backupDirectory: Storage.applicationDirectory.appendingPathComponent("job-list-backups"))
        } catch { rebuildWatchers(); throw error }
        jobs = plan.jobs
        journals = journals.filter { plan.reusedIDs.contains($0.key) }
        retries = retries.filter { plan.reusedIDs.contains($0.key) }
        issues = issues.filter { plan.reusedIDs.contains($0.jobID) }
        statuses = [:]; progress = [:]; selection = nil; trash = []; trashJob = nil
        rebuildWatchers()
        return backupURL
    }
    private func sameIssue(_ a: BackupIssue, _ b: BackupIssue) -> Bool {
        guard a.path == b.path, a.reason == b.reason else { return false }
        return a.conflict == b.conflict
    }
    func runSelected(full: Bool = false) { if let job = selected { run(job, full: full) } }
    func runAll() { for job in jobs { run(job) } }
    var waitingIssues: [BackupIssue] { issues.filter { $0.waiting != nil } }
    func canRetryWaiting(_ id: UUID) -> Bool { jobs.contains { $0.id == id && !$0.paused } && running[id] == nil && !busyTrash && !isImportingJobList }
    func retryWaiting(jobID: UUID? = nil) {
        let ids = Set(waitingIssues.filter { jobID == nil || $0.jobID == jobID }.map(\.jobID))
        for job in jobs where ids.contains(job.id) && canRetryWaiting(job.id) { run(job) }
    }
    private func journalURL(_ id: UUID) -> URL { Storage.applicationDirectory.appendingPathComponent("changes/\(id).json") }
    private func saveJournal(_ id: UUID) { do { try Storage.save(journals[id] ?? ChangeJournal(), to: journalURL(id)) } catch { configurationUsable = false; self.error = "변경 기록 저장 실패: \(error.localizedDescription)" } }
    private func saveRetries() { do { try Storage.save(retries, to: Storage.applicationDirectory.appendingPathComponent("retries.json")) } catch { self.error = error.localizedDescription } }
    private func scheduleRetry(_ id: UUID) {
        var retry = retries[id] ?? RetryState(); retry.attempts += 1
        retry.next = Date().addingTimeInterval(min(300, 30 * pow(2, Double(min(4, retry.attempts - 1)))))
        let problems = issues.filter { $0.jobID == id && !$0.conflict }
        let waitingDates = problems.compactMap { $0.waiting?.nextAttempt }
        if problems.allSatisfy({ $0.waiting != nil }), let next = waitingDates.min() { retry.next = next }
        else if let next = waitingDates.min() { retry.next = min(retry.next, next) }
        retries[id] = retry; saveRetries()
    }
    private func isNetwork(_ path: String) -> Bool {
        let local = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal
        return local == false || (local == nil && path.hasPrefix("/Volumes/"))
    }
    func rebuildWatchers() {
        watchers.removeAll()
        for job in jobs {
            if journals[job.id] == nil { journals[job.id] = ChangeJournal() }
            let roots = job.cloudProvider == nil ? [job.source, job.destination] : [job.source]
            watchers[job.id] = FolderWatcher(paths: roots, since: journals[job.id]?.eventID) { [weak self] events in
                MainActor.assumeIsolated { self?.record(events, jobID: job.id, roots: roots) }
            }
        }
    }
    private func record(_ events: [FolderWatcher.Event], jobID: UUID, roots: [String]) {
        var paths: Set<String> = [], full = false
        let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for event in events {
            if event.flags & lost != 0 { full = true }
            if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
            let path = BackupEngine.canonical(event.path).path
            let ownData = Storage.applicationDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            if path == ownData || path.hasPrefix(ownData + "/") { continue }
            for rootPath in roots {
                let root = BackupEngine.canonical(rootPath).path
                if path == root { full = true }
                else if path.hasPrefix(root + "/") {
                    let relative = String(path.dropFirst(root.count + 1))
                    if relative.split(separator: "/").first?.hasPrefix(".safesync-") != true { paths.insert(relative) }
                }
            }
        }
        // Ignore our own journal writes and reserved staging/trash events; persisting their cursor would itself generate another event.
        guard !paths.isEmpty || full else { return }
        var journal = journals[jobID] ?? ChangeJournal()
        journal.record(paths: Array(paths), eventID: events.map(\.id).max(), requireFull: full)
        journals[jobID] = journal; saveJournal(jobID)
        if !paths.isEmpty || full { retries.removeValue(forKey: jobID) }
    }
    func tick() {
        guard configurationUsable, !isImportingJobList else { return }
        tickCount += 1
        let now = Date(), clock = DateFormatter(), day = DateFormatter()
        clock.dateFormat = "HH:mm"; day.dateFormat = "yyyy-MM-dd"
        for i in jobs.indices where !jobs[i].paused && jobs[i].stopped != true {
            let job = jobs[i]
            if let retry = retries[job.id], now < retry.next { continue }
            if job.scheduled {
                if (clock.string(from: now) >= job.scheduleTime && job.lastScheduledDay != day.string(from: now)) || retries[job.id] != nil {
                    if run(job, automatic: true) { jobs[i].lastScheduledDay = day.string(from: now); save() }
                }
            } else {
                let journal = journals[job.id] ?? ChangeJournal()
                let pollRemote = job.cloudProvider != nil && tickCount % 3 == 1
                let pollNetwork = (watchers[job.id]?.isOperational != true || isNetwork(job.source) || (job.cloudProvider == nil && isNetwork(job.destination))) && tickCount % 3 == 1
                let changed = journal.needsFullScan() || !journal.pending.isEmpty
                // Conflicts wait for new filesystem events or a manual choice, rather than re-alerting every tick.
                let onlyConflicts = !journal.pending.isEmpty && journal.pending.keys.allSatisfy { path in issues.contains { $0.jobID == job.id && $0.path == path && $0.conflict } }
                if pollRemote || pollNetwork || retries[job.id] != nil || (changed && !onlyConflicts) { run(job, automatic: true) }
            }
        }
    }
    func resolve(_ issue: BackupIssue, action: ConflictAction) {
        guard !isImportingJobList, let job = jobs.first(where: { $0.id == issue.jobID }), running[job.id] == nil, !busyTrash else { return }
        busyTrash = true
        Task {
            defer { busyTrash = false }
            do { if job.cloudProvider != nil { try await cloudEngine.resolve(issue, job: job, storage: remote(job), action: action) } else { try await engine.resolve(issue, job: job, action: action) }; issues.removeAll { $0.id == issue.id }; save(); log("충돌 처리 완료: \(issue.path)") }
            catch { self.error = error.localizedDescription }
        }
    }
    func applyDecisions(_ decisions: [ResolutionDecision], session: SyncSession, review: ComparisonReview? = nil) {
        let authorized = review.map { canUseReview($0) && FileComparisons.sameEndpoints($0.job, session.job) } ?? canRepair(session)
        guard authorized, !decisions.isEmpty, let job = jobs.first(where: { FileComparisons.sameEndpoints($0, session.job) }),
              decisions.allSatisfy({ FileComparisons.sameEndpoints($0.comparison.job, job) }) else {
            error = "작업이 실행 중이거나 비교 후 상태가 바뀌었습니다. 대기 상태에서 현재 파일을 다시 비교하세요."; return
        }
        var runnable = job; runnable.paused = false
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].paused = false }
        workspace = .sync; detailTab = .progress
        _ = run(runnable, decisions: decisions)
    }
    func loadTrash() {
        guard !isImportingJobList, let job = selected, running[job.id] == nil else { return }
        if trashJob?.id != job.id { trash = [] }
        trashJob = job; refreshTrash(job)
    }
    func refreshTrash(_ job: BackupJob) {
        guard running[job.id] == nil else { error = "실행을 완료하거나 작업 종료 후 휴지통을 확인하세요."; return }
        let token = UUID(); trashGeneration = token; busyTrash = true
        Task {
            do {
                let listed = job.cloudProvider == nil ? try await engine.listTrash(job) : try await cloudEngine.listTrash(job, storage: remote(job))
                if trashGeneration == token { trash = listed }
            } catch { if trashGeneration == token { self.error = error.localizedDescription } }
            if trashGeneration == token { busyTrash = false }
        }
    }
    func restore(_ items: [TrashItem]) {
        guard let job = trashJob, !busyTrash else { return }
        guard running[job.id] == nil else { error = "백업 완료 또는 일시정지 후 복구하세요."; return }
        guard Set(items.map(\.path)).count == items.count else { error = "같은 경로의 버전은 한 번에 하나만 복구하세요."; return }
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].paused = true; save() }
        busyTrash = true
        Task {
            do { if job.cloudProvider != nil { try await cloudEngine.restore(items, job: job, storage: remote(job)) } else { for item in items { try await engine.restore(item, job: job) } }; log("휴지통 복구 완료 · 작업은 일시정지 상태입니다.") }
            catch { self.error = error.localizedDescription }
            busyTrash = false; refreshTrash(job)
        }
    }
    func deleteTrash(_ items: [TrashItem]) {
        guard let job = trashJob, !busyTrash, !items.isEmpty else { return }
        guard running[job.id] == nil else { error = "백업 완료 또는 일시정지 후 휴지통을 정리하세요."; return }
        busyTrash = true
        Task { do { if job.cloudProvider != nil { try await cloudEngine.deleteTrash(items, job: job, storage: remote(job)) } else { try await engine.deleteTrash(items, job: job) } } catch { self.error = error.localizedDescription }; busyTrash = false; refreshTrash(job) }
    }
    private func installWindowPolicy() {
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let window = notification.object as? NSWindow, window.title == "SafeSync" else { return }
                    if name == NSWindow.willCloseNotification || name == NSWindow.didMiniaturizeNotification {
                        self.mainVisible = false
                        self.hiddenCompanions = NSApp.windows.filter { $0 !== window && ($0.title == "백업 비교 및 충돌 처리" || $0.title == "SafeSync 휴지통") && $0.isVisible }
                        for companion in self.hiddenCompanions { companion.orderOut(nil) }
                        if UserDefaults.standard.bool(forKey: "windowSound") { NSSound(named: "Pop")?.play() }
                    } else if !self.mainVisible {
                        self.mainVisible = true
                        for companion in self.hiddenCompanions { companion.orderFront(nil) }; self.hiddenCompanions = []
                    }
                }
            })
        }
    }
    func remote(_ job: BackupJob) throws -> any RemoteStorage {
        guard let account = accounts.first(where: { $0.id == job.cloudAccountID && $0.provider == job.cloudProvider }) else { throw BackupError.unsafe("클라우드 계정을 연결하세요.") }
        return Self.storage(account)
    }
    static func storage(_ account: CloudAccount) -> any RemoteStorage { account.provider == .dropbox ? DropboxStorage(account: account) : GoogleDriveStorage(account: account) }
    func addAccount(_ account: CloudAccount) throws {
        accounts.append(account)
        do { try persist() } catch { accounts.removeAll { $0.id == account.id }; try? CredentialVault.delete(account: account.id); throw error }
        log("클라우드 계정 연결: \(account.name)")
    }
    func validateCloudAccount(_ account: CloudAccount) {
        guard !validatingCloud, !busyTrash else { return }
        validatingCloud = true; cloudValidationReport = "새로운 SafeSync-test 폴더에서 안전한 전송과 복구를 확인하고 있습니다."
        Task {
            defer { validatingCloud = false }
            do {
                let report = try await CloudDiagnostics.run(account: account)
                log(report)
                cloudValidationReport = report
            } catch { self.cloudValidationReport = "클라우드 검증 실패: \(error.localizedDescription)"; log(self.cloudValidationReport!) }
        }
    }
    func disconnect(_ account: CloudAccount) {
        guard !jobs.contains(where: { $0.cloudAccountID == account.id && running[$0.id] != nil }) else { error = "이 계정의 백업을 먼저 일시정지하세요."; return }
        let alert = NSAlert(); alert.messageText = "‘\(account.name)’ 연결을 해제할까요?"; alert.informativeText = "해당 작업은 일시정지되고 Keychain 인증 정보만 삭제됩니다. 클라우드 파일은 보존합니다."; alert.addButton(withTitle: "연결 해제"); alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try CredentialVault.delete(account: account.id); accounts.removeAll { $0.id == account.id }; for i in jobs.indices where jobs[i].cloudAccountID == account.id { jobs[i].paused = true }; save() }
        catch { self.error = error.localizedDescription }
    }
    func status(_ job: BackupJob) -> String { job.stopped == true ? "종료 대기" : job.paused ? "일시정지" : statuses[job.id] ?? "대기 중" }
    func quit() { for task in running.values { task.cancel() }; NSApp.terminate(nil) }
}
