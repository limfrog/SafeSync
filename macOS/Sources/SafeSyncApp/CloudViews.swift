import SwiftUI
import SafeSyncCore

struct CloudAccountsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var provider = CloudProvider.dropbox
    @ViewState private var name = ""
    @ViewState private var googleClientID = ""
    @ViewState private var dropboxKey = ""
    @ViewState private var developerSettings = false
    private let publicDropboxKey = "08al8ot9uye36k9"
    var clientID: String { provider == .dropbox ? (dropboxKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? publicDropboxKey : dropboxKey) : googleClientID }
    @ViewState private var clientSecret = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var login: OAuthLogin?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("클라우드 계정").font(.title2.bold())
            List(store.accounts) { account in
                HStack { VStack(alignment: .leading) { Text(account.name).font(.headline); Text(account.provider.title).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("연결 검증") { store.validateCloudAccount(account) }.disabled(store.validatingCloud || busy); Button("연결 해제") { store.disconnect(account) }.disabled(busy) }
            }.frame(height: 150)
            TabView(selection: $provider) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Dropbox 공식 로그인 페이지에서 본인 계정으로 로그인하고 SafeSync 연결을 허용하세요.").foregroundStyle(.secondary)
                    TextField("계정 표시 이름", text: $name)
                    DisclosureGroup("개발자 설정 · 일반 사용자는 변경할 필요가 없습니다", isExpanded: $developerSettings) {
                        TextField("Dropbox App key (기본 SafeSync 앱)", text: $dropboxKey).padding(.top, 8)
                        Text("개인 앱을 사용한다면 Full Dropbox 권한과 http://127.0.0.1:53682/ 리디렉션을 등록하세요.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }.padding(16).tabItem { Text("Dropbox") }.tag(CloudProvider.dropbox)
                VStack(alignment: .leading, spacing: 12) {
                    TextField("계정 표시 이름", text: $name)
                    TextField("Google Client ID", text: $googleClientID)
                    SecureField("Google Client Secret", text: $clientSecret)
                    Text("Google Drive API를 활성화한 ‘데스크톱 앱’ OAuth 클라이언트를 사용하세요. 백업 폴더 접근 동의를 요청합니다.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(16).tabItem { Text("Google Drive") }.tag(CloudProvider.googleDrive)
            }.frame(height: 235).disabled(busy)
            if let report = store.cloudValidationReport { Text(report).font(.caption).textSelection(.enabled) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("닫기") { login?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if busy { ProgressView().controlSize(.small); Text("브라우저에서 로그인을 완료하세요."); Button("취소") { login?.cancel() } }
                Spacer()
                Button("브라우저에서 계정 연결") { connect() }.buttonStyle(.borderedProminent).disabled(busy || clientID.trimmingCharacters(in: .whitespaces).isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 680, height: 640).onDisappear { login?.cancel() }
    }
    func connect() {
        busy = true; error = nil
        let account = CloudAccount(provider: provider, name: name.trimmingCharacters(in: .whitespaces), clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines))
        let connection = OAuthLogin(); login = connection
        Task { @MainActor in
            do { try await connection.connect(account, clientSecret: clientSecret); try store.addAccount(account); name = ""; googleClientID = ""; dropboxKey = ""; clientSecret = "" }
            catch is CancellationError { self.error = "연결을 취소했습니다." }
            catch { self.error = error.localizedDescription }
            busy = false; login = nil
        }
    }
}
struct CloudFolderPicker: View {
    let account: CloudAccount
    var selected: (String, String) -> Void
    @Environment(\.dismiss) var dismiss
    @ViewState private var stack: [RemoteItem] = []
    @ViewState private var children: [RemoteItem] = []
    @ViewState private var loading = true
    @ViewState private var showNewFolder = false
    @ViewState private var newFolderName = ""
    @ViewState private var creatingFolder = false
    @ViewState private var newFolderError: String?
    @FocusState private var folderNameFocused: Bool
    @ViewState private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("클라우드 폴더 선택 · \(account.name)").font(.title2.bold())
            HStack {
                Button("상위 폴더") { if stack.count > 1 { stack.removeLast(); load() } }.disabled(stack.count < 2 || loading || creatingFolder)
                Text(stack.map(\.name).joined(separator: " / ")).lineLimit(2)
                Spacer()
                Button { newFolderName = ""; newFolderError = nil; showNewFolder = true } label: { Label("새 폴더", systemImage: "folder.badge.plus") }
                    .disabled(loading || creatingFolder || stack.isEmpty || error != nil)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("새로고침").accessibilityLabel("새로고침")
                    .disabled(loading || creatingFolder || stack.isEmpty)
                if loading { ProgressView().controlSize(.small) }
            }
            List(children) { item in Button { stack.append(item); load() } label: { Label(item.name, systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).disabled(loading || creatingFolder) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Button("취소") { dismiss() }.disabled(creatingFolder); Spacer(); Button("현재 폴더 선택") { if let current = stack.last { selected(current.locator, stack.map(\.name).joined(separator: " / ")); dismiss() } }.buttonStyle(.borderedProminent).disabled(loading || creatingFolder || stack.isEmpty || error != nil) }
        }.padding(24).frame(width: 680, height: 500)
        .interactiveDismissDisabled(creatingFolder)
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
        .task {
            do {
                if account.provider == .dropbox { stack = [RemoteItem(id: "", name: "Dropbox", parent: "", folder: true, locator: "")] }
                else { guard let root = try await Store.storage(account).metadata("root") else { throw BackupError.unsafe("Drive 루트를 열 수 없습니다.") }; stack = [root] }
                load()
            } catch { self.error = error.localizedDescription; loading = false }
        }
    }
    var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("새 폴더").font(.title2.bold())
            Text("생성 위치: " + stack.map(\.name).joined(separator: " / "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            TextField("폴더 이름", text: $newFolderName).focused($folderNameFocused).disabled(creatingFolder)
                .onChange(of: newFolderName) { _, _ in newFolderError = nil }
                .onSubmit { if canCreateFolder { createFolder() } }
            if !newFolderName.isEmpty, let validationError = folderNameError { Text(validationError).font(.caption).foregroundStyle(.red) }
            if let newFolderError { Text(newFolderError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("취소") { showNewFolder = false }.keyboardShortcut(.cancelAction).disabled(creatingFolder)
                Spacer()
                if creatingFolder { ProgressView().controlSize(.small); Text("만드는 중…").font(.caption) }
                Button("만들기") { createFolder() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canCreateFolder)
            }
        }.padding(24).frame(width: 460)
        .interactiveDismissDisabled(creatingFolder)
        .onAppear { folderNameFocused = true }
    }
    var folderNameError: String? {
        do { _ = try CloudFolderCreation.validatedName(newFolderName); return nil }
        catch { return error.localizedDescription }
    }
    var canCreateFolder: Bool { !creatingFolder && folderNameError == nil }
    func createFolder() {
        guard canCreateFolder, let parent = stack.last else { return }
        creatingFolder = true; newFolderError = nil
        let proposed = newFolderName
        Task { @MainActor in
            do {
                let created = try await CloudFolderCreation.create(name: proposed, parent: parent.locator, storage: Store.storage(account))
                creatingFolder = false; showNewFolder = false
                stack.append(created); load()
            } catch {
                newFolderError = error.localizedDescription
                if error is URLError { newFolderError! += "\n취소 후 목록을 새로고침해 생성 여부를 확인하세요." }
                creatingFolder = false
            }
        }
    }
    func load() {
        guard let current = stack.last else { return }; loading = true; error = nil; children = []
        Task { do { children = try await Store.storage(account).children(current.locator).filter { $0.folder && !$0.name.hasPrefix(".safesync-") }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } } catch { self.error = error.localizedDescription }; loading = false }
    }
}
