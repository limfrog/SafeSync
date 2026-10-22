import SwiftUI
import SafeSyncCore

struct MessageRow: Identifiable {
    let id: String
    let jobName: String
    let path: String
    let kind: String
    let message: String
    let issue: BackupIssue?
}

@MainActor extension Store {
    var messageRows: [MessageRow] {
        var rows = issues.filter { !$0.automaticNetworkRetry }.map { issue in
            MessageRow(id: issue.id.uuidString,
                       jobName: jobs.first(where: { $0.id == issue.jobID })?.name ?? "이전 작업",
                       path: issue.path.isEmpty ? "작업 전체" : issue.path,
                       kind: issue.conflict ? "충돌" : issue.waiting != nil ? "사용 중" : "오류",
                       message: issue.reason, issue: issue)
        }
        if let error, !error.isEmpty, !issues.contains(where: { $0.reason == error }) {
            rows.insert(MessageRow(id: "application", jobName: "SafeSync", path: "프로그램", kind: "안내", message: error, issue: nil), at: 0)
        }
        return rows
    }
    func showMessageDetails(_ issue: BackupIssue) {
        selection = jobs.first(where: { $0.id == issue.jobID })?.id
        let session = sessions.first { $0.job.id == issue.jobID }
        sessionSelection = session?.id
        followLatest = session?.id == sessions.first?.id
        workspace = .sync
        detailTab = issue.conflict ? .conflicts : issue.waiting != nil ? .waiting : .errors
    }
}

struct MessagesView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @ViewState private var selection: String?
    private var rows: [MessageRow] { store.messageRows }
    private var selected: MessageRow? { rows.first { $0.id == selection } }
    private var selectedIssue: BackupIssue? {
        guard let issue = selected?.issue, store.jobs.contains(where: { $0.id == issue.jobID }) else { return nil }
        return issue
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("확인할 메시지").font(.title2.bold())
                    Text("확인할 메시지 \(rows.count)개").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Table(rows, selection: $selection) {
                TableColumn("유형", value: \.kind).width(65)
                TableColumn("작업", value: \.jobName).width(min: 100, ideal: 145)
                TableColumn("파일", value: \.path).width(min: 130, ideal: 220)
                TableColumn("메시지", value: \.message)
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView("확인할 메시지가 없습니다", systemImage: "checkmark.bubble", description: Text("백업 중 확인이 필요한 내용이 생기면 여기에 표시됩니다."))
                }
            }
            if let selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(selected.path).font(.callout.weight(.semibold))
                        Text(selected.message).font(.callout)
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 95).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            HStack {
                Text("메시지를 열거나 닫아도 오류·충돌 상태와 백업 파일은 유지됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("선택 작업 문제 확인") {
                    guard let issue = selectedIssue else { return }
                    AppPresentation.showInDock()
                    store.showMessageDetails(issue)
                    openWindow(id: "main")
                }.disabled(selectedIssue == nil)
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(minWidth: 780, minHeight: 470)
        .onAppear { if selection == nil { selection = rows.first?.id } }
        .onChange(of: rows.map(\.id)) { _, ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
    }
}
