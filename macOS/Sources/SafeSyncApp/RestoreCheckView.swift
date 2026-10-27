import SwiftUI
import SafeSyncCore

struct RestoreCheckView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("백업 복원 검증").font(.title2.bold())
            Text(store.restoreCheckJob?.name ?? "작업을 선택하세요").font(.headline)
            Text("원본 위치에 복원하지 않고 임시 위치에서 내용 일치 여부를 검사합니다. 파일 크기에 따라 시간이 걸릴 수 있습니다.").foregroundStyle(.secondary)
            if store.busyRestoreCheck { ProgressView().controlSize(.small) }
            Text(store.restoreCheckSummary).textSelection(.enabled)
            Table(store.restoreCheckRows) {
                TableColumn("파일",value: \.path)
                TableColumn("결과",value: \.status).width(90)
                TableColumn("상세",value: \.detail)
            }
            HStack {
                Button("검증 시작") { store.startRestoreCheck() }.disabled(store.busyRestoreCheck || store.restoreCheckJob == nil)
                Button("취소") { store.cancelRestoreCheck() }.disabled(!store.busyRestoreCheck)
                Spacer(); Button("닫기") { store.cancelRestoreCheck(); dismiss() }
            }
        }.padding(20).frame(minWidth: 760,minHeight: 430).onDisappear { store.cancelRestoreCheck() }
    }
}
