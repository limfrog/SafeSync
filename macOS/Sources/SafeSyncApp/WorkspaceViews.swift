import SwiftUI
import SafeSyncCore

struct ProgressViewScreen: View {
    @EnvironmentObject var store: Store
    @ViewState private var historyHeight = 155.0
    var run: SyncSession? { store.selectedSession }
    var runIssues: [BackupIssue] { run?.issues ?? store.issues }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("실행 이력").font(.headline); Text("앱을 실행한 동안의 기록").font(.caption).foregroundStyle(.secondary); Spacer(); Toggle("최신 실행 따라가기", isOn: $store.followLatest).toggleStyle(.checkbox).onChange(of: store.followLatest) { _, value in if value { store.sessionSelection = store.sessions.first?.id } } }
            Table(store.sessions, selection: $store.sessionSelection) {
                TableColumn("상태", value: \.outcome).width(95)
                TableColumn("작업") { Text($0.job.name) }
                TableColumn("시작") { Text($0.start.formatted(date: .omitted, time: .standard)) }.width(95)
                TableColumn("종료") { Text($0.end?.formatted(date: .omitted, time: .standard) ?? "—") }.width(95)
                TableColumn("소요", value: \.duration).width(80)
                TableColumn("결과") { r in Text("복사 \(r.result?.copied ?? 0) · 동일 \(r.result?.skipped ?? 0) · 휴지통 \(r.result?.removed ?? 0)") }
            }.frame(height: historyHeight).onChange(of: store.sessionSelection) { _, id in if id != store.sessions.first?.id { store.followLatest = false } }
            ResizeHandle(height: $historyHeight, minimum: 85, maximum: 280)
            if let run {
                HStack {
                    location("원본", path: run.job.source)
                    Image(systemName: run.job.mode == .twoWay ? "arrow.left.arrow.right" : "arrow.right").foregroundStyle(Color.accentColor)
                    location("백업", path: run.job.destination)
                    if !run.active && !store.canRepair(run) { Text("이전 기록 · 문제 해결에서 현재 파일 재비교 가능").font(.caption).foregroundStyle(.secondary) }
                }
            }
            TabView(selection: $store.detailTab) {
                detail.tag(SyncDetailTab.progress).tabItem { Text("진행 상세") }
                issueList(runIssues.filter(\.conflict)).tag(SyncDetailTab.conflicts).tabItem { Text("충돌 \(runIssues.filter(\.conflict).count)") }
                waiting.tag(SyncDetailTab.waiting).tabItem { Text("사용 중 \(runIssues.filter { $0.waiting != nil }.count)") }
                issueList(runIssues.filter { !$0.conflict && $0.waiting == nil }).tag(SyncDetailTab.errors).tabItem { Text("오류 \(runIssues.filter { !$0.conflict && $0.waiting == nil }.count)") }
                ProblemWorkspace(run: run, issues: store.problemIssues(runIssues, jobID: run?.job.id)).tag(SyncDetailTab.problems).tabItem { Text("문제 해결") }
            }
        }
    }
    func location(_ title: String, path: String) -> some View { VStack(alignment: .leading) { Text(title).font(.caption).foregroundStyle(.secondary); Text(path).lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled) }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)) }
    var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run {
                Text("\(run.job.name) · \(run.job.mode.title)").font(.headline)
                Text(run.outcome).foregroundStyle(run.issues.isEmpty ? Color.secondary : .orange)
                if let p = run.progress {
                    Text(p.path).lineLimit(2).textSelection(.enabled)
                    Text(p.stage ?? "파일 비교·검증").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: Double(p.completed), total: Double(max(1, p.total)))
                    HStack { Text("\(p.completed) / \(p.total)"); Spacer(); if let size = p.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) } }
                    if let bytes = p.transferred, let size = p.size { ProgressView(value: Double(bytes), total: Double(max(1, size))) }
                }
                HStack {
                    if run.active { Button(run.outcome == "일시정지" ? "다시 시작" : "일시정지") { store.selection = run.job.id; store.togglePause() } }
                    else if store.canRepair(run) { Button("작업 다시 실행") { store.run(run.job) }; Button("작업 문제 해결") { store.detailTab = .problems } }
                }
            } else { ContentUnavailableView("실행 이력이 없습니다", systemImage: "clock", description: Text("작업을 실행하면 진행 상황과 비교 결과가 표시됩니다.")) }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }
    func issueList(_ issues: [BackupIssue]) -> some View {
        VStack(alignment: .leading) {
            Table(issues) {
                TableColumn("파일") { issue in Text(issue.path).onTapGesture(count: 2) { if !issue.automaticNetworkRetry { store.showProblems(issue) } } }
                TableColumn("원본 정보") { Text(info($0.source)).font(.caption) }
                TableColumn("백업 정보") { Text(info($0.backup)).font(.caption) }
                TableColumn("확인 사유", value: \.reason)
                TableColumn("처리") { issue in
                    if issue.automaticNetworkRetry { Text("자동 재시도").font(.caption) }
                    else { Button("파일 비교") { store.showProblems(issue) }.disabled(issue.path.isEmpty) }
                }.width(95)
            }
            Text("일시적 네트워크 오류는 동기화 끝에 자동 재시도합니다. 과거 이력은 당시 기록입니다. 그 외 문제는 양쪽 정보를 확인한 뒤 처리하세요.").font(.caption).foregroundStyle(.secondary)
        }.padding(10)
    }
    func info(_ stamp: FileStamp?) -> String { guard let stamp else { return "없음 / 확인 필요" }; return "\(stamp.size) B · \(stamp.modified.formatted(date: .numeric, time: .shortened))" }
    var waiting: some View {
        VStack {
            HStack { Text("사용 중인 파일은 30초부터 최대 5분 간격으로 다시 시도합니다.").font(.caption); Spacer(); Button("지금 다시 시도") { store.retryWaiting(jobID: run?.job.id) }.disabled(run.map { !store.canRepair($0) } ?? true) }
            Table(runIssues.filter { $0.waiting != nil }) {
                TableColumn("파일", value: \.path)
                TableColumn("최초 대기") { Text($0.waiting?.firstWait.formatted() ?? "") }
                TableColumn("최근 시도") { Text($0.waiting?.lastAttempt.formatted() ?? "") }
                TableColumn("시도 횟수") { Text("\($0.waiting?.attempts ?? 0)") }.width(70)
                TableColumn("다음 시도") { Text($0.waiting?.nextAttempt.formatted() ?? "") }
            }
        }.padding(12)
    }
}

struct ProblemWorkspace: View {
    @EnvironmentObject var store: Store
    let run: SyncSession?
    let issues: [BackupIssue]
    @ViewState private var selection: Set<UUID> = []
    @ViewState private var comparisons: [UUID: FileComparison] = [:]
    @ViewState private var choices: [UUID: ConflictAction] = [:]
    @ViewState private var loading = false
    @ViewState private var failure: String?
    @ViewState private var confirm = false
    @ViewState private var generation = UUID()
    @ViewState private var review: ComparisonReview?
    var chosen: [BackupIssue] { issues.filter { selection.contains($0.id) } }
    var focused: FileComparison? { chosen.first.flatMap { comparisons[$0.id] } }
    var editable: Bool { review.map { store.canUseReview($0) } ?? false }
    var latestRunID: UUID? { run.flatMap { selected in store.sessions.first(where: { $0.job.id == selected.job.id })?.id } }
    var body: some View {
        HSplitView {
            List(issues, selection: $selection) { issue in
                VStack(alignment: .leading, spacing: 5) {
                    Text(issue.path.isEmpty ? "작업 문제" : issue.path).lineLimit(2)
                    Text(choiceText(issue)).font(.caption).foregroundStyle(choices[issue.id] == nil ? Color.secondary : .accentColor).lineLimit(2)
                }.padding(.vertical, 4).tag(issue.id)
            }.frame(minWidth: 210, idealWidth: 260, maxWidth: 360)
            VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading { ProgressView("양쪽 정보 확인 중") }
                    if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                    if let c = focused {
                        Text(c.path).font(.headline).textSelection(.enabled)
                        HStack(alignment: .top) { fileCard("원본", file: c.source, root: c.job.source, error: c.sourceError); fileCard("백업", file: c.backup, root: c.job.destination, error: c.backupError) }
                        if !c.duplicates.isEmpty { Text("중복 사본 \(c.candidates.count)개 · 이름만 정리하면 모든 사본이 보존됩니다.").foregroundStyle(.orange); ForEach(c.candidates) { Text("\($0.name) · ID \($0.id)").font(.caption).textSelection(.enabled) } }
                        ForEach(ConflictAction.allCases, id: \.self) { action in
                            Button(action.title) { choose(action) }
                                .disabled(!editable || loading || chosen.isEmpty || !chosen.allSatisfy { comparisons[$0.id]?.allows(action) == true && !store.resolutionState($0.jobID, path: $0.path).executing })
                        }
                    } else if !loading {
                        Text(chosen.first?.reason ?? "왼쪽에서 확인할 파일을 선택하세요.").textSelection(.enabled)
                        if chosen.contains(where: { $0.path.isEmpty }) {
                            Text("원본·백업 폴더의 연결과 접근 권한을 확인하세요. 클라우드 계정은 환경설정에서 확인할 수 있습니다.").foregroundStyle(.secondary)
                            if let run, editable, !store.isRunning(run.job.id) { Button("작업 수정") { store.editing = store.jobs.first { $0.id == run.job.id } }; Button("연결 확인 후 다시 실행") { store.run(run.job, full: true) } }
                        }
                    }
                    Text("실행 중에는 버튼 한 번으로 예약하고 현재 동기화 전체가 끝난 뒤 처리합니다. 실행 전에 다른 버튼을 누르면 마지막 선택으로 바뀝니다. 파일·연결이 바뀌면 덮어쓰지 않고 재확인합니다.").font(.caption).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(editable ? "정보 다시 확인" : "현재 파일 다시 비교") { refresh(authorize: true) }.disabled(loading || selection.isEmpty || !(run.map { store.canBeginReview($0) } ?? false))
                if let run, store.isRunning(run.job.id) {
                    Text("실행 대기 \(store.queuedResolutionCount(run.job.id))개").font(.caption)
                    Button("선택 예약 취소") { store.cancelQueuedResolutions(run.job.id, paths: Set(chosen.map(\.path))) }
                        .disabled(!chosen.contains { store.resolutionState($0.jobID, path: $0.path).action != nil && !store.resolutionState($0.jobID, path: $0.path).executing })
                }
                Spacer()
                if run.map({ !store.isRunning($0.job.id) }) ?? true {
                    Button("선택한 처리 적용 (\(choices.count))") { confirm = true }.buttonStyle(.borderedProminent).disabled(!editable || choices.isEmpty || loading)
                }
            }.padding(12)
            }.frame(minWidth: 500)
        }.onChange(of: selection) { _, _ in refresh(reset: false) }
        .onChange(of: run?.id) { _, _ in selection = []; comparisons = [:]; choices = [:]; review = nil; loading = false; generation = UUID() }
        .onChange(of: latestRunID) { _, _ in comparisons = [:]; choices = [:]; review = nil; loading = false; generation = UUID(); refresh(authorize: true) }
        .onChange(of: store.problemSelection) { _, id in if let id { selection = [id] } }
        .onAppear {
            if let id = store.problemSelection, selection != [id] { selection = [id] }
            else { refresh(reset: false) }
        }
        .onDisappear { generation = UUID(); loading = false }
        .confirmationDialog("선택한 처리를 적용할까요?", isPresented: $confirm, titleVisibility: .visible) {
            Button("처리 적용") {
                guard let run, let review, editable else { return }
                let decisions = choices.compactMap { id, action in comparisons[id].map { ResolutionDecision($0, action: action) } }
                store.applyDecisions(decisions, session: run, review: review); choices = [:]
            }
            Button("취소", role: .cancel) {}
        } message: { Text(choices.values.map(\.title).sorted().joined(separator: "\n") + "\n적용 직전에 양쪽 정보를 다시 검증하며, 교체된 파일은 SafeSync 휴지통에 보존합니다.") }
    }
    func choiceText(_ issue: BackupIssue) -> String {
        let state = store.resolutionState(issue.jobID, path: issue.path)
        if let action = state.action { return (state.executing ? "처리 중 · " : "예약 · ") + action.title }
        return choices[issue.id]?.title ?? issue.reason
    }
    func choose(_ action: ConflictAction) {
        guard let run else { return }
        if store.isRunning(run.job.id) {
            guard let review else { return }
            let decisions = chosen.compactMap { comparisons[$0.id].map { ResolutionDecision($0, action: action) } }
            if decisions.count == chosen.count, store.applyDecisions(decisions, session: run, review: review) { choices = [:] }
        } else { for issue in chosen { choices[issue.id] = action } }
    }
    func fileCard(_ title: String, file: ComparedFile?, root: String, error: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline); Text(root).font(.caption).lineLimit(2).textSelection(.enabled)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            else if let file {
                Text(file.folder ? "폴더" : ByteCountFormatter.string(fromByteCount: file.stamp.size, countStyle: .file))
                Text("생성: \(file.stamp.created == .distantPast ? "정보 없음" : file.stamp.created.formatted())").font(.caption)
                Text("수정: \(file.stamp.modified.formatted())").font(.caption)
                Text("ID: \(file.identity)").font(.caption).textSelection(.enabled)
            } else { Text("파일 없음").foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .topLeading).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
    func refresh(reset: Bool = true, authorize: Bool = false) {
        let token = UUID(); generation = token; failure = nil
        if reset { choices = [:]; comparisons = [:] } else { for id in selection { choices.removeValue(forKey: id) } }
        guard let run, !chosen.isEmpty else { loading = false; return }
        if authorize || (review == nil && store.canBeginReview(run)) {
            review = store.beginReview(run)
        }
        guard let checked = review, store.canUseReview(checked) else { loading = false; return }
        let job = checked.job
        let items = chosen; loading = true
        Task {
            var fetched: [UUID: FileComparison] = [:]
            do {
                let storage = job.cloudProvider == nil ? nil : try store.remote(job)
                for issue in items where !issue.path.isEmpty { fetched[issue.id] = try await FileComparisons.read(job: job, path: issue.path, storage: storage) }
                guard generation == token else { return }
                if store.canUseReview(checked) { comparisons.merge(fetched) { _, new in new } }
                else { review = nil; comparisons = [:]; choices = [:] }
            } catch { if generation == token { failure = error.localizedDescription } }
            if generation == token { loading = false }
        }
    }
}

struct TrashView: View {
    @EnvironmentObject var store: Store
    @ViewState private var selection: Set<UUID> = []
    @ViewState private var search = ""
    @ViewState private var sourceTrash = false
    @ViewState private var confirmDelete = false
    var visible: [TrashItem] { store.trash.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) } }
    var chosen: [TrashItem] { visible.filter { selection.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("작업", selection: $store.selection) { Text("작업 선택").tag(UUID?.none); ForEach(store.jobs) { Text($0.name).tag(Optional($0.id)) } }.frame(maxWidth: 360)
                Picker("휴지통 위치", selection: $sourceTrash) { Text("백업 휴지통").tag(false); Text("원본 휴지통").tag(true) }.pickerStyle(.segmented).frame(width: 240)
                Spacer(); if store.busyTrash { ProgressView().controlSize(.small) }
            }.disabled(store.busyTrash)
            HStack {
                TextField("파일 이름 또는 원래 경로 검색", text: $search)
                Button("새로고침") { refresh() }; Button("모두 선택") { selection = Set(visible.map(\.id)) }; Button("선택 해제") { selection = [] }
            }.disabled(store.busyTrash)
            HStack {
                Text("\(visible.count)개 · \(ByteCountFormatter.string(fromByteCount: visible.reduce(0) { $0 + $1.size }, countStyle: .file))")
                Spacer(); Text("보관기간 \(UserDefaults.standard.object(forKey: "trashRetentionDays") as? Int ?? 100)일 · 선택 \(chosen.count)개")
            }.font(.caption).foregroundStyle(.secondary)
            Table(visible, selection: $selection) {
                TableColumn("파일 이름") { Text(URL(fileURLWithPath: $0.path).lastPathComponent) }
                TableColumn("삭제된 날짜와 시간") { Text($0.deletedAt.formatted()) }
                TableColumn("원래 경로", value: \.path)
                TableColumn("크기") { Text(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)) }.width(95)
            }.overlay { if store.trashJob == nil { Text("작업을 선택하세요.").foregroundStyle(.secondary) } }
            if let item = chosen.first { Text("\(item.path) · \(item.deletedAt.formatted())").font(.caption).textSelection(.enabled) }
            Text("복구하면 작업은 일시정지됩니다. 파일을 확인한 뒤 다시 시작하세요.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("선택 파일 완전 삭제", role: .destructive) { confirmDelete = true }.disabled(chosen.isEmpty)
                Spacer(); Button("백업 작업으로") { store.navigate(.jobs) }
                Button("선택 파일 복구") { store.restore(chosen) }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            }.disabled(store.busyTrash)
        }.onChange(of: store.selection) { _, _ in refresh() }.onChange(of: sourceTrash) { _, _ in refresh() }
        .onAppear { refresh() }
        .confirmationDialog("선택한 \(chosen.count)개 파일을 완전히 삭제할까요?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("완전 삭제", role: .destructive) { store.deleteTrash(chosen) }; Button("취소", role: .cancel) {} } message: { Text("이 작업은 되돌릴 수 없습니다.") }
    }
    func refresh() {
        selection = []
        guard var job = store.selected else { store.trashJob = nil; store.trash = []; return }
        if sourceTrash { job.destination = job.source; job.cloudProvider = nil; job.cloudAccountID = nil; job.cloudFolderID = nil }
        store.trashJob = job; store.refreshTrash(job)
    }
}
