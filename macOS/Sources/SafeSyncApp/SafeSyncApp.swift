import SwiftUI
import AppKit
import ServiceManagement
import SafeSyncCore

// Explicit alias selects the property wrapper on SDKs that also declare a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

enum BrandIcon {
    static var image: NSImage {
        let url = Bundle.main.resourceURL?.appendingPathComponent("SafeSync.png")
        let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/SafeSync.png")
        let image = url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(contentsOf: original) ?? NSImage()
        image.isTemplate = false
        return image
    }
    static func menuImage(angle: CGFloat, warning: Bool) -> NSImage {
        let icon = image
        let result = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX: 8, byY: 8)
            var rotation = AffineTransform(); rotation.rotate(byRadians: angle)
            var composed = transform; composed.append(rotation); composed.translate(x: -8, y: -8)
            (composed as NSAffineTransform).concat()
            icon.draw(in: rect.insetBy(dx: 1, dy: 1))
            NSGraphicsContext.restoreGraphicsState()
            if warning { NSColor.systemOrange.setFill(); NSBezierPath(ovalIn: NSRect(x: 11, y: 0, width: 5, height: 5)).fill() }
            return true
        }
        result.isTemplate = false; return result
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    func applicationDidFinishLaunching(_ notification: Notification) { statusBar = StatusBarController(store: Store.shared) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { statusBar?.showMain(); return true }
}
@main struct SafeSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        Window("SafeSync", id: "main") {
            MainView().environmentObject(store).preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }.defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("새 백업 작업") { store.editing = BackupJob() }.keyboardShortcut("n")
                Divider()
                Button("작업 목록 내보내기") { store.exportJobList() }.disabled(store.isImportingJobList)
                Button("작업 목록 가져오기") { store.importJobList() }.disabled(store.isImportingJobList)
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
        Window("백업 비교 및 충돌 처리", id: "progress") { ProgressViewScreen().environmentObject(store) }.defaultSize(width: 1080, height: 680)
        Window("SafeSync 휴지통", id: "trash") { TrashView().environmentObject(store) }.defaultSize(width: 950, height: 600)
        Settings { SettingsView().environmentObject(store) }

    }
}
struct MainView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(nsImage: BrandIcon.image).resizable().scaledToFit().frame(width: 48, height: 48)
                VStack(alignment: .leading) { Text("SafeSync").font(.title.bold()); Text("파일을 안전하게, 백업은 자동으로").foregroundStyle(.secondary) }
                Spacer()
                Label(store.runningCount > 0 ? "백업 중" : "자동 검사 대기", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                Button("확인할 메시지 \(store.issues.count)") { openWindow(id: "progress") }
            }.padding(8)
            HStack {
                Button("＋ 새 작업") { store.editing = BackupJob() }
                Button("▶ 지금 백업") { store.runSelected(); openWindow(id: "progress") }.buttonStyle(.borderedProminent).disabled(store.selected == nil || store.selected?.paused == true)
                Button(store.selected?.paused == true ? "▶ 다시 시작" : "Ⅱ 일시정지") { store.togglePause() }.disabled(store.selected == nil)
                Button("▶▶ 모든 작업") { store.runAll(); openWindow(id: "progress") }
                Divider().frame(height: 22)
                Button("동기화 상태") { openWindow(id: "progress") }
                Spacer()
                Menu("작업 관리") {
                    Button("작업 수정") { store.editing = store.selected }
                    Button("전체 검사") { store.runSelected(full: true); openWindow(id: "progress") }
                    Button("휴지통 관리") { store.loadTrash(); openWindow(id: "trash") }
                    Divider(); Button("작업 삭제") { store.removeSelected() }
                }.fixedSize().disabled(store.selected == nil)
                SettingsLink { Image(systemName: "gearshape") }
            }.controlSize(.large)
            Table(store.jobs, selection: $store.selection) {
                TableColumn("작업 이름", value: \.name).width(min: 110, ideal: 150)
                TableColumn("원본 위치") { job in path(job.source) }.width(min: 170, ideal: 260)
                TableColumn("백업 위치") { job in if job.cloudProvider == nil { path(job.destination) } else { Text(job.destination).lineLimit(1).truncationMode(.middle).help(job.destination) } }.width(min: 170, ideal: 260)
                TableColumn("실행 방식", value: \.triggerText).width(min: 100, ideal: 120)
                TableColumn("상태") { job in Text(store.status(job)).foregroundStyle(job.paused ? .secondary : .primary) }.width(min: 90, ideal: 110)
            }.overlay { if store.jobs.isEmpty { ContentUnavailableView("첫 백업 작업을 추가하세요", systemImage: "folder.badge.plus", description: Text("원본과 백업 폴더를 선택하면 자동 백업을 시작합니다.")) } }
            VStack(alignment: .leading, spacing: 8) {
                Text("활동 기록").font(.headline)
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(Array(store.activity.enumerated()), id: \.offset) { _, line in Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } } }
            }.padding(12).frame(height: 145).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack { Text("macOS 개발 버전 0.2 · 로컬 · Dropbox · Google Drive"); Spacer(); Text("작업 \(store.jobs.count)개") }.font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(minWidth: 1000, minHeight: 620)
        .onAppear { store.openAppWindow = { id in openWindow(id: id) } }
        .sheet(item: $store.editing) { JobEditor(job: $0).environmentObject(store) }
        .alert("확인할 메시지", isPresented: Binding(get: { store.error != nil && store.mainVisible }, set: { if !$0 { store.error = nil } })) { Button("확인") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    func path(_ value: String) -> some View { Text(value).lineLimit(1).truncationMode(.middle).help(value).onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: value)) } }
}
struct JobEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ViewState var job: BackupJob
    @ViewState private var error: String?
    @ViewState private var showCloudPicker = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("백업 작업 설정").font(.title.bold())
            Form {
                TextField("작업 이름", text: $job.name)
                HStack { TextField("원본 위치", text: $job.source); Button("찾아보기") { choose(source: true) } }
                Picker("백업 방식", selection: $job.cloudProvider) {
                    Text("로컬 / 네트워크 / 동기화 폴더").tag(CloudProvider?.none)
                    ForEach(CloudProvider.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.onChange(of: job.cloudProvider) { _, _ in job.cloudAccountID = nil; job.cloudFolderID = nil; job.destination = "" }
                if let provider = job.cloudProvider {
                    Picker("클라우드 계정", selection: $job.cloudAccountID) {
                        Text("계정 선택").tag(UUID?.none)
                        ForEach(store.accounts.filter { $0.provider == provider }) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: job.cloudAccountID) { _, _ in job.cloudFolderID = nil; job.destination = "" }
                    HStack { Text(job.destination.isEmpty ? "백업 폴더를 선택하세요" : job.destination).lineLimit(2); Spacer(); Button("클라우드 폴더 선택") { showCloudPicker = true }.disabled(job.cloudAccountID == nil) }
                } else { HStack { TextField("백업 위치", text: $job.destination); Button("위치 선택") { choose(source: false) } } }
                Picker("실행 방식", selection: $job.scheduled) { Text("파일 변경 시").tag(false); Text("매일 정해진 시간").tag(true) }
                if job.scheduled { TextField("예약 시간 (HH:mm)", text: $job.scheduleTime) }
                Toggle("원본에서 사라진 파일은 SafeSync 휴지통으로 이동", isOn: $job.mirrorDeletes)
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("취소") { dismiss() }.keyboardShortcut(.cancelAction); Button("저장") { do { try store.upsert(job); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 640)
        .sheet(isPresented: $showCloudPicker) {
            if let account = store.accounts.first(where: { $0.id == job.cloudAccountID }) {
                CloudFolderPicker(account: account) { id, label in job.cloudFolderID = id; job.destination = "\(account.provider.title) · \(label)" }
            }
        }
    }
    func choose(source: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = !source; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { if source { job.source = url.path } else { job.destination = url.path } }
    }
}
struct ProgressViewScreen: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("백업 비교 및 충돌 처리").font(.title2.bold())
            ForEach(store.jobs.filter { store.progress[$0.id] != nil }) { job in
                if let p = store.progress[job.id] {
                    GroupBox(job.name) {
                        VStack(alignment: .leading) {
                            HStack { Text(job.source); Spacer(); Image(systemName: "arrow.right"); Spacer(); Text(job.destination) }.font(.caption).foregroundStyle(.secondary)
                            HStack { Text(p.path).lineLimit(1).truncationMode(.middle); Spacer(); if let size = p.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption) } }
                            if let stage = p.stage { Text(stage).font(.caption).foregroundStyle(.secondary) }
                            if let bytes = p.transferred, let size = p.size { ProgressView(value: Double(bytes), total: Double(max(1, size))).tint(.green) }
                            ProgressView(value: Double(p.completed), total: Double(max(1, p.total)))
                            HStack { Text(store.status(job)); Spacer(); Text("\(p.completed) / \(p.total)") }.font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
            }
            HStack {
                Text("사용 중 대기 \(store.waitingIssues.count)건").font(.headline)
                Spacer()
                Button("지금 다시 시도") { store.retryWaiting() }
                    .disabled(!store.waitingIssues.contains { store.canRetryWaiting($0.jobID) })
            }
            if !store.waitingIssues.isEmpty {
                Table(store.waitingIssues) {
                    TableColumn("작업") { issue in Text(store.jobs.first { $0.id == issue.jobID }?.name ?? "") }.width(100)
                    TableColumn("파일", value: \.path)
                    TableColumn("최초 대기") { if let w = $0.waiting { Text(w.firstWait.formatted(date: .abbreviated, time: .standard)) } }
                    TableColumn("최근 시도") { if let w = $0.waiting { Text(w.lastAttempt.formatted(date: .omitted, time: .standard)) } }
                    TableColumn("시도 횟수") { Text("\($0.waiting?.attempts ?? 0)") }.width(65)
                    TableColumn("다음 시도") { if let w = $0.waiting { Text(w.nextAttempt.formatted(date: .omitted, time: .standard)) } }
                }.frame(height: 150)
                Text("사용 중인 파일은 30초부터 최대 5분 간격으로 다시 시도합니다. 일시정지한 작업은 재개 후 시도합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Text("충돌 및 오류 \(store.issues.filter { $0.waiting == nil }.count)건").font(.headline)
            List(store.issues.filter { $0.waiting == nil }) { issue in
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.path.isEmpty ? "작업 전체" : issue.path).font(.headline).textSelection(.enabled)
                    Text(issue.reason).foregroundStyle(issue.conflict ? .orange : .red)
                    if let src = issue.source, let dst = issue.backup {
                        HStack { Text("원본: \(src.modified.formatted()) · \(src.size) B"); Spacer(); Text("백업: \(dst.modified.formatted()) · \(dst.size) B") }.font(.caption)
                    }
                    if issue.conflict {
                        HStack {
                            Button("원본으로 덮어쓰기") { store.resolve(issue, action: .overwrite) }
                            Button("기존 백업 이름 변경 후 복사") { store.resolve(issue, action: .keepBoth) }
                            Text("변경 없이 두려면 처리를 선택하지 마세요.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(8)
            }.overlay { if store.issues.filter({ $0.waiting == nil }).isEmpty { Text("확인할 충돌이나 오류가 없습니다.").foregroundStyle(.secondary) } }
        }.padding(20).frame(minWidth: 850, minHeight: 500)
    }
}
struct TrashView: View {
    @EnvironmentObject var store: Store
    @ViewState private var selection: Set<UUID> = []
    var chosen: [TrashItem] { store.trash.filter { selection.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SafeSync 휴지통 · \(store.trashJob?.name ?? "작업을 먼저 선택하세요")").font(.title2.bold())
            HStack {
                Button("새로고침") { if let job = store.trashJob { store.refreshTrash(job) } }
                Button("모두 선택") { selection = Set(store.trash.map(\.id)) }
                Button("선택 파일 복구") { store.restore(chosen) }.disabled(chosen.isEmpty)
                Button("선택 파일 완전 삭제", role: .destructive) { store.deleteTrash(chosen) }.disabled(chosen.isEmpty)
                Spacer(); if store.busyTrash { ProgressView().controlSize(.small) }
            }.disabled(store.busyTrash)
            Table(store.trash, selection: $selection) {
                TableColumn("파일 이름") { Text(URL(fileURLWithPath: $0.path).lastPathComponent) }
                TableColumn("삭제된 날짜와 시간") { Text($0.deletedAt.formatted()) }
                TableColumn("지워지기 전 백업 경로", value: \.path)
                TableColumn("크기") { Text(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file)) }
            }
            Text("복구하면 해당 작업은 일시정지됩니다. 파일을 확인한 뒤 직접 다시 시작하세요.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 800, minHeight: 450)
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("trashRetentionDays") private var retention = 100
    @AppStorage("errorSound") private var errorSound = false
    @AppStorage("windowSound") private var windowSound = false
    @AppStorage("completionSound") private var completionSound = false
    @ViewState private var cloud = false
    @ViewState private var loginEnabled = SMAppService.mainApp.status == .enabled
    @ViewState private var error: String?
    var body: some View {
        Form {
            Picker("화면 모드", selection: $appearance) { Text("시스템 설정").tag("system"); Text("라이트").tag("light"); Text("다크").tag("dark") }
            Toggle("로그인 시 자동 시작", isOn: $loginEnabled).onChange(of: loginEnabled) { _, enabled in
                do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                catch { self.error = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
            }
            if SMAppService.mainApp.status == .requiresApproval {
                Button("시스템 설정에서 자동 시작 승인") { SMAppService.openSystemSettingsLoginItems() }
            }
            Stepper("SafeSync 휴지통 보관기간: \(retention)일", value: $retention, in: 1...3650)
            Toggle("백업 완료 알림음", isOn: $completionSound)
            Toggle("백업 오류 알림음", isOn: $errorSound)
            Toggle("창 최소화·닫기 알림음", isOn: $windowSound)
            Button("클라우드 계정 관리") { cloud = true }
            LabeledContent("버전", value: "0.2.4 · macOS 검증 중")
            LabeledContent("제작자", value: "임호")
            LabeledContent("이메일", value: "limfrog75@gmail.com")
            Text("앱이 실행되고 Mac이 깨어 있을 때 자동 백업합니다. 휴지통 보관기간이 지난 파일은 백업 완료 후 정리됩니다. Dropbox는 서비스의 보존 정책에 따라 웹 복구 기록이 남을 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Button("설정 폴더 열기") { NSWorkspace.shared.open(Storage.applicationDirectory) }
        }.formStyle(.grouped).frame(width: 580, height: 520)
        .sheet(isPresented: $cloud) { CloudAccountsView().environmentObject(store) }
    }
}
