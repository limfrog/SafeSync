import Foundation
import CryptoKit
import Darwin

/// Filesystem engine. Every replacement is staged, hashed and exchanged on the target volume.
public actor BackupEngine {
    private let fm = FileManager.default
    private let dataDirectory: URL
    private struct Transaction: Codable {
        var destination: String
        var temporary: String
        var expectedHash: String
        var trash: TrashItem
    }
    public init(dataDirectory: URL = Storage.applicationDirectory) { self.dataDirectory = dataDirectory }
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
    public static func overlaps(_ a: URL, _ b: URL) -> Bool {
        let x = a.path.lowercased(), y = b.path.lowercased()
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/") || x == "/" || y == "/"
    }
    public static func validate(_ job: BackupJob) throws {
        let fm = FileManager.default
        let source = canonical(job.source), target = canonical(job.destination)
        guard !job.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw BackupError.unsafe("작업 이름을 입력하세요.") }
        guard job.cloudProvider != nil || !overlaps(source, target) else { throw BackupError.unsafe("원본과 백업 위치는 같거나 서로의 하위 폴더일 수 없습니다.") }
        for root in (job.cloudProvider == nil ? [source, target] : [source]) {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw BackupError.unsafe("폴더에 접근할 수 없습니다: \(root.path)") }
        }
        if job.cloudProvider != nil {
            guard job.cloudAccountID != nil, job.cloudFolderID != nil else { throw BackupError.unsafe("클라우드 계정과 폴더를 선택하세요.") }
        }
        if job.scheduled {
            guard job.scheduleTime.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { throw BackupError.unsafe("예약 시간은 HH:mm 형식으로 입력하세요.") }
        }
    }
    private func child(_ root: URL, _ relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw BackupError.unsafe("안전하지 않은 상대 경로입니다.") }
        let candidate = root.appendingPathComponent(relative)
        var cursor = root
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw BackupError.unsafe("심볼릭 링크 경로는 처리하지 않습니다: \(relative)") }
        }
        guard candidate.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw BackupError.unsafe("백업 경로 밖으로 나갈 수 없습니다.") }
        return candidate
    }
    private func scan(_ root: URL) throws -> [String: FileStamp] { try SourceScanner.files(root) }
    private func manifestURL(_ job: BackupJob) -> URL { dataDirectory.appendingPathComponent("manifests/\(job.id).json") }
    private func loadManifest(_ job: BackupJob) throws -> Manifest {
        let path = manifestURL(job)
        return fm.fileExists(atPath: path.path) ? try Storage.load(Manifest.self, from: path) : Manifest()
    }
    private func lock(_ root: URL) throws -> Int32 {
        let url = try child(root, ".safesync-lock")
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BackupError.unsafe("백업 위치 잠금 파일을 열 수 없습니다.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw BackupError.unsafe("다른 백업 작업이 이 위치를 사용 중입니다.") }
        return fd
    }
    private func trashDirectory(_ root: URL) throws -> URL {
        let dir = try child(root, ".safesync-trash")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func archive(_ file: URL, path: String, root: URL) throws {
        let item = TrashItem(id: UUID(), path: path, deletedAt: Date(), size: try FileStamp(file).size)
        let dir = try trashDirectory(root)
        try Storage.save(item, to: dir.appendingPathComponent("\(item.id).json"))
        do { try fm.moveItem(at: file, to: dir.appendingPathComponent("\(item.id).data")) }
        catch { try? fm.removeItem(at: dir.appendingPathComponent("\(item.id).json")); throw error }
    }
    private func recover(_ root: URL) throws {
        let staging = try child(root, ".safesync-staging")
        guard fm.fileExists(atPath: staging.path) else { return }
        for journal in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) where journal.pathExtension == "json" {
            let tx = try Storage.load(Transaction.self, from: journal)
            let destination = try child(root, tx.destination), temporary = try child(root, tx.temporary)
            let trash = try trashDirectory(root)
            let old = trash.appendingPathComponent("\(tx.trash.id).data")
            // If the destination is the verified new file, exchange completed; preserve the old version.
            if fm.fileExists(atPath: destination.path), try Self.hash(destination) == tx.expectedHash {
                if fm.fileExists(atPath: temporary.path) {
                    try Storage.save(tx.trash, to: trash.appendingPathComponent("\(tx.trash.id).json"))
                    try fm.moveItem(at: temporary, to: old)
                }
            } else {
                // Before exchange, the old destination is intact. Discard only the known staged new file.
                if fm.fileExists(atPath: temporary.path) {
                    guard try Self.hash(temporary) == tx.expectedHash else { throw BackupError.unsafe("복구 기록과 파일이 일치하지 않습니다. 파일을 보존합니다: \(tx.destination)") }
                    try fm.removeItem(at: temporary)
                }
            }
            try fm.removeItem(at: journal)
        }
    }
    private func transfer(_ source: URL, to destination: URL, path: String, root: URL, expected: FileStamp) throws -> String {
        let sourceLock = try FileAccess.readLock(source); defer { FileAccess.unlock(sourceLock) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try child(root, path)
        let staging = try child(root, ".safesync-staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let token = UUID()
        let relative = ".safesync-staging/\(token).data", temp = try child(root, relative)
        let journal = staging.appendingPathComponent("\(token).json")
        var journalWritten = false
        defer { if !journalWritten { try? fm.removeItem(at: temp) } }
        let before = try FileStamp(source)
        guard before == expected else { throw BackupError.fileBusy("복사 전 원본이 변경되어 사용 중 대기합니다.") }
        try fm.copyItem(at: source, to: temp)
        let handle = try FileHandle(forWritingTo: temp); try handle.synchronize(); try handle.close()
        let digest = try Self.hash(source)
        guard try FileStamp(source) == before else { throw BackupError.fileBusy("복사 중 원본이 변경되어 사용 중 대기합니다. 기존 백업을 보존합니다.") }
        guard try Self.hash(temp) == digest else { throw BackupError.unsafe("복사 사본의 체크섬이 일치하지 않습니다. 기존 백업을 보존합니다.") }
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            let tx = Transaction(destination: path, temporary: relative, expectedHash: digest, trash: TrashItem(id: UUID(), path: path, deletedAt: Date(), size: try FileStamp(destination).size))
            try Storage.save(tx, to: journal); journalWritten = true
            guard renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw BackupError.unsafe("이 저장장치는 안전한 원자적 교체를 지원하지 않거나 파일에 접근할 수 없습니다 (\(errno)). 기존 백업을 보존합니다.") }
            try recover(root)
        } else {
            // Exclusive rename refuses to overwrite a concurrently created file.
            guard renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw BackupError.unsafe("새 백업을 배치하지 못했습니다 (\(errno)).") }
        }
        guard try Self.hash(destination) == digest else { throw BackupError.unsafe("교체 후 검증에 실패했습니다.") }
        return digest
    }
    public func run(_ job: BackupJob, fullScan: Bool = false, changedPaths: Set<String>? = nil, deferredPaths: Set<String> = [], progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> BackupResult {
        try Self.validate(job)
        let root = Self.canonical(job.destination), source = Self.canonical(job.source)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try recover(root)
        var manifest = try loadManifest(job), result = BackupResult()
        if let oldSource = manifest.sourceRoot, let oldDestination = manifest.destinationRoot {
            guard oldSource == source.path, oldDestination == root.path else { throw BackupError.unsafe("작업 경로가 이전 백업 기록과 다릅니다. 새 작업으로 등록하세요.") }
        }
        manifest.sourceRoot = source.path; manifest.destinationRoot = root.path
        let files: [String: FileStamp]
        if let changedPaths, !fullScan, !manifest.files.isEmpty { files = try SourceScanner.reconcile(root: source, known: manifest.files.mapValues(\.source), changed: changedPaths) }
        else { files = try scan(source) }
        // Include removed paths that never had a successful manifest entry (for stale conflict/wait cleanup).
        result.evaluatedPaths.formUnion((changedPaths ?? []).filter { !deferredPaths.contains($0) })
        let paths = files.keys.filter { path in
            guard !deferredPaths.contains(path) else { return false }
            guard let changedPaths, !fullScan else { return true }
            return manifest.files[path] == nil || changedPaths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.isEmpty }
        }.sorted()
        for (index, path) in paths.enumerated() {
            result.evaluatedPaths.insert(path)
            try Task.checkCancellation()
            progress(BackupProgress(path: path, completed: index, total: paths.count, size: files[path]?.size, stage: "파일 비교·검증"))
            do {
                let src = try child(source, path), dst = try child(root, path), stamp = files[path]!
                let sourceLock = try FileAccess.readLock(src); defer { FileAccess.unlock(sourceLock) }
                let targetLock = fm.fileExists(atPath: dst.path) ? try FileAccess.readLock(dst) : nil
                defer { if let targetLock { FileAccess.unlock(targetLock) } }
                if fm.fileExists(atPath: dst.path) {
                    let backup = try FileStamp(dst)
                    if let old = manifest.files[path], old.source == stamp, old.backup == backup, !fullScan { result.skipped += 1; continue }
                    let digest = try Self.hash(src)
                    if try Self.hash(dst) == digest {
                        manifest.files[path] = FileRecord(source: stamp, backup: backup, hash: digest)
                        result.skipped += 1; continue
                    }
                    if backup.modified >= stamp.modified {
                        result.issues.append(BackupIssue(jobID: job.id, path: path, reason: backup.modified > stamp.modified ? "백업 파일이 원본보다 최신입니다." : "수정 시간이 같지만 내용이 다릅니다.", conflict: true, source: stamp, backup: backup)); continue
                    }
                }
                if !fm.fileExists(atPath: dst.path), manifest.files[path] != nil {
                    // Preserve the source content when a known backup was deleted externally.
                    let staging = try child(root, ".safesync-staging")
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    let preserved = staging.appendingPathComponent(UUID().uuidString + ".preserved")
                    try fm.copyItem(at: src, to: preserved)
                    guard try Self.hash(src) == Self.hash(preserved), try FileStamp(src) == stamp else {
                        try? fm.removeItem(at: preserved)
                        throw BackupError.unsafe("삭제된 백업을 보호하는 동안 원본이 변경되었습니다.")
                    }
                    try archive(preserved, path: path, root: root)
                }
                let digest = try transfer(src, to: dst, path: path, root: root, expected: stamp)
                manifest.files[path] = FileRecord(source: stamp, backup: try FileStamp(dst), hash: digest)
                result.copied += 1
                try Storage.save(manifest, to: manifestURL(job))
            } catch is CancellationError { throw CancellationError() }
            catch { result.issues.append(FileAccess.issue(error, jobID: job.id, path: path)) }
        }
        if job.mirrorDeletes {
            for path in manifest.files.keys.sorted() where files[path] == nil && !deferredPaths.contains(path) {
                result.evaluatedPaths.insert(path)
                try Task.checkCancellation()
                do {
                    // Never infer deletion from a disconnected or unreadable source.
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { throw BackupError.unsafe("원본 연결이 끊겨 삭제 처리를 중단합니다.") }
                    let original = try child(source, path)
                    // A skipped symbolic link or an unreadable entry is not a deletion.
                    if (try? fm.attributesOfItem(atPath: original.path)) != nil { continue }
                    let dst = try child(root, path)
                    if fm.fileExists(atPath: dst.path) { try archive(dst, path: path, root: root); result.removed += 1 }
                    manifest.files.removeValue(forKey: path)
                    try Storage.save(manifest, to: manifestURL(job))
                } catch { result.issues.append(FileAccess.issue(error, jobID: job.id, path: path)) }
            }
        }
        try Storage.save(manifest, to: manifestURL(job))
        progress(BackupProgress(path: "완료", completed: paths.count, total: paths.count))
        return result
    }
    public func resolve(_ issue: BackupIssue, job: BackupJob, action: ConflictAction) throws {
        try Self.validate(job)
        let root = Self.canonical(job.destination), source = Self.canonical(job.source)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try recover(root)
        let src = try child(source, issue.path), dst = try child(root, issue.path)
        let stamp = try FileStamp(src)
        guard stamp == issue.source, try FileStamp(dst) == issue.backup else { throw BackupError.unsafe("충돌 발견 후 파일이 변경되었습니다. 전체 검사를 다시 실행하세요.") }
        if action == .keepBoth {
            let sibling = dst.deletingLastPathComponent().appendingPathComponent(dst.lastPathComponent + ".SafeSync-conflict-" + UUID().uuidString)
            try fm.copyItem(at: dst, to: sibling)
            guard try Self.hash(sibling) == Self.hash(dst) else { throw BackupError.unsafe("이전 버전 복사 검증에 실패했습니다.") }
        }
        let digest = try transfer(src, to: dst, path: issue.path, root: root, expected: stamp)
        var manifest = try loadManifest(job)
        manifest.files[issue.path] = FileRecord(source: stamp, backup: try FileStamp(dst), hash: digest)
        try Storage.save(manifest, to: manifestURL(job))
    }
    public func listTrash(_ job: BackupJob) throws -> [TrashItem] {
        let root = Self.canonical(job.destination)
        let dir = try child(root, ".safesync-trash")
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try Storage.load(TrashItem.self, from: $0) }.filter { fm.fileExists(atPath: dir.appendingPathComponent("\($0.id).data").path) }.sorted { $0.deletedAt > $1.deletedAt }
    }
    public func restore(_ item: TrashItem, job: BackupJob) throws {
        guard item.path.split(separator: "/").first?.hasPrefix(".safesync-") != true else { throw BackupError.unsafe("SafeSync 내부 경로에는 복구할 수 없습니다.") }
        let root = Self.canonical(job.destination)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        let dir = try trashDirectory(root), stored = dir.appendingPathComponent("\(item.id).data")
        let dst = try child(root, item.path)
        let stamp = try FileStamp(stored)
        _ = try transfer(stored, to: dst, path: item.path, root: root, expected: stamp)
        try fm.removeItem(at: stored)
        try fm.removeItem(at: dir.appendingPathComponent("\(item.id).json"))
    }
    public func deleteTrash(_ items: [TrashItem], job: BackupJob) throws {
        let root = Self.canonical(job.destination)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        let dir = try trashDirectory(root)
        for item in items {
            try fm.removeItem(at: dir.appendingPathComponent("\(item.id).data"))
            try fm.removeItem(at: dir.appendingPathComponent("\(item.id).json"))
        }
    }
    public func pruneTrash(_ job: BackupJob, retentionDays: Int, now: Date = Date()) throws -> Int {
        guard retentionDays >= 1 else { throw BackupError.unsafe("보관기간은 1일 이상이어야 합니다.") }
        let root = Self.canonical(job.destination)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try recover(root)
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let old = try listTrash(job).filter { $0.deletedAt < cutoff }
        let dir = try trashDirectory(root)
        for item in old {
            try fm.removeItem(at: dir.appendingPathComponent("\(item.id).data"))
            try fm.removeItem(at: dir.appendingPathComponent("\(item.id).json"))
        }
        return old.count
    }

}
