import SwiftUI
import AppKit
import ServiceManagement
import SafeSyncCore

// Explicit alias selects the property wrapper on SDKs that also declare a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var presentation: AppPresentation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        presentation = AppPresentation()
        statusBar = StatusBarController(store: Store.shared)
        ApplicationUpdates.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { statusBar?.showMain(); return true }
}
@main struct SafeSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    @AppStorage("appearance") private var appearance = "system"
    private var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    var body: some Scene {
        Window("SafeSync", id: "main") {
            MainView().environmentObject(store).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }.defaultSize(width: 1180, height: 720)
        .commands {
            AboutCommands()
            CommandGroup(after: .newItem) {
                Button("새 백업 작업") { store.editing = BackupJob() }.keyboardShortcut("n")
                Divider()
                Button("작업 목록 내보내기") { store.exportJobList() }.disabled(store.isImportingJobList)
                Button("작업 목록 가져오기") { store.importJobList() }.disabled(store.isImportingJobList)
            }
            CommandMenu("보기") {
                ForEach(WorkspaceTab.allCases, id: \.self) { tab in Button(tab.rawValue) { store.navigate(tab) } }
            }
            CommandMenu("작업") {
                Button("작업 수정") { store.editing = store.selected }.disabled(store.selected == nil)
                Button("작업 삭제") { store.removeSelected() }.disabled(store.selected == nil)
                Divider()
                Button("지금 백업") { store.runSelected() }
                Button("전체 검사") { store.runSelected(full: true) }
                Button("모든 작업 백업") { store.runAll() }
                Button("일시정지 / 다시 시작") { store.togglePause() }
            }
        }
        Window("About SafeSync", id: "about") {
            AboutView().preferredColorScheme(colorScheme)
        }.windowResizability(.contentSize).defaultPosition(.center)
        Window("SafeSync · 확인할 메시지", id: "messages") {
            MessagesView().environmentObject(store).preferredColorScheme(colorScheme)
        }.defaultSize(width: 980, height: 580).defaultPosition(.center)
        Settings { SettingsView().environmentObject(store).preferredColorScheme(colorScheme) }
        Window("SafeSync 업데이트", id: "updates") { AppUpdateView().preferredColorScheme(colorScheme) }
            .windowResizability(.contentSize).defaultPosition(.center)

    }
}
struct MainView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow
    @AppStorage("activityHeight") private var activityHeight = 130.0
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(nsImage: BrandIcon.image).resizable().scaledToFit().frame(width: 48, height: 48)
                VStack(alignment: .leading) { Text("SafeSync").font(.title.bold()); Text("파일을 안전하게, 백업은 자동으로").foregroundStyle(.secondary) }
                Spacer()
                Label(store.runningCount > 0 ? "동기화 중 \(store.runningCount)" : "자동 검사 대기", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                Button("확인할 메시지 \(store.messageRows.count)") {
                    AppPresentation.showInDock()
                    openWindow(id: "messages")
                }
            }.padding(8)
            HStack(spacing: 20) {
                ForEach(WorkspaceTab.allCases, id: \.self) { tab in
                    Button { store.navigate(tab) } label: {
                        VStack(spacing: 9) { Text(tab.rawValue).fontWeight(store.workspace == tab ? .semibold : .regular); Rectangle().fill(store.workspace == tab ? Color.accentColor : .clear).frame(height: 3) }
                    }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                }
                Spacer(); SettingsLink { Label("환경설정", systemImage: "gearshape") }
            }.frame(height: 35)
            Divider()
            switch store.workspace {
            case .jobs: jobs
            case .sync: ProgressViewScreen()
            case .trash: TrashView()
            }
            HStack { Text("macOS \(AppInformation.version) · 로컬 · Dropbox · Google Drive"); Spacer(); Text("작업 \(store.jobs.count)개") }.font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 1060, minHeight: 680)
        .onAppear { store.openAppWindow = { id in AppPresentation.showInDock(); if id == "progress" { store.navigate(.sync) } else if id == "trash" { store.navigate(.trash) }; openWindow(id: id == "about" || id == "messages" || id == "updates" ? id : "main") } }
        .sheet(item: $store.editing) { JobEditor(job: $0).environmentObject(store) }
        .confirmationDialog("‘\(store.deleteRequest?.name ?? "")’ 작업을 삭제할까요?", isPresented: Binding(get: { store.deleteRequest != nil }, set: { if !$0 { store.deleteRequest = nil } }), titleVisibility: .visible) {
            Button("작업 삭제", role: .destructive) { store.confirmDelete() }; Button("취소", role: .cancel) { store.deleteRequest = nil }
        } message: { Text("백업 파일과 SafeSync 휴지통은 보존합니다.") }
        .alert("확인할 메시지", isPresented: Binding(get: { store.error != nil && store.mainVisible }, set: { if !$0 { store.error = nil } })) { Button("확인") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private var jobs: some View {
        VStack(spacing: 8) {
            HStack {
                Button("＋ 새 작업") { store.editing = BackupJob() }
                Menu("작업 관리") {
                    Button("작업 수정") { store.editing = store.selected }
                    Button("클라우드 연결 위치 다시 지정") { store.editing = store.selected }.disabled(store.selected?.cloudProvider == nil)
                    Button("전체 검사") { store.runSelected(full: true); store.navigate(.sync) }
                    Button("작업 종료 · 자동 실행 대기") { store.stopSelected() }
                    Divider(); Button("작업 목록 내보내기") { store.exportJobList() }; Button("작업 목록 가져오기") { store.importJobList() }.disabled(!store.canImportJobList)
                    Divider(); Button("작업 삭제", role: .destructive) { store.removeSelected() }
                }.fixedSize().disabled(store.selected == nil)
                Divider().frame(height: 24)
                Button("▶ 지금 실행") { store.runSelected(); store.navigate(.sync) }.buttonStyle(.borderedProminent).disabled(store.selected == nil || store.selected?.paused == true)
                Button(store.selected?.paused == true || store.selected?.stopped == true ? "▶ 다시 시작" : "Ⅱ 일시정지") { store.togglePause() }.disabled(store.selected == nil)
                Button("▶▶ 모든 작업") { store.runAll(); store.navigate(.sync) }
                Spacer()
            }.controlSize(.large)
            Table(store.jobs, selection: $store.selection) {
                TableColumn("작업 이름", value: \.name).width(min: 100, ideal: 140)
                TableColumn("방향") { Text($0.mode.title) }.width(130)
                TableColumn("원본 위치") { path($0.source) }.width(min: 150, ideal: 230)
                TableColumn("백업 위치") { path($0.destination) }.width(min: 150, ideal: 230)
                TableColumn("실행 방식", value: \.triggerText).width(110)
                TableColumn("상태") { Text(store.status($0)) }.width(min: 80, ideal: 110)
            }.overlay { if store.jobs.isEmpty { ContentUnavailableView("첫 백업 작업을 추가하세요", systemImage: "folder.badge.plus") } }
            ResizeHandle(height: $activityHeight, minimum: 70, maximum: 260)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("활동 기록").font(.headline); Spacer(); Button("기록 지우기") { store.activity = [] }.buttonStyle(.link) }
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(Array(store.activity.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }
            }.padding(12).frame(height: activityHeight).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
    func path(_ value: String) -> some View { Text(value).lineLimit(1).truncationMode(.middle).help(value).onTapGesture(count: 2) { if value.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: value)) } } }
}
struct ResizeHandle: View {
    @Binding var height: Double
    var minimum: Double
    var maximum: Double
    @ViewState private var initial: Double?
    var body: some View {
        Capsule().fill(.secondary.opacity(0.35)).frame(width: 44, height: 4).frame(maxWidth: .infinity).frame(height: 9).contentShape(Rectangle())
            .gesture(DragGesture().onChanged { drag in if initial == nil { initial = height }; height = min(maximum, max(minimum, (initial ?? height) - drag.translation.height)) }.onEnded { _ in initial = nil })
            .help("드래그하여 영역 높이 조절")
    }
}
struct JobEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ViewState var job: BackupJob
    @ViewState private var error: String?
    @ViewState private var showCloudPicker = false
    @ViewState private var confirmEndpointChange = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("백업 작업 설정").font(.title.bold())
            Picker("동기화 방향", selection: Binding(get: { job.mode }, set: { job.syncMode = $0 })) { ForEach(SyncMode.allCases.filter { job.cloudProvider != .googleDrive || $0 == .oneWay }, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.radioGroup).horizontalRadioGroupLayout()
            if job.cloudProvider == .googleDrive { Text("Google Drive 제한 권한은 전용 폴더의 단방향 백업만 지원합니다. 양방향은 Drive 데스크톱 폴더를 로컬 위치로 지정하세요.").font(.caption).foregroundStyle(.secondary) }
            Text(job.mode == .twoWay ? "양쪽의 변경과 삭제를 반영합니다. 양쪽에서 수정된 파일은 비교 후 직접 선택합니다." : "원본의 변경을 백업에 반영합니다. 이전 파일은 SafeSync 휴지통에 보존합니다.").font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("작업 이름", text: $job.name)
                HStack { TextField("원본 위치", text: $job.source); Button("찾아보기") { choose(source: true) } }
                Picker("백업 방식", selection: $job.cloudProvider) {
                    Text("로컬 / 네트워크 / 동기화 폴더").tag(CloudProvider?.none)
                    ForEach(CloudProvider.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.onChange(of: job.cloudProvider) { _, _ in job.cloudAccountID = nil; job.cloudFolderID = nil; job.cloudAccessMode = nil; job.destination = ""; if job.cloudProvider == .googleDrive { job.syncMode = .oneWay } }
                if let provider = job.cloudProvider {
                    Picker("클라우드 계정", selection: $job.cloudAccountID) {
                        Text("계정 선택").tag(UUID?.none)
                        ForEach(store.accounts.filter { $0.provider == provider }) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: job.cloudAccountID) { _, _ in job.cloudFolderID = nil; job.cloudAccessMode = nil; job.destination = "" }
                    HStack { Text(job.destination.isEmpty ? "백업 폴더를 선택하세요" : job.destination).lineLimit(2); Spacer(); Button("클라우드 폴더 선택") { showCloudPicker = true }.disabled(job.cloudAccountID == nil) }
                } else { HStack { TextField("백업 위치", text: $job.destination); Button("위치 선택") { choose(source: false) } } }
                Picker("실행 방식", selection: $job.scheduled) { Text("파일 변경 시").tag(false); Text("매일 정해진 시간").tag(true) }
                if job.scheduled { TextField("예약 시간 (HH:mm)", text: $job.scheduleTime) }
                if job.mode == .oneWay { Toggle("원본에서 사라진 파일은 SafeSync 휴지통으로 이동", isOn: $job.mirrorDeletes) }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("취소") { dismiss() }.keyboardShortcut(.cancelAction); Button("저장") { if let original = store.jobs.first(where: { $0.id == job.id }), !FileComparisons.sameEndpoints(original, job) { confirmEndpointChange = true } else { save() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 640)
        .confirmationDialog("변경된 위치·방향으로 새 비교 기록을 시작할까요?", isPresented: $confirmEndpointChange, titleVisibility: .visible) { Button("변경 후 일시정지 상태로 저장") { save() }; Button("취소", role: .cancel) {} } message: { Text("기존 백업 파일과 휴지통은 보존합니다. 새 위치를 확인한 뒤 직접 다시 시작하세요.") }
        .sheet(isPresented: $showCloudPicker) {
            if let account = store.accounts.first(where: { $0.id == job.cloudAccountID }) {
                CloudFolderPicker(account: account) { id, label in job.cloudFolderID = id; job.destination = "\(account.provider.title) · \(label)"; job.cloudAccessMode = account.provider == .googleDrive ? GoogleFileAccess.mode : nil; if account.provider == .googleDrive { job.syncMode = .oneWay } }
            }
        }
    }
    func save() { do { try store.upsert(job); dismiss() } catch { self.error = error.localizedDescription } }
    func choose(source: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = !source; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { if source { job.source = url.path } else { job.destination = url.path } }
    }
}
