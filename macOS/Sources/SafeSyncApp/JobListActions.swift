import AppKit
import UniformTypeIdentifiers
import SafeSyncCore

@MainActor extension Store {
    func exportJobList() {
        guard !isImportingJobList else { return }
        let dialog = NSSavePanel()
        dialog.title = "작업 목록 내보내기"
        dialog.allowedContentTypes = [.json]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd"
        dialog.nameFieldStringValue = "SafeSync-jobs-\(formatter.string(from: Date())).safesync-jobs.json"
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        do {
            try checkJobListExportLocation(url)
            try JobListFiles.write(jobs, to: url)
            log("작업 목록 \(jobs.count)개를 내보냈습니다.")
            jobListMessage("내보내기 완료", "작업 목록을 저장했습니다.\n\n\(url.path)\n\n클라우드 인증 정보, 스냅샷, 실제 백업 파일은 포함되지 않습니다.")
        } catch { jobListMessage("내보내기 오류", error.localizedDescription, error: true) }
    }
    func importJobList() {
        guard canImportJobList else {
            jobListMessage("가져오기 대기", "백업이나 확인 작업이 끝난 뒤 작업 목록을 가져오세요.")
            return
        }
        isImportingJobList = true
        defer { isImportingJobList = false }
        let dialog = NSOpenPanel()
        dialog.title = "작업 목록 가져오기"; dialog.allowedContentTypes = [.json]
        dialog.canChooseFiles = true; dialog.canChooseDirectories = false; dialog.allowsMultipleSelection = false
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        do {
            let document = try JobListFiles.read(url)
            let plan = try JobListCodec.plan(document, replacing: jobs)
            let confirmation = NSAlert(); confirmation.messageText = "작업 목록 가져오기"
            confirmation.informativeText = "작업 \(plan.jobs.count)개를 가져와 현재 작업 \(jobs.count)개를 교체할까요?\n\n현재 목록은 교체 전에 자동 보관됩니다. 환경설정과 클라우드 계정은 그대로 유지됩니다. 원본·백업 경로와 클라우드 연결 상태는 가져온 후 확인하세요."
            confirmation.addButton(withTitle: "가져오기"); confirmation.addButton(withTitle: "취소")
            guard confirmation.runModal() == .alertFirstButtonReturn else { return }
            let backupURL = try applyJobList(plan)
            log("작업 목록 \(plan.jobs.count)개를 가져왔습니다. 새 작업 \(plan.newJobCount)개는 새 스냅샷으로 시작합니다.")
            jobListMessage("가져오기 완료", "작업 목록을 가져왔습니다.\n\n기존 목록 보관 위치: \(backupURL.path)\n\n새로 등록된 작업은 처음 실행할 때 파일을 다시 확인합니다. 클라우드 작업은 계정 연결 상태와 백업 폴더를 확인하세요.")
        } catch { jobListMessage("가져오기 오류", error.localizedDescription, error: true) }
    }
    private func checkJobListExportLocation(_ url: URL) throws {
        let target = BackupEngine.canonical(url.path).path
        let data = Storage.applicationDirectory.resolvingSymlinksInPath().path
        let archive = Storage.applicationDirectory.appendingPathComponent("job-list-backups").resolvingSymlinksInPath().path
        if target.hasPrefix(data + "/"), !target.hasPrefix(archive + "/") { throw BackupError.unsafe("앱이 사용하는 설정 파일 위에는 내보낼 수 없습니다. 다른 폴더를 선택하세요.") }
    }
    private func jobListMessage(_ title: String, _ message: String, error: Bool = false) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.alertStyle = error ? .warning : .informational; alert.addButton(withTitle: "확인"); alert.runModal()
    }
}
