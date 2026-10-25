import SwiftUI
import SafeSyncCore

struct CloudAccountsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var provider = CloudProvider.dropbox
    @ViewState private var name = ""
    @ViewState private var showAccounts = false
    private var registration: DesktopCloudRegistration { .load(provider: provider) }
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var login: OAuthLogin?
    private var providerName: String { provider == .dropbox ? "Dropbox" : "Google Drive" }
    private var accent: Color { provider == .dropbox ? .blue : .indigo }
    private var canConnect: Bool {
        !busy && registration.isAvailable
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 25, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 54, height: 54).background(.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 5) {
                    Text("클라우드 연결").font(.system(size: 23, weight: .bold))
                    Text("내 클라우드를 SafeSync의 백업 공간으로 연결하세요.").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    connectedAccounts
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle("새 계정 연결", subtitle: "사용할 클라우드 서비스를 선택하세요.")
                        Picker("클라우드 서비스", selection: $provider) {
                            Text("Dropbox").tag(CloudProvider.dropbox)
                            Text("Google Drive").tag(CloudProvider.googleDrive)
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
                        connectionForm
                    }
                    if let error { notice(error, symbol: "exclamationmark.circle", color: .red) }
                }.padding(24)
            }
            if store.validatingCloud || store.cloudValidationReport != nil {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    if store.validatingCloud { ProgressView().controlSize(.small) }
                    Image(systemName: store.cloudValidationReport?.hasPrefix("클라우드 검증 실패") == true ? "exclamationmark.triangle.fill" : "checkmark.shield")
                        .foregroundStyle(store.cloudValidationReport?.hasPrefix("클라우드 검증 실패") == true ? Color.red : Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.validatingCloud ? "연결 검증 중" : "연결 검증 결과").font(.callout.weight(.semibold))
                        Text(store.cloudValidationReport ?? store.cloudValidationStage ?? "클라우드 연결을 확인하고 있습니다.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 24).padding(.vertical, 12)
            }
            Divider()
            HStack(spacing: 12) {
                Button("닫기") { login?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text("브라우저에서 로그인 중…").font(.callout).foregroundStyle(.secondary)
                    Button("취소") { login?.cancel() }
                } else {
                    Label("인증 정보는 Mac의 키체인에 보관됩니다", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { connect() } label: {
                    Label("\(providerName) 연결", systemImage: "arrow.up.right")
                        .padding(.horizontal, 6)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canConnect)
            }.padding(.horizontal, 24).padding(.vertical, 18)
        }
        .frame(width: 740, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear { login?.cancel() }
    }
    private var connectedAccounts: some View {
        DisclosureGroup(isExpanded: $showAccounts) {
            if store.accounts.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "cloud").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("첫 번째 클라우드를 연결해 보세요").font(.callout.weight(.medium))
                        Text("연결한 계정은 백업 작업에서 선택할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(18).frame(maxWidth: .infinity).background(cardBackground)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.accounts) { account in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.fill.badge.icloud")
                                .font(.title3).foregroundStyle(account.provider == .dropbox ? Color.blue : Color.indigo)
                                .frame(width: 38, height: 38).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.name).font(.callout.weight(.semibold)).lineLimit(1)
                                Text(account.provider == .dropbox ? "Dropbox" : account.accessMode == GoogleFileAccess.mode ? "Google Drive · 제한 권한" : "Google Drive · 새 계정 연결로 제한 권한 재연결 필요").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("연결 검증") { store.validateCloudAccount(account) }.disabled(store.validatingCloud || busy)
                            Button("연결 해제") { store.disconnect(account) }.disabled(busy || store.validatingCloud)
                        }.padding(14)
                        if account.id != store.accounts.last?.id { Divider().padding(.leading, 64) }
                    }
                }.background(cardBackground).padding(.top, 10)
            }
        } label: {
            HStack(spacing: 8) {
                Text("연결된 계정").font(.headline)
                Text("\(store.accounts.count)").font(.caption.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
                Spacer()
                Text("계정 관리").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)))
    }
    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cloud.fill").font(.title2).foregroundStyle(accent)
                    .frame(width: 42, height: 42).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(providerName).font(.headline)
                    Text("공식 로그인 페이지에서 안전하게 연결합니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                connectionStep("1", title: "계정으로 로그인", detail: "브라우저에서 사용할 계정을 선택합니다.")
                connectionStep("2", title: "SafeSync 연결 허용", detail: "서비스에서 요청하는 접근 권한을 확인합니다.")
                connectionStep("3", title: "백업 폴더 선택", detail: "연결한 계정으로 새 백업 작업을 만들 수 있습니다.")
            }
            Divider()
            inputField("계정 이름 (선택)", hint: "예: 개인 백업 · 비워 두어도 됩니다", text: $name, symbol: "person.crop.circle")
            if !registration.isAvailable {
                notice("Google Drive 연결은 배포 준비 중입니다. 연결을 지원하는 업데이트를 설치해 주세요.", symbol: "info.circle", color: .secondary)
            }
            Label(provider == .googleDrive ? "제한 권한으로 새 전용 폴더에 단방향 백업합니다. 이전 연결은 새로 로그인하고 작업의 폴더를 다시 선택하세요." : "연결 후 백업할 폴더를 직접 선택할 수 있습니다.", systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(cardBackground).disabled(busy)
    }
    private func connectionStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).foregroundStyle(accent)
                .frame(width: 24, height: 24).background(accent.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14)))
    }
    private func inputField(_ title: String, hint: String, text: Binding<String>, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.medium))
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                TextField(hint, text: text).textFieldStyle(.plain).accessibilityLabel(title)
            }.padding(12).background(fieldBackground)
        }
    }
    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.font(.caption).foregroundStyle(color).padding(12)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    func connect() {
        guard canConnect else { return }
        let registration = registration
        busy = true; error = nil
        let enteredName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var accountName = enteredName
        if accountName.isEmpty {
            accountName = providerName
            var suffix = 2
            while store.accounts.contains(where: { $0.name == accountName }) {
                accountName = "\(providerName) \(suffix)"; suffix += 1
            }
        }
        let account = CloudAccount(provider: provider, name: accountName, clientID: registration.clientID)
        let connection = OAuthLogin(); login = connection
        Task { @MainActor in
            do { try await connection.connect(account, clientSecret: registration.clientSecret); try store.addAccount(account); name = ""; showAccounts = true }
            catch is CancellationError { self.error = "연결을 취소했습니다." }
            catch { self.error = error.localizedDescription }
            busy = false; login = nil
        }
    }
}
struct CloudFolderPicker: View {
    @EnvironmentObject var store: Store
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
    @ViewState private var parentLogin: OAuthLogin?
    @ViewState private var pickingParent = false
    private var canSelect: Bool { !loading && !creatingFolder && !pickingParent && error == nil && stack.last.map { account.provider == .dropbox ? !$0.locator.isEmpty : $0.appAccessMode == GoogleFileAccess.mode } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("클라우드 폴더 선택 · \(account.name)").font(.title2.bold())
            if account.provider == .googleDrive { Text("SafeSync 전용 폴더를 선택하거나 새로 만드세요. 다른 위치에 만들려면 ‘상위 위치 선택’을 사용하세요. 다른 앱이 만든 파일은 이 연결에서 보이지 않을 수 있습니다.").font(.caption).foregroundStyle(.secondary) }
            if account.provider == .googleDrive { Button(pickingParent ? "브라우저에서 선택 중…" : "상위 위치 선택…") { pickParent() }.disabled(loading || creatingFolder || pickingParent) }
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
            HStack { Button("취소") { parentLogin?.cancel(); dismiss() }.disabled(creatingFolder); Spacer(); Button("현재 폴더 선택") { if let current = stack.last, canSelect { selected(current.locator, stack.map(\.name).joined(separator: " / ")); dismiss() } }.buttonStyle(.borderedProminent).disabled(!canSelect) }
        }.padding(24).frame(width: 680, height: 500)
        .interactiveDismissDisabled(creatingFolder)
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
        .task {
            do {
                if account.provider == .dropbox { stack = [RemoteItem(id: "", name: "Dropbox", parent: "", folder: true, locator: "")] }
                else { try GoogleFileAccess.validateAccount(account); guard let root = try await Store.storage(account).metadata("root") else { throw BackupError.unsafe("Drive 루트를 열 수 없습니다.") }; stack = [root] }
                load()
            } catch { self.error = error.localizedDescription; loading = false }
        }
        .onDisappear { parentLogin?.cancel() }
    }
    func pickParent() {
        guard store.runningCount == 0 else { error = "진행 중인 백업을 마친 뒤 상위 폴더를 선택하세요."; return }
        pickingParent = true; loading = true; error = nil
        let login = OAuthLogin(); parentLogin = login
        Task { @MainActor in
            defer { pickingParent = false; parentLogin = nil; loading = false }
            do {
                let secret = try CredentialVault.read(account: account.id)
                let ids = try await login.connect(account, clientSecret: secret.clientSecret, pickFolder: true)
                guard let id = ids.first, let folder = try await Store.storage(account).metadata(id), folder.folder else { throw BackupError.unsafe("선택한 상위 폴더에 접근할 수 없습니다.") }
                stack = [folder]; children = []; showNewFolder = true; newFolderName = ""; newFolderError = nil
                // Loading the chosen parent may show only app-authorized children.
                children = try await Store.storage(account).children(folder.locator).filter { $0.folder && !$0.name.hasPrefix(".safesync-") }
            } catch { self.error = error.localizedDescription }
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
