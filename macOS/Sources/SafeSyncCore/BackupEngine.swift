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
        let timing = OperationLog.measure("file.sha256", path: url.path); defer { timing.end() }
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
        guard (1...1_000_000).contains(job.massMinimum), (1...100).contains(job.massPercent) else { throw BackupError.unsafe("대량 변경 보호 기준을 확인하세요.") }
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
        let timing = OperationLog.measure("prepare.state_load"); defer { timing.end() }
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
        let isDirectory = (try file.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        let held = isDirectory ? nil : try FileAccess.readLock(file); defer { if let held { FileAccess.unlock(held) } }
        let checksum: String?
        if isDirectory { checksum = nil } else { checksum = try Self.hash(file) }
        let item = TrashItem(id: UUID(), path: path, deletedAt: Date(), size: try FileStamp(file).size, directory: isDirectory, batchID: RecoveryBatch.id, expectedHash: checksum, hashKind: isDirectory ? nil : "sha256")
        let dir = try trashDirectory(root)
        try Storage.save(item, to: dir.appendingPathComponent("\(item.id).json"))
        do { try fm.moveItem(at: file, to: dir.appendingPathComponent("\(item.id).data")) }
        catch { try? fm.removeItem(at: dir.appendingPathComponent("\(item.id).json")); throw error }
    }
    private func recover(_ root: URL) throws {
        let timing = OperationLog.measure("prepare.local_transaction_recovery"); defer { timing.end() }
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
    private func transfer(_ source: URL, to destination: URL, path: String, root: URL, expected: FileStamp, validate: () throws -> Void = {}) throws -> String {
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
        try validate()
        let targetLock = fm.fileExists(atPath: destination.path) ? try FileAccess.readLock(destination) : nil
        defer { if let targetLock { FileAccess.unlock(targetLock) } }
        if fm.fileExists(atPath: destination.path) {
            let tx = Transaction(destination: path, temporary: relative, expectedHash: digest, trash: TrashItem(id: UUID(), path: path, deletedAt: Date(), size: try FileStamp(destination).size, batchID: RecoveryBatch.id, expectedHash: try Self.hash(destination), hashKind: "sha256"))
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
        return try RecoveryBatch.withRun { try runCore(job, fullScan: fullScan, changedPaths: changedPaths, deferredPaths: deferredPaths, progress: progress) }
    }
    private func runCore(_ job: BackupJob, fullScan: Bool = false, changedPaths: Set<String>? = nil, deferredPaths: Set<String> = [], progress: @Sendable (BackupProgress) -> Void = { _ in }) throws -> BackupResult {
        try Self.validate(job)
        let root = Self.canonical(job.destination), source = Self.canonical(job.source)
        var manifest = try loadManifest(job), result = BackupResult()
        let sourceGuard = try LocalRootGuard(job.source, expected: manifest.sourceIdentity)
        let targetGuard = try LocalRootGuard(job.destination, expected: manifest.destinationIdentity)
        let legacy = manifest.sourceIdentity == nil || manifest.destinationIdentity == nil
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try sourceGuard.verify(); try targetGuard.verify()
        try recover(root)
        if let oldSource = manifest.sourceRoot, let oldDestination = manifest.destinationRoot {
            guard oldSource == source.path, oldDestination == root.path else { throw BackupError.unsafe("작업 경로가 이전 백업 기록과 다릅니다. 새 작업으로 등록하세요.") }
        }
        manifest.sourceRoot = source.path; manifest.destinationRoot = root.path
        manifest.sourceIdentity = sourceGuard.identity; manifest.destinationIdentity = targetGuard.identity
        let files: [String: FileStamp]
        if let changedPaths, !fullScan, !legacy, !MassChanges.blocked(directory: dataDirectory, job: job), !manifest.files.isEmpty { files = try SourceScanner.reconcile(root: source, known: manifest.files.mapValues(\.source), changed: changedPaths) }
        else { files = try scan(source) }
        let massPrior = manifest.files.filter { $0.value.verificationVersion == 1 }.mapValues(\.source)
        try MassChanges.check(directory: dataDirectory, job: job, baseline: massPrior.count,
                              changes: MassChanges.differences(prior: massPrior, current: files, side: "원본", deletion: job.mirrorDeletes).filter { !deferredPaths.contains($0.path) }, roots: sourceGuard.identity + "|" + targetGuard.identity)
        // Include removed paths that never had a successful manifest entry (for stale conflict/wait cleanup).
        result.evaluatedPaths.formUnion((changedPaths ?? []).filter { !deferredPaths.contains($0) })
        let paths = files.keys.filter { path in
            guard !deferredPaths.contains(path) else { return false }
            guard let changedPaths, !fullScan, !legacy else { return true }
            return manifest.files[path]?.verificationVersion != 1 || changedPaths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.isEmpty }
        }.sorted()
        for (index, path) in paths.enumerated() {
            let timing = OperationLog.measure("file.total", path: path); defer { timing.end() }
            result.evaluatedPaths.insert(path)
            try Task.checkCancellation()
            progress(BackupProgress(path: path, completed: index, total: paths.count, size: files[path]?.size, stage: "파일 비교·검증"))
            try Task.checkCancellation()
            do {
                try sourceGuard.verify(); try targetGuard.verify()
                let src = try child(source, path), dst = try child(root, path), stamp = files[path]!
                let sourceLock = try FileAccess.readLock(src); defer { FileAccess.unlock(sourceLock) }
                let targetLock = fm.fileExists(atPath: dst.path) ? try FileAccess.readLock(dst) : nil
                defer { if let targetLock { FileAccess.unlock(targetLock) } }
                if fm.fileExists(atPath: dst.path) {
                    let backup = try FileStamp(dst)
                    let digest = try Self.hash(src)
                    if try Self.hash(dst) == digest {
                        guard try FileStamp(src) == stamp else { throw BackupError.fileBusy("파일 비교 중 원본이 변경되었습니다.") }
                        try sourceGuard.verify(); try targetGuard.verify()
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
                    try sourceGuard.verify(); try targetGuard.verify()
                    try archive(preserved, path: path, root: root)
                }
                let digest = try transfer(src, to: dst, path: path, root: root, expected: stamp, validate: {
                    try sourceGuard.verify(); try targetGuard.verify()
                })
                manifest.files[path] = FileRecord(source: stamp, backup: try FileStamp(dst), hash: digest)
                result.copied += 1
                try Storage.save(manifest, to: manifestURL(job))
            } catch is CancellationError { throw CancellationError() }
            catch { OperationLog.event("file.error", "local", path: path, error: error); result.issues.append(FileAccess.issue(error, jobID: job.id, path: path)) }
        }
        if job.mirrorDeletes {
            for path in manifest.files.keys.sorted() where files[path] == nil && !deferredPaths.contains(path) {
                result.evaluatedPaths.insert(path)
                try Task.checkCancellation()
                do {
                    try targetGuard.verify()
                    guard manifest.files[path]?.verificationVersion == 1 else {
                        throw BackupError.unsafe("이전 버전 기록의 원본을 재확인하지 못해 자동 삭제를 보류합니다. 파일 비교에서 확인하세요.")
                    }
                    guard try sourceGuard.confirmedMissing(path) else { continue }
                    let dst = try child(root, path)
                    if !(try targetGuard.confirmedMissing(path)) {
                        guard let backup = try FileComparisons.local(root: root.path, path: path), !backup.folder,
                              backup.hash == manifest.files[path]?.hash else {
                            throw BackupError.unsafe("삭제 비교 후 백업 내용 또는 파일 종류가 변경되어 보존합니다.")
                        }
                        try targetGuard.verify()
                        guard try sourceGuard.confirmedMissing(path) else { continue }
                        try archive(dst, path: path, root: root); result.removed += 1
                    }
                    manifest.files.removeValue(forKey: path)
                    try Storage.save(manifest, to: manifestURL(job))
                } catch { result.issues.append(FileAccess.issue(error, jobID: job.id, path: path)) }
            }
        }
        try sourceGuard.verify(); try targetGuard.verify()
        try Storage.save(manifest, to: manifestURL(job))
        progress(BackupProgress(path: "완료", completed: paths.count, total: paths.count))
        return result
    }
    public func resolve(_ issue: BackupIssue, job: BackupJob, action: ConflictAction) throws {
        guard action == .overwrite || action == .keepBoth else { throw BackupError.unsafe("파일 비교 화면에서 처리를 선택하세요.") }
        try Self.validate(job)
        let root = Self.canonical(job.destination), source = Self.canonical(job.source)
        var manifest = try loadManifest(job)
        let sourceGuard = try LocalRootGuard(job.source, expected: manifest.sourceIdentity)
        let targetGuard = try LocalRootGuard(job.destination, expected: manifest.destinationIdentity)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try sourceGuard.verify(); try targetGuard.verify()
        try recover(root)
        let src = try child(source, issue.path), dst = try child(root, issue.path)
        let stamp = try FileStamp(src)
        guard stamp == issue.source, try FileStamp(dst) == issue.backup else { throw BackupError.unsafe("충돌 발견 후 파일이 변경되었습니다. 전체 검사를 다시 실행하세요.") }
        if action == .keepBoth {
            let sibling = dst.deletingLastPathComponent().appendingPathComponent(dst.lastPathComponent + ".SafeSync-conflict-" + UUID().uuidString)
            try fm.copyItem(at: dst, to: sibling)
            guard try Self.hash(sibling) == Self.hash(dst) else { throw BackupError.unsafe("이전 버전 복사 검증에 실패했습니다.") }
        }
        let digest = try transfer(src, to: dst, path: issue.path, root: root, expected: stamp, validate: {
            try sourceGuard.verify(); try targetGuard.verify()
        })
        manifest.sourceIdentity = sourceGuard.identity; manifest.destinationIdentity = targetGuard.identity
        manifest.files[issue.path] = FileRecord(source: stamp, backup: try FileStamp(dst), hash: digest)
        try Storage.save(manifest, to: manifestURL(job))
    }
    public func prepareSync(_ job: BackupJob) throws {
        try Self.validate(job)
        var descriptors: [Int32] = []; defer { for fd in descriptors { flock(fd, LOCK_UN); Darwin.close(fd) } }
        for root in [Self.canonical(job.source), Self.canonical(job.destination)].sorted(by: { $0.path < $1.path }) {
            descriptors.append(try lock(root)); try recover(root)
        }
    }
    /// Revalidate both endpoints immediately before the atomic exchange.
    public func apply(_ comparison: FileComparison, action: ConflictAction) throws {
        let job = comparison.job
        try Self.validate(job)
        guard job.cloudProvider == nil, comparison.allows(action) else { throw BackupError.unsafe("선택한 처리를 적용할 수 없습니다.") }
        if action == .ignore { return }
        let roots = [Self.canonical(job.source), Self.canonical(job.destination)].sorted { $0.path < $1.path }
        var locks: [Int32] = []; defer { for fd in locks { flock(fd, LOCK_UN); Darwin.close(fd) } }
        for root in roots { locks.append(try lock(root)); try recover(root) }
        let check = { try FileComparisons.verify(comparison, current: FileComparisons.localPair(job: job, path: comparison.path)) }
        try check()
        let reverse = action == .useBackup
        let fromRoot = Self.canonical(reverse ? job.destination : job.source)
        let toRoot = Self.canonical(reverse ? job.source : job.destination)
        let src = try child(fromRoot, comparison.path), dst = try child(toRoot, comparison.path)
        let targetLock = fm.fileExists(atPath: dst.path) ? try FileAccess.readLock(dst) : nil
        defer { if let targetLock { FileAccess.unlock(targetLock) } }
        if action == .keepBoth {
            let sibling = dst.appendingPathExtension("SafeSync-conflict-" + UUID().uuidString)
            try fm.copyItem(at: dst, to: sibling)
            guard try Self.hash(sibling) == comparison.backup?.hash else { throw BackupError.unsafe("보존 사본 검증에 실패했습니다.") }
        }
        _ = try transfer(src, to: dst, path: comparison.path, root: toRoot,
            expected: (reverse ? comparison.backup : comparison.source)!.stamp, validate: check)
    }
    public func installDownload(_ file: URL, comparison: FileComparison) throws {
        let root = Self.canonical(comparison.job.source)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try recover(root)
        let check = {
            guard try FileComparisons.identity(root) == comparison.sourceRoot,
                  try FileComparisons.local(root: root.path, path: comparison.path) == comparison.source else {
                throw BackupError.unsafe("다운로드 중 원본이 변경되어 보존했습니다.")
            }
        }
        let target = try child(root, comparison.path)
        let targetLock = fm.fileExists(atPath: target.path) ? try FileAccess.readLock(target) : nil
        defer { if let targetLock { FileAccess.unlock(targetLock) } }
        try check()
        _ = try transfer(file, to: target, path: comparison.path, root: root, expected: FileStamp(file), validate: check)
    }
    public func changeStructure(_ comparison: FileComparison, forward: Bool, deleting: Bool) throws {
        try Task.checkCancellation()
        let job = comparison.job, root = Self.canonical(forward ? job.destination : job.source)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        try recover(root)
        if job.cloudProvider == nil { try FileComparisons.verify(comparison, current: FileComparisons.localPair(job: job, path: comparison.path)) }
        else {
            guard try FileComparisons.identity(root) == comparison.sourceRoot,
                  try FileComparisons.local(root: root.path, path: comparison.path) == comparison.source else { throw BackupError.unsafe("원본이 변경되었습니다.") }
        }
        let target = try child(root, comparison.path)
        if deleting {
            if (forward ? comparison.backup : comparison.source)?.folder == true,
               !(try fm.contentsOfDirectory(atPath: target.path)).isEmpty { throw BackupError.unsafe("폴더에 남은 항목이 있어 삭제를 보류합니다.") }
            try archive(target, path: comparison.path, root: root)
        } else { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
    }
    public func listTrash(_ job: BackupJob) throws -> [TrashItem] {
        let root = Self.canonical(job.destination)
        let dir = try child(root, ".safesync-trash")
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { try Storage.load(TrashItem.self, from: $0) }.filter { fm.fileExists(atPath: dir.appendingPathComponent("\($0.id).data").path) }.sorted { $0.deletedAt > $1.deletedAt }
    }
    public func verifyTrash(_ item: TrashItem, job: BackupJob) throws -> Bool {
        let root = Self.canonical(job.destination)
        let metadata = try child(root, ".safesync-trash/\(item.id).json")
        let saved = try Storage.load(TrashItem.self, from: metadata)
        guard saved.id == item.id, saved.path == item.path, saved.size == item.size, saved.expectedHash == item.expectedHash else { throw BackupError.unsafe("휴지통 기록이 변경되었습니다. 다시 불러오세요.") }
        let stored = try child(root, ".safesync-trash/\(item.id).data")
        if saved.directory == true { _ = try fm.contentsOfDirectory(atPath: stored.path); return false }
        let digest = try Self.hash(stored)
        guard try FileStamp(stored).size == saved.size else { throw BackupError.unsafe("보관 파일 크기가 달라 복원을 중단했습니다.") }
        guard let expected = saved.expectedHash else { return false }
        guard saved.hashKind == "sha256", expected == digest else { throw BackupError.unsafe("보관 당시 체크섬과 다릅니다. 손상 가능성이 있어 복원을 중단했습니다.") }
        return true
    }
    public func verifyBackup(_ job: BackupJob, progress: @Sendable (RestoreCheckRow) -> Void = { _ in }) throws -> [RestoreCheckRow] {
        let manifest = try loadManifest(job), root = Self.canonical(job.destination)
        if let source = manifest.sourceRoot, source != Self.canonical(job.source).path { throw BackupError.unsafe("검증 작업이 성공 백업의 위치와 다릅니다.") }
        if let target = manifest.destinationRoot, target != root.path { throw BackupError.unsafe("백업 위치가 변경되었습니다.") }
        let guardRoot = try LocalRootGuard(job.destination, expected: manifest.destinationIdentity); var rows: [RestoreCheckRow] = []
        for (path,record) in manifest.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation(); try guardRoot.verify(); let row: RestoreCheckRow
            do { row = try RestoreVerifier.local(child(root,path), path: path, expected: record.hash) }
            catch is CancellationError { throw CancellationError() }
            catch { row = RestoreCheckRow(path: path, length: record.backup.size, status: "실패", detail: error.localizedDescription) }
            rows.append(row); progress(row)
        }
        try guardRoot.verify(); return rows
    }
    public func restore(_ item: TrashItem, job: BackupJob) throws {
        let held = item.directory == true ? nil : try FileAccess.readLock(child(Self.canonical(job.destination), ".safesync-trash/\(item.id).data"))
        defer { if let held { FileAccess.unlock(held) } }
        _ = try verifyTrash(item, job: job)
        guard item.path.split(separator: "/").first?.hasPrefix(".safesync-") != true else { throw BackupError.unsafe("SafeSync 내부 경로에는 복구할 수 없습니다.") }
        let root = Self.canonical(job.destination)
        let fd = try lock(root); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        let dir = try trashDirectory(root), stored = dir.appendingPathComponent("\(item.id).data")
        let dst = try child(root, item.path)
        if item.directory == true {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard renameatx_np(AT_FDCWD, stored.path, AT_FDCWD, dst.path, UInt32(RENAME_EXCL)) == 0 else { throw BackupError.unsafe("복구 위치에 항목이 있거나 폴더를 복구할 수 없습니다. 사본을 보존합니다.") }
            try fm.removeItem(at: dir.appendingPathComponent("\(item.id).json")); return
        }
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
