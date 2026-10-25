import Foundation
import SafeSyncCore

/// Creates an isolated folder for the diagnostic and removes that whole folder
/// after success, failure, or cancellation. Existing user files are never used.
enum CloudDiagnostics {
    static func run(account: CloudAccount, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let storage = await Store.storage(account)
        progress("계정과 클라우드 루트를 확인하는 중…")
        // Google Drive accepts the stable `root` alias directly. Looking it up
        // first added a redundant request and was the most common place for the
        // validation UI to appear stuck.
        let root = account.provider == .googleDrive ? "root" : ""
        let token = UUID(), folderName = "SafeSync-test-" + token.uuidString
        progress("전용 시험 폴더를 만드는 중…")
        let remoteFolder = try await storage.createFolder(name: folderName, parent: root)
        // SourceScanner intentionally excludes Storage.applicationDirectory so
        // SafeSync can never back up its own state. Diagnostics therefore need
        // an isolated source outside that protected tree.
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-connection-diagnostic-\(token.uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        func cleanupRemote() async throws {
            progress("검증용 클라우드 파일과 폴더를 정리하는 중…")
            var last: Error?
            for attempt in 0..<3 {
                do {
                    // Detached cleanup is not born cancelled when the user
                    // closes the window during validation.
                    try await Task.detached(priority: .utility) { try await storage.remove(remoteFolder) }.value
                    return
                } catch {
                    last = error
                    if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 500_000_000) }
                }
            }
            throw BackupError.unsafe("검증용 클라우드 폴더 자동 정리에 실패했습니다: \(last?.localizedDescription ?? "알 수 없는 오류")")
        }
        do {
        let source = local.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("한글 폴더"), withIntermediateDirectories: true)
        var job = BackupJob(); job.name = "클라우드 연결 검증"; job.source = source.path; job.destination = folderName; job.cloudProvider = account.provider; job.cloudAccountID = account.id; job.cloudFolderID = remoteFolder.locator
        job.cloudAccessMode = account.provider == .googleDrive ? GoogleFileAccess.mode : nil
        let engine = CloudBackupEngine(dataDirectory: local.appendingPathComponent("state"))
        let file = source.appendingPathComponent("한글 폴더/검증.txt")
        func write(_ content: String, ago: TimeInterval) throws {
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ago)], ofItemAtPath: file.path)
        }
        try write("SafeSync diagnostic original \(token)", ago: 120)
        let forward: @Sendable (BackupProgress) -> Void = { value in
            progress(value.stage ?? (value.path.isEmpty ? "파일을 확인하는 중…" : value.path))
        }
        progress("최초 전송과 체크섬을 검증하는 중…")
        let first = try await engine.run(job, storage: storage, progress: forward)
        guard first.copied == 1, first.issues.isEmpty else { throw BackupError.unsafe("최초 전송/검증 실패: " + (first.issues.first?.reason ?? "복사 \(first.copied), 동일 \(first.skipped), 휴지통 \(first.removed)")) }
        progress("변경 없는 파일 건너뛰기를 확인하는 중…")
        let unchanged = try await engine.run(job, storage: storage, progress: forward)
        guard unchanged.skipped == 1, unchanged.issues.isEmpty else { throw BackupError.unsafe("변경 없는 파일 건너뛰기 검증에 실패했습니다.") }
        try write("SafeSync diagnostic replacement \(token)", ago: 60)
        progress("안전한 파일 교체를 확인하는 중…")
        let updated = try await engine.run(job, storage: storage, progress: forward)
        guard updated.copied == 1, updated.issues.isEmpty else { throw BackupError.unsafe("안전한 교체 검증 실패: " + (updated.issues.first?.reason ?? "복사 \(updated.copied), 동일 \(updated.skipped), 휴지통 \(updated.removed)")) }
        try FileManager.default.removeItem(at: file)
        progress("휴지통 이동을 확인하는 중…")
        let removed = try await engine.run(job, storage: storage, progress: forward)
        guard removed.removed == 1, removed.issues.isEmpty else { throw BackupError.unsafe("휴지통 이동 검증에 실패했습니다.") }
        let trash = try await engine.listTrash(job, storage: storage)
        guard let item = trash.first else { throw BackupError.unsafe("휴지통 목록이 비어 있습니다.") }
        progress("휴지통 파일 복구를 확인하는 중…")
        try await engine.restore([item], job: job, storage: storage)
        try Storage.save(["provider": account.provider.rawValue, "status": "passed", "folder": folderName, "date": HTTP.dateString(Date())], to: local.appendingPathComponent("result.json"))
        try await cleanupRemote()
        return "\(account.provider.title) 실제 검증 통과: 전송·체크섬·증분·교체·휴지통·복구. 검증용 클라우드 폴더와 파일을 모두 정리했습니다."
        } catch let validationError {
            do { try await cleanupRemote() }
            catch let cleanupError { throw BackupError.unsafe("\(validationError.localizedDescription) 또한 \(cleanupError.localizedDescription)") }
            throw validationError
        }
    }
}
