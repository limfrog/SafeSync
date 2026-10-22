import Foundation
import Darwin

/// A verified common baseline, never timestamps, grants authority to propagate a deletion.
public actor SyncCoordinator {
    private struct Conflict: LocalizedError { var errorDescription: String?; init(_ reason: String) { errorDescription = reason } }
    private struct Baseline: Codable {
        var sourceRoot: String
        var backupRoot: String
        var endpoint: BackupJob
        var files: [String: Pair] = [:]
    }
    private struct Pair: Codable { var source: ComparedFile?; var backup: ComparedFile? }
    private let directory: URL
    private let local: BackupEngine
    private let cloud: CloudBackupEngine
    private var active: Set<UUID> = []
    public init(dataDirectory: URL = Storage.applicationDirectory) {
        directory = dataDirectory; local = BackupEngine(dataDirectory: dataDirectory); cloud = CloudBackupEngine(dataDirectory: dataDirectory)
    }
    private func lease(_ id: UUID) throws -> Int32 {
        let folder = directory.appendingPathComponent("two-way/locks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = Darwin.open(folder.appendingPathComponent(id.uuidString).path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BackupError.unsafe("동기화 잠금을 열 수 없습니다.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw BackupError.unsafe("다른 프로세스에서 이 작업을 실행 중입니다.") }
        return fd
    }
    private func same(_ a: ComparedFile?, _ b: ComparedFile?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.folder == b.folder && (a.folder || (a.hash != nil && a.hash == b.hash && a.stamp.size == b.stamp.size))
    }
    private func equal(_ c: FileComparison) throws -> Bool {
        guard let a = c.source, let b = c.backup else { return c.source == nil && c.backup == nil }
        guard a.folder == b.folder else { return false }
        if a.folder { return true }
        if let remote = c.remote {
            guard let hash = remote.hash, let kind = remote.hashKind, a.stamp.size == remote.size else { return false }
            let file = try SourceScanner.file(BackupEngine.canonical(c.job.source), path: c.path)
            return try ContentHash.compute(file, kind: kind) == hash
        }
        return same(a, b)
    }
    private func tree(_ root: URL) throws -> Set<String> {
        _ = try FileComparisons.identity(root)
        var failure: Error?, paths: Set<String> = []
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey], errorHandler: { _, error in failure = error; return false }) else { throw BackupError.unsafe("폴더 전체를 읽을 수 없습니다.") }
        for case let url as URL in entries {
            try Task.checkCancellation()
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/") else { throw BackupError.unsafe("폴더 밖 경로가 발견되었습니다: \(root.path) / \(resolved.path)") }
            let ownData = Storage.applicationDirectory.standardizedFileURL.resolvingSymlinksInPath().path
            if resolved.path == ownData || resolved.path.hasPrefix(ownData + "/") { entries.skipDescendants(); continue }
            let path = String(resolved.path.dropFirst(root.path.count + 1))
            if path.split(separator: "/").first?.hasPrefix(".safesync-") == true { entries.skipDescendants(); continue }
            let flags = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            // Unreadable or unsupported entries must never be interpreted as deletion.
            guard flags.isSymbolicLink != true, flags.isDirectory == true || flags.isRegularFile == true else { throw BackupError.unsafe("양방향 동기화 경로에 링크 또는 지원하지 않는 항목이 있습니다: \(path)") }
            paths.insert(path)
        }
        if let failure { throw failure }
        return paths
    }
    private func remoteTree(_ root: String, storage: any RemoteStorage) async throws -> Set<String> {
        var paths: Set<String> = [], visited: Set<String> = []
        func visit(_ parent: String, prefix: String) async throws {
            guard visited.insert(parent).inserted else { throw BackupError.unsafe("클라우드 폴더 순환 경로입니다.") }
            for item in try await storage.children(parent) {
                try Task.checkCancellation()
                if prefix.isEmpty && item.name.hasPrefix(".safesync-") { continue }
                let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
                try FileComparisons.validatePath(path); paths.insert(path)
                if item.folder { try await visit(item.locator, prefix: path) }
            }
        }
        try await visit(root, prefix: ""); return paths
    }
    public func run(_ job: BackupJob, storage: (any RemoteStorage)? = nil, deferredPaths: Set<String> = [], progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) async throws -> BackupResult {
        try BackupEngine.validate(job)
        guard active.insert(job.id).inserted else { throw BackupError.unsafe("같은 작업이 실행 중입니다.") }
        defer { active.remove(job.id) }
        let fd = try lease(job.id); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        if let storage { try await cloud.prepareSync(job, storage: storage) } else { try await local.prepareSync(job) }
        let url = directory.appendingPathComponent("two-way/\(job.id).json")
        let sourceRoot = try FileComparisons.identity(BackupEngine.canonical(job.source))
        let backupRoot: String
        if let storage {
            guard let root = try await storage.metadata(job.cloudFolderID!), root.folder else { throw BackupError.unsafe("클라우드 루트에 접근할 수 없습니다.") }
            backupRoot = root.id
        } else { backupRoot = try FileComparisons.identity(BackupEngine.canonical(job.destination)) }
        var state = FileManager.default.fileExists(atPath: url.path) ? try Storage.load(Baseline.self, from: url) : Baseline(sourceRoot: sourceRoot, backupRoot: backupRoot, endpoint: job)
        guard state.sourceRoot == sourceRoot, state.backupRoot == backupRoot, FileComparisons.sameEndpoints(state.endpoint, job) else { throw BackupError.unsafe("양방향 동기화의 폴더 또는 계정이 바뀌었습니다. 새 작업으로 등록하세요.") }
        progress(BackupProgress(path: "양쪽 폴더 전체 목록 확인", completed: 0, total: 1))
        // Complete both enumerations before allowing any file or directory deletion.
        let left = try tree(BackupEngine.canonical(job.source))
        let right = if let storage { try await remoteTree(job.cloudFolderID!, storage: storage) } else { try tree(BackupEngine.canonical(job.destination)) }
        let discovered = left.union(right).union(state.files.keys).subtracting(deferredPaths)
        let excluded = discovered.filter { path in
            job.cloudProvider.map { CloudPathPolicy.isExcluded(path, provider: $0) } ?? false
        }
        let all = discovered.subtracting(excluded)
        // Files first; directories missing on one side are deleted only after their children.
        var snapshots: [String: FileComparison] = [:]
        for path in all.sorted() { snapshots[path] = try await FileComparisons.read(job: job, path: path, storage: storage) }
        let paths = all.sorted {
            let a = snapshots[$0]!, b = snapshots[$1]!
            let ad = a.source?.folder == true || a.backup?.folder == true
            let bd = b.source?.folder == true || b.backup?.folder == true
            if ad != bd { return !ad }
            if ad, $0.split(separator: "/").count != $1.split(separator: "/").count { return $0.split(separator: "/").count > $1.split(separator: "/").count }
            return $0 < $1
        }
        var result = BackupResult()
        result.evaluatedPaths.formUnion(excluded); result.skipped += excluded.count
        for (offset, path) in paths.enumerated() {
            try Task.checkCancellation(); result.evaluatedPaths.insert(path)
            progress(BackupProgress(path: path, completed: offset, total: paths.count, stage: "양방향 비교·반영"))
            try Task.checkCancellation()
            do {
                // Parent timestamps can legitimately change as verified child operations complete.
                let c = try await FileComparisons.read(job: job, path: path, storage: storage)
                if c.waiting { throw BackupError.fileBusy(c.sourceError + " " + c.backupError) }
                if c.networkFailure { throw TransientNetworkFailure(c.sourceError + " " + c.backupError) }
                guard c.readable, c.sourceRoot == sourceRoot, c.backupRoot == backupRoot else { throw BackupError.unsafe("양쪽 위치에 접근할 수 없습니다. 변경을 보류합니다.") }
                if !c.duplicates.isEmpty || c.candidates.count > 1 {
                    var identical = c.source != nil && !c.candidates.isEmpty
                    for item in c.candidates {
                        if c.source?.folder == true { if !item.folder { identical = false }; continue }
                        guard !item.folder, item.hash != nil, item.size == c.source?.stamp.size else { identical = false; break }
                        let file = try SourceScanner.file(BackupEngine.canonical(job.source), path: path)
                        if try ContentHash.compute(file, kind: item.hashKind ?? "") != item.hash { identical = false; break }
                    }
                    if identical {
                        try await FileComparisons.verify(c, job: job, storage: storage)
                        result.skipped += 1; continue // Duplicate identities never become deletion authority.
                    }
                    throw Conflict("중복 이름이 있습니다. 문제 해결에서 사본을 모두 보존하며 정리하세요.")
                }
                if try equal(c) {
                    state.files[path] = Pair(source: c.source, backup: c.backup); result.skipped += 1
                } else {
                    if let a = c.source, let b = c.backup, a.folder != b.folder { throw Conflict("파일과 폴더가 같은 경로를 사용합니다.") }
                    let forward: Bool
                    if let old = state.files[path], old.source != nil, old.backup != nil {
                        let ac = !same(c.source, old.source), bc = !same(c.backup, old.backup)
                        guard ac != bc else { throw Conflict("양쪽 파일이 모두 변경되었거나 삭제와 수정이 겹쳤습니다. 유지할 사본을 선택하세요.") }
                        forward = ac
                    } else {
                        guard c.source == nil || c.backup == nil else { throw Conflict("최초 비교에서 양쪽 내용이 다릅니다. 유지할 사본을 선택하세요.") }
                        forward = c.source != nil
                    }
                    let chosen = forward ? c.source : c.backup
                    if chosen == nil || chosen?.folder == true {
                        if let storage { try await cloud.changeStructure(c, forward: forward, deleting: chosen == nil, storage: storage, local: local) }
                        else { try await local.changeStructure(c, forward: forward, deleting: chosen == nil) }
                        if chosen == nil { result.removed += 1 } else { result.copied += 1 }
                    } else {
                        if let storage { try await cloud.apply(c, action: forward ? .overwrite : .useBackup, storage: storage, local: local) }
                        else { try await local.apply(c, action: forward ? .overwrite : .useBackup) }
                        result.copied += 1
                    }
                    let updated = try await FileComparisons.read(job: job, path: path, storage: storage)
                    guard try equal(updated) else { throw BackupError.unsafe("반영 후 양쪽 비교에 실패했습니다. 비교 기록을 갱신하지 않습니다.") }
                    state.files[path] = Pair(source: updated.source, backup: updated.backup)
                }
                try Storage.save(state, to: url)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let c = snapshots[path]!
                var issue = FileAccess.issue(error, jobID: job.id, path: path)
                if error is Conflict { issue.conflict = true }
                issue.source = c.source?.stamp; issue.backup = c.backup?.stamp; issue.remoteID = c.remote?.id; issue.remoteRevision = c.remote?.revision
                result.issues.append(issue)
            }
        }
        try Storage.save(state, to: url)
        progress(BackupProgress(path: "완료", completed: paths.count, total: paths.count)); return result
    }
    public func apply(_ decisions: [ResolutionDecision], job: BackupJob, storage: (any RemoteStorage)? = nil, progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) async throws -> BackupResult {
        guard active.insert(job.id).inserted else { throw BackupError.unsafe("작업이 실행 중입니다.") }
        defer { active.remove(job.id) }
        let fd = try lease(job.id); defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard Set(decisions.map { $0.comparison.path }).count == decisions.count else { throw BackupError.unsafe("같은 파일에 여러 처리를 지정할 수 없습니다.") }
        // Preflight the entire batch before mutating the first file.
        for decision in decisions where decision.action != .ignore {
            guard decision.comparison.allows(decision.action) else { throw BackupError.unsafe("적용할 수 없는 처리입니다.") }
            try await FileComparisons.verify(decision.comparison, job: job, storage: storage)
        }
        var result = BackupResult()
        for (offset, decision) in decisions.enumerated() {
            progress(BackupProgress(path: decision.comparison.path, completed: offset, total: decisions.count, stage: "선택한 처리 적용"))
            try Task.checkCancellation()
            guard FileComparisons.sameEndpoints(decision.comparison.job, job) else { throw BackupError.unsafe("작업 위치가 바뀌었습니다.") }
            if decision.action == .ignore { result.skipped += 1 }
            else {
                if let storage { try await cloud.apply(decision.comparison, action: decision.action, storage: storage, local: local) }
                else { try await local.apply(decision.comparison, action: decision.action) }
                if decision.action == .normalizeDuplicates { result.skipped += 1 } else { result.copied += 1 }
            }
            result.evaluatedPaths.insert(decision.comparison.path)
        }
        progress(BackupProgress(path: "완료", completed: decisions.count, total: decisions.count))
        return result
    }
}
