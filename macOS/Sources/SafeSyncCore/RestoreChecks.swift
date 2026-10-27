import Foundation

public struct RestoreCheckRow: Identifiable, Sendable {
    public var path: String, length: Int64, status: String, detail: String
    public var id: String { path }
    public init(path: String, length: Int64, status: String, detail: String) { self.path = path; self.length = length; self.status = status; self.detail = detail }
}
enum RestoreVerifier {
    static func local(_ file: URL, path: String, expected: String?) throws -> RestoreCheckRow {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-restore-check-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: folder) }
        let fd = try FileAccess.readLock(file); defer { FileAccess.unlock(fd) }
        let before = try FileStamp(file), identity = try FileComparisons.identity(file), temporary = folder.appendingPathComponent("payload")
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporary)
        do { while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: bytes) }; try output.synchronize(); try output.close() }
        catch { try? output.close(); throw error }
        let digest = try BackupEngine.hash(temporary)
        guard try FileStamp(file) == before, try FileComparisons.identity(file) == identity else { throw BackupError.unsafe("검증 중 백업 파일이 변경되었습니다.") }
        guard let expected, !expected.isEmpty else { return RestoreCheckRow(path: path, length: before.size, status: "기준 없음", detail: "임시 복원은 가능하지만 이전 성공 체크섬이 없습니다.") }
        return RestoreCheckRow(path: path, length: before.size, status: digest == expected ? "정상" : "실패", detail: digest == expected ? "임시 복원한 내용이 성공 백업의 SHA-256과 일치합니다." : "마지막 성공 백업 기록과 내용이 다릅니다. 현재 파일은 보존했습니다.")
    }
    static func cloud(_ item: RemoteItem, path: String, expected: String?, kind: String?, storage: any RemoteStorage) async throws -> RestoreCheckRow {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-restore-check-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("payload"); try await storage.download(item, to: local); try ContentHash.verify(item, file: local)
        guard let fresh = try await storage.metadata(item.id), fresh == item else { throw BackupError.unsafe("검증 중 백업 파일이 변경되었습니다.") }
        guard let expected, let kind else { return RestoreCheckRow(path: path, length: item.size, status: "기준 없음", detail: "임시 복원은 가능하지만 이전 성공 체크섬이 없습니다.") }
        let digest = try ContentHash.compute(local, kind: kind)
        return RestoreCheckRow(path: path, length: item.size, status: digest == expected ? "정상" : "실패", detail: digest == expected ? "임시 복원 내용이 성공 백업 체크섬과 일치합니다." : "마지막 성공 백업과 내용이 다릅니다.")
    }
}
