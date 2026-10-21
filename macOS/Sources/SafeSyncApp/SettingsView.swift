import SwiftUI
import AppKit
import ServiceManagement
import SafeSyncCore

enum AppInformation {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 빌드" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
}

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SafeSync") { openWindow(id: "about") }
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: BrandIcon.image).resizable().scaledToFit().frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("SafeSync").font(.system(size: 28, weight: .bold))
            Text("버전 \(AppInformation.version) (\(AppInformation.build)) · macOS").foregroundStyle(.secondary)
            Text("파일을 안전하게, 백업은 자동으로").font(.callout)
            Divider().padding(.vertical, 6)
            LabeledContent("개발자", value: "Horizon Entertainment")
            LabeledContent("이메일") { Link("apps@horizonent.co.kr", destination: URL(string: "mailto:apps@horizonent.co.kr")!) }
            Link("GitHub · 소스 및 업데이트", destination: URL(string: "https://github.com/limfrog/SafeSync")!)
                .padding(.top, 8)
        }.padding(30).frame(width: 390)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @ViewState private var appearance = "system"
    @ViewState private var retention = "100"
    @ViewState private var errorSound = false
    @ViewState private var windowSound = false
    @ViewState private var completionSound = false
    @ViewState private var loginEnabled = false
    @ViewState private var cloud = false
    @ViewState private var error: String?
    @ViewState private var autoUpdates = true
    @ViewState private var autoDownloads = true
    @ObservedObject private var updates = ApplicationUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("환경설정").font(.system(size: 24, weight: .bold))
                Text("자동 실행, 파일 보호 정책 및 화면 모드를 관리합니다.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Mac 로그인 시 SafeSync 자동 시작", isOn: $loginEnabled)
                            if SMAppService.mainApp.status == .requiresApproval {
                                Button("시스템 설정에서 자동 시작 승인") { SMAppService.openSystemSettingsLoginItems() }
                            }
                            HStack(spacing: 10) {
                                Text("휴지통 보관 기간").frame(width: 128, alignment: .leading)
                                TextField("보관 기간", text: $retention).textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing).frame(width: 72)
                                    .accessibilityLabel("휴지통 보관 기간")
                                Text("일 (1~3650일)").foregroundStyle(.secondary)
                            }
                            Text("교체되거나 삭제된 백업 파일을 지정한 기간 동안 SafeSync 휴지통에 보관합니다.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Divider().padding(.vertical, 2)
                            Toggle("창을 최소화하거나 메뉴 막대로 보낼 때 알림음 재생", isOn: $windowSound)
                            Toggle("백업이 정상적으로 완료됐을 때 알림음 재생", isOn: $completionSound)
                            Toggle("백업 오류가 발생했을 때 알림음 재생", isOn: $errorSound)
                            Button("클라우드 계정 연결 관리") { cloud = true }.padding(.top, 4)
                        }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } label: { Text("보호 설정").font(.headline) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("현재 버전: \(AppInformation.version)")
                            Toggle("앱 실행 시와 매시간 새 버전 자동 확인", isOn: $autoUpdates)
                            Toggle("새 버전을 찾으면 설치 파일 자동 다운로드", isOn: $autoDownloads)
                            Text(updates.status).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("업데이트 확인") { updates.check(manual: true) }
                                Button("다운로드 / 업데이트") { updates.show() }
                            }
                        }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } label: { Text("업데이트").font(.headline) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 16) {
                                Text("모양").foregroundStyle(.secondary)
                                Picker("화면 모드", selection: $appearance) {
                                    Text("라이트 모드").tag("light")
                                    Text("다크 모드").tag("dark")
                                    Text("시스템 설정").tag("system")
                                }.labelsHidden().pickerStyle(.radioGroup).horizontalRadioGroupLayout()
                            }
                            Text("설정 저장을 누르면 모든 SafeSync 창에 적용됩니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    } label: { Text("화면 모드").font(.headline) }
                }.padding(.trailing, 4)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("설정 폴더 열기") { NSWorkspace.shared.open(Storage.applicationDirectory) }
                Spacer()
                Button("닫기") { close() }.keyboardShortcut(.cancelAction)
                Button("설정 저장") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }.controlSize(.large)
        }.padding(24).frame(width: 620, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { load() }
        .onDisappear { load() }
        .sheet(isPresented: $cloud) { CloudAccountsView().environmentObject(store) }
    }
    private var registered: Bool {
        SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
    private func load() {
        let defaults = UserDefaults.standard
        appearance = defaults.string(forKey: "appearance") ?? "system"
        retention = String(defaults.object(forKey: "trashRetentionDays") as? Int ?? 100)
        errorSound = defaults.bool(forKey: "errorSound")
        windowSound = defaults.bool(forKey: "windowSound")
        completionSound = defaults.bool(forKey: "completionSound")
        loginEnabled = registered; error = nil
        autoUpdates = defaults.object(forKey: "automaticallyCheckUpdates") as? Bool ?? true
        autoDownloads = defaults.object(forKey: "automaticallyDownloadUpdates") as? Bool ?? true
    }
    private func close() { load(); NSApp.keyWindow?.close() }
    private func save() {
        guard let days = Int(retention.trimmingCharacters(in: .whitespacesAndNewlines)), (1...3650).contains(days) else {
            error = "보관 기간은 1~3650일 사이의 숫자로 입력하세요."; return
        }
        do {
            if loginEnabled != registered {
                if loginEnabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            }
            let defaults = UserDefaults.standard
            defaults.set(days, forKey: "trashRetentionDays")
            defaults.set(windowSound, forKey: "windowSound")
            defaults.set(completionSound, forKey: "completionSound")
            defaults.set(errorSound, forKey: "errorSound")
            defaults.set(appearance, forKey: "appearance")
            defaults.set(autoUpdates, forKey: "automaticallyCheckUpdates")
            defaults.set(autoDownloads, forKey: "automaticallyDownloadUpdates")
            updates.preferencesChanged()
            store.log("환경설정을 저장했습니다.")
            close()
        } catch { self.error = "환경설정 저장 오류: \(error.localizedDescription)" }
    }
}
