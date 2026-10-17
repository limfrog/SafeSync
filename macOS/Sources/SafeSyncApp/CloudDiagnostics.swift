import Foundation
import SafeSyncCore

/// Only creates files below a new, uniquely named diagnostic folder. Never purges remote data.
enum CloudDiagnostics {
    static func run(account: CloudAccount) async throws -> String {
        let storage = await Store.storage(account)
        let root: String
        if account.provider == .googleDrive {
            guard let folder = try await storage.metadata("root") else { throw BackupError.unsafe("Google Drive 루트를 열 수 없습니다.") }; root = folder.id
        } else { root = "" }
        let token = UUID(), folderName = "SafeSync-test-" + token.uuidString
        let remoteFolder = try await storage.createFolder(name: folderName, parent: root)
        let local = Storage.applicationDirectory.appendingPathComponent("diagnostics/\(token)")
        let source = local.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("한글 폴더"), withIntermediateDirectories: true)
        var job = BackupJob(); job.name = "클라우드 연결 검증"; job.source = source.path; job.destination = folderName; job.cloudProvider = account.provider; job.cloudAccountID = account.id; job.cloudFolderID = remoteFolder.locator
        let engine = CloudBackupEngine(dataDirectory: local.appendingPathComponent("state"))
        let file = source.appendingPathComponent("한글 폴더/검증.txt")
        func write(_ content: String, ago: TimeInterval) throws {
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: file.path)
        }
        try write("SafeSync diagnostic original \(token)", ago: 120)
        let first = try await engine.run(job, storage: storage)
        guard first.copied == 1, first.issues.isEmpty else { throw BackupError.unsafe("최초 전송/검증 실패: " + (first.issues.first?.reason ?? "완료 수 불일치")) }
        let unchanged = try await engine.run(job, storage: storage)
        guard unchanged.skipped == 1, unchanged.issues.isEmpty else { throw BackupError.unsafe("변경 없는 파일 건너뛰기 검증에 실패했습니다.") }
        try write("SafeSync diagnostic replacement \(token)", ago: 60)
        let updated = try await engine.run(job, storage: storage)
        guard updated.copied == 1, updated.issues.isEmpty else { throw BackupError.unsafe("안전한 교체 검증 실패: " + (updated.issues.first?.reason ?? "완료 수 불일치")) }
        try write("SafeSync older source conflict \(token)", ago: 180)
        let conflict = try await engine.run(job, storage: storage)
        guard let issue = conflict.issues.first, issue.conflict else { throw BackupError.unsafe("최신 백업 보호/충돌 감지 검증에 실패했습니다.") }
        try await engine.resolve(issue, job: job, storage: storage, action: .keepBoth)
        try FileManager.default.removeItem(at: file)
        let removed = try await engine.run(job, storage: storage)
        guard removed.removed == 1, removed.issues.isEmpty else { throw BackupError.unsafe("휴지통 이동 검증에 실패했습니다.") }
        let trash = try await engine.listTrash(job, storage: storage)
        guard let item = trash.first else { throw BackupError.unsafe("휴지통 목록이 비어 있습니다.") }
        try await engine.restore([item], job: job, storage: storage)
        try Storage.save(["provider": account.provider.rawValue, "status": "passed", "folder": folderName, "date": HTTP.dateString(Date())], to: local.appendingPathComponent("result.json"))
        return "\(account.provider.title) 실제 검증 통과: 전송·체크섬·증분·교체·충돌·휴지통·복구. 클라우드의 ‘\(folderName)’ 폴더에 검증 파일을 남겼습니다."
    }
}
