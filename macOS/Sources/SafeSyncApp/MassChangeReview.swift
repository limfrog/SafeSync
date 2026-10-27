import SwiftUI
import SafeSyncCore

struct MassChangeReview: View {
    @EnvironmentObject var store: Store
    var proposal: MassChangeProposal
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("대량 변경을 보류했습니다").font(.title.bold())
            Text("기존 \(proposal.baseline)개 · 변경/삭제 \(proposal.changes.count)건").foregroundStyle(.secondary)
            Text("목록을 확인하고 이번 변경만 허용할 수 있습니다. 다음 실행 전에 목록이나 위치가 바뀌면 다시 보류하며, 기존 사본은 휴지통에 보관합니다.").fixedSize(horizontal: false, vertical: true)
            Table(proposal.changes) {
                TableColumn("파일 경로") { Text($0.path).lineLimit(1).help($0.path) }.width(min: 300)
                TableColumn("위치") { Text($0.side) }.width(70)
                TableColumn("변경") { Text($0.action) }.width(70)
            }
            HStack { Spacer(); Button("보류 유지") { store.massProposal = nil }; Button("확인한 변경 1회 허용") { store.approveMassChanges(proposal) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 860, height: 580)
    }
}
extension Store {
    func reviewMassChanges() {
        guard let job = selected, !isRunning(job.id) else { return }
        do { massProposal = try MassChanges.pending(directory: Storage.applicationDirectory, job: job); if massProposal == nil { error = "이 작업에 보류된 대량 변경이 없습니다." } }
        catch { self.error = error.localizedDescription }
    }
    func approveMassChanges(_ proposal: MassChangeProposal) {
        guard let job = jobs.first(where: { $0.id == proposal.jobID }), !isRunning(job.id) else { return }
        do { try MassChanges.approve(directory: Storage.applicationDirectory, job: job, fingerprint: proposal.fingerprint); massProposal = nil; log("검토한 대량 변경을 다음 실행에서 1회 허용했습니다. 지금 실행을 눌러 진행하세요.") }
        catch { self.error = error.localizedDescription }
    }

}
