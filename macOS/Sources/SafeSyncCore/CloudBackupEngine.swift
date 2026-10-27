import Foundation
import CryptoKit
import Darwin

public actor CloudBackupEngine {
    private let dataDirectory: URL
    private let fm = FileManager.default
    private var active: Set<String> = []
    private struct Record: Codable {
        var source: FileStamp
        var remote: RemoteItem
        var verificationVersion: Int? = 1
        // Optional so snapshots written by 0.3.13 remain readable. They earn
        // fast-comparison authority only after one successful content check.
        var sourceIdentity: String?
        var verifiedRemote: RemoteItem?
        // Google Drive permits several physical items at one logical path.
        // Once every copy has been content-verified, keep the exact set so an
        // unchanged remote poll does not hash the same files again.
        var verifiedDuplicates: [RemoteItem]?
        var sourceSHA256: String? = nil
    }
    private struct State: Codable {
        var source: String
        var root: String
        var account: UUID
        var files: [String: Record] = [:]
        var inventory: RemoteIndex?
        var sourceIdentity: String?
        var remoteRootIdentity: String?
    }
    private struct Transaction: Codable {
        var path: String
        var parent: String
        var name: String
        var staged: RemoteItem
        var previous: RemoteItem?
        var archiveParent: String?
        var archiveName: String?
    }
    public init(dataDirectory: URL = Storage.applicationDirectory) { self.dataDirectory = dataDirectory }
    private func stateURL(_ job: BackupJob) -> URL { dataDirectory.appendingPathComponent("cloud/manifests/\(job.id).json") }
    private func transactionDirectory(_ job: BackupJob) -> URL { dataDirectory.appendingPathComponent("cloud/transactions/\(job.id)") }
    private func lease(_ job: BackupJob) throws -> (String, Int32) {
        guard let account = job.cloudAccountID, let provider = job.cloudProvider, let root = job.cloudFolderID else { throw BackupError.unsafe("클라우드 위치를 선택하세요.") }
        let key = "\(provider.rawValue)|\(account)|\(root.lowercased())"
        guard !active.contains(key) else { throw BackupError.unsafe("다른 작업이 같은 클라우드 위치를 사용 중입니다.") }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let dir = dataDirectory.appendingPathComponent("cloud/locks")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = Darwin.open(dir.appendingPathComponent(hash).path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw BackupError.unsafe("클라우드 작업 잠금을 열 수 없습니다.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw BackupError.unsafe("다른 프로세스가 같은 클라우드 위치를 사용 중입니다.") }
        active.insert(key); return (key, fd)
    }
    private func release(_ lease: (String, Int32)) { active.remove(lease.0); flock(lease.1, LOCK_UN); Darwin.close(lease.1) }
    private func loaded(_ job: BackupJob) throws -> State {
        let timing = OperationLog.measure("prepare.state_load"); defer { timing.end() }
        let url = stateURL(job)
        let state = fm.fileExists(atPath: url.path) ? try Storage.load(State.self, from: url) : State(source: BackupEngine.canonical(job.source).path, root: job.cloudFolderID!, account: job.cloudAccountID!)
        guard state.source == BackupEngine.canonical(job.source).path, state.root == job.cloudFolderID!, state.account == job.cloudAccountID! else { throw BackupError.unsafe("클라우드 작업 경로가 저장된 기록과 다릅니다. 새 작업을 추가하세요.") }; return state
    }
    private func fresh(_ previous: RemoteItem, storage: any RemoteStorage) async throws -> RemoteItem {
        guard let item = try await storage.metadata(previous.id), item.revision == previous.revision, item.parent == previous.parent, item.name == previous.name else { throw BackupError.unsafe("백업 파일이 검사 후 변경되었습니다. 현재 파일을 보존하고 다시 검사합니다.") }; return item
    }
    private func verifyRemoteRoot(_ job: BackupJob, storage: any RemoteStorage, expected: String?) async throws -> String {
        let timing = OperationLog.measure("prepare.remote_root_verify"); defer { timing.end() }
        let current: RemoteItem?
        if let google = storage as? GoogleDriveStorage { current = try await google.validatedJobFolder(job) }
        else { current = try await storage.metadata(job.cloudFolderID!) }
        guard let folder = current, folder.folder,
              expected == nil || folder.id == expected else {
            throw BackupError.unsafe("클라우드 폴더가 이전 백업과 다르거나 연결할 수 없습니다. 기존 파일을 보존합니다.")
        }
        return folder.id
    }
    private func matching(_ expected: RemoteItem, _ actual: RemoteItem) -> Bool {
        expected.id == actual.id && expected.size == actual.size && expected.hash != nil && expected.hash == actual.hash && expected.hashKind == actual.hashKind
    }
    private func writeTrashMetadata(_ item: TrashItem, folder: String, storage: any RemoteStorage) async throws {
        let temp = dataDirectory.appendingPathComponent("cloud/metadata/\(item.id).json")
        try Storage.save(item, to: temp); defer { try? fm.removeItem(at: temp) }
        let uploaded = try await storage.upload(file: temp, name: "metadata.json", parent: folder, modified: Date(), resumeKey: "trash-\(item.id)")
        try ContentHash.verify(uploaded, file: temp)
    }
    private func archiveLocation(_ previous: RemoteItem, path: String, root: String, storage: any RemoteStorage) async throws -> String {
        let trash = try await storage.ensureFolder(name: ".safesync-trash", parent: root)
        let item = TrashItem(id: UUID(), path: path, deletedAt: Date(), size: previous.size, directory: previous.folder, batchID: RecoveryBatch.id, expectedHash: previous.hash, hashKind: previous.hashKind)
        let directory = try await storage.ensureFolder(name: item.id.uuidString, parent: trash.locator)
        try await writeTrashMetadata(item, folder: directory.locator, storage: storage)
        return directory.locator
    }
    private func sameName(_ a: String, _ b: String, storage: any RemoteStorage) -> Bool { storage.provider == .dropbox ? a.caseInsensitiveCompare(b) == .orderedSame : a == b }
    private func target(_ tx: Transaction, storage: any RemoteStorage) async throws -> RemoteItem? {
        let found = try await storage.children(tx.parent).filter { sameName($0.name, tx.name, storage: storage) }
        guard found.count <= 1 else { throw BackupError.unsafe("복구 대상 이름이 중복되었습니다. 두 파일을 보존합니다.") }; return found.first
    }
    /// Idempotent recovery never discards an old copy. A missing staged upload restores the prior copy.
    private func finish(_ tx: Transaction, storage: any RemoteStorage) async throws -> RemoteItem {
        guard var staged = try await storage.metadata(tx.staged.id), matching(tx.staged, staged) else {
            if let previous = tx.previous, let old = try await storage.metadata(previous.id), try await target(tx, storage: storage) == nil {
                _ = try await storage.move(old, name: tx.name, parent: tx.parent)
            }
            throw BackupError.unsafe("검증된 임시 업로드가 없습니다. 이전 버전을 보존했으며 복구 기록을 유지합니다.")
        }
        if storage.provider == .dropbox {
            if let previous = tx.previous, let old = try await storage.metadata(previous.id), let archiveParent = tx.archiveParent {
                if old.parent == tx.parent && sameName(old.name, tx.name, storage: storage) {
                    guard old.revision == previous.revision else { throw BackupError.unsafe("복구 중 이전 백업이 바뀌었습니다.") }
                    _ = try await storage.move(old, name: tx.archiveName ?? "payload", parent: archiveParent)
                } else { guard old.parent == archiveParent else { throw BackupError.unsafe("이전 백업 위치가 바뀌었습니다. 복구를 보류합니다.") } }
            }
            if staged.parent != tx.parent || !sameName(staged.name, tx.name, storage: storage) {
                guard try await target(tx, storage: storage) == nil else { throw BackupError.unsafe("복구 위치에 다른 파일이 있습니다.") }
                staged = try await storage.move(staged, name: tx.name, parent: tx.parent)
            }
        } else {
            // Drive supports duplicate names: publish the verified ID before moving the old ID.
            if staged.parent != tx.parent || !sameName(staged.name, tx.name, storage: storage) { staged = try await storage.move(staged, name: tx.name, parent: tx.parent) }
            guard let checked = try await storage.metadata(staged.id), matching(tx.staged, checked) else { throw BackupError.unsafe("Google Drive 배치를 확인할 수 없습니다.") }
            if let previous = tx.previous, let old = try await storage.metadata(previous.id), let archiveParent = tx.archiveParent {
                if old.parent == tx.parent && sameName(old.name, tx.name, storage: storage) {
                    guard old.revision == previous.revision else { throw BackupError.unsafe("기존 백업이 변경되었습니다. 두 사본과 복구 기록을 유지합니다.") }
                    _ = try await storage.move(old, name: tx.archiveName ?? "payload", parent: archiveParent)
                } else { guard old.parent == archiveParent else { throw BackupError.unsafe("이전 버전의 위치를 확인할 수 없습니다.") } }
            }
        }
        guard let checked = try await storage.metadata(staged.id), matching(tx.staged, checked), checked.parent == tx.parent, sameName(checked.name, tx.name, storage: storage) else { throw BackupError.unsafe("클라우드 반영 후 검증에 실패했습니다.") }
        return checked
    }
    private func recover(_ job: BackupJob, storage: any RemoteStorage) async throws {
        let timing = OperationLog.measure("prepare.cloud_transaction_recovery"); defer { timing.end() }
        let directory = transactionDirectory(job)
        guard fm.fileExists(atPath: directory.path) else { return }
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            let transaction = try Storage.load(Transaction.self, from: url)
            if CloudPathPolicy.isExcluded(transaction.path, provider: storage.provider) {
                // Keep both remote copies and the complete journal. A reserved-name publish
                // cannot succeed and must not block unrelated backups on every restart.
                let retained = dataDirectory.appendingPathComponent("cloud/excluded-transactions/\(job.id)")
                try fm.createDirectory(at: retained, withIntermediateDirectories: true)
                try fm.moveItem(at: url, to: retained.appendingPathComponent(UUID().uuidString + ".json"))
                continue
            }
            _ = try await finish(transaction, storage: storage)
            try fm.removeItem(at: url)
        }
    }
    private struct PreparedUpload: Sendable {
        var file: URL; var path: String; var stamp: FileStamp; var parent: String
        var staging: String; var snapshot: URL; var digest: String; var jobID: UUID; var root: String
        var sourceGuard: LocalRootGuard; var sourceIdentity: String
    }
    private func prepare(file: URL, path: String, stamp: FileStamp, job: BackupJob, storage: any RemoteStorage) async throws -> PreparedUpload {
        let timing = OperationLog.measure("file.stable_copy_and_hash", path: path, bytes: stamp.size); defer { timing.end() }
        guard !CloudPathPolicy.isExcluded(path, provider: storage.provider) else { throw BackupError.unsafe("Dropbox가 지원하지 않는 시스템 메타데이터 파일은 전송에서 제외됩니다.") }
        let sourceGuard = try LocalRootGuard(job.source, expected: loaded(job).sourceIdentity)
        let root = job.cloudFolderID!, parentPath = (path as NSString).deletingLastPathComponent
        let parent = try await storage.folder(path: parentPath, root: root)
        let staging = try await storage.folder(path: ".safesync-staging", root: root)
        let sourceLock = try FileAccess.readLock(file); defer { FileAccess.unlock(sourceLock) }
        let sourceIdentity = try FileComparisons.identity(file)
        let digest = try BackupEngine.hash(file)
        // Include the relative path: two identical files must not share a live snapshot or upload session.
        let pathKey = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let snapshot = dataDirectory.appendingPathComponent("cloud/snapshots/\(job.id)/\(pathKey)-\(digest).data")
        try fm.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: snapshot.path) { try fm.copyItem(at: file, to: snapshot) }
        guard try FileStamp(file) == stamp, try FileComparisons.identity(file) == sourceIdentity else { throw BackupError.fileBusy("전송 사본 준비 중 원본이 변경되어 사용 중 대기합니다.") }
        guard try BackupEngine.hash(snapshot) == digest else { throw BackupError.unsafe("전송 사본의 체크섬이 일치하지 않습니다. 기존 백업을 보존합니다.") }
        try sourceGuard.verify()
        return PreparedUpload(file: file, path: path, stamp: stamp, parent: parent, staging: staging, snapshot: snapshot, digest: digest, jobID: job.id, root: root, sourceGuard: sourceGuard, sourceIdentity: sourceIdentity)
    }
    private nonisolated static func upload(_ prepared: PreparedUpload, storage: any RemoteStorage, progress: @Sendable (String, Int64?) -> Void) async throws -> RemoteItem {
        let timing = OperationLog.measure("file.upload", path: prepared.path); defer { timing.end() }
        progress("임시 업로드", 0)
        if let google = storage as? GoogleDriveStorage {
            guard try await google.folder(path: ".safesync-staging", root: prepared.root) == prepared.staging else { throw BackupError.unsafe("전송 준비 후 임시 폴더가 변경되었습니다. 기존 사본을 보존합니다.") }
        }
        let pathKey = SHA256.hash(data: Data(prepared.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return try await storage.upload(file: prepared.snapshot,
            name: storage.provider == .googleDrive ? "part-\(pathKey)-\(prepared.digest)" : "part-\(prepared.digest)-\(UUID())",
            parent: prepared.staging, modified: prepared.stamp.modified,
            resumeKey: "\(prepared.jobID)|\(prepared.path)|\(prepared.digest)", progress: { bytes, _ in progress("임시 업로드", bytes) })
    }
    private func commit(_ prepared: PreparedUpload, staged: RemoteItem, previous: RemoteItem?, job: BackupJob, storage: any RemoteStorage, keepBoth: Bool = false, comparison: FileComparison? = nil, progress: @Sendable (String, Int64?) -> Void = { _, _ in }) async throws -> RemoteItem {
        let timing = OperationLog.measure("file.verify_publish", path: prepared.path); defer { timing.end() }
        let file = prepared.file, path = prepared.path, stamp = prepared.stamp, parent = prepared.parent
        let snapshot = prepared.snapshot, digest = prepared.digest, name = (path as NSString).lastPathComponent, root = job.cloudFolderID!
        progress("서버 체크섬 검증", nil)
        guard let verified = try await storage.metadata(staged.id) else { throw BackupError.unsafe("업로드한 파일을 찾을 수 없습니다.") }
        try ContentHash.verify(verified, file: snapshot)
        try prepared.sourceGuard.verify()
        let sourceLock = try FileAccess.readLock(file); defer { FileAccess.unlock(sourceLock) }
        guard try FileStamp(file) == stamp, try FileComparisons.identity(file) == prepared.sourceIdentity,
              try BackupEngine.hash(file) == digest else { throw BackupError.fileBusy("업로드 중 원본이 변경되어 사용 중 대기합니다. 기존 백업은 보존됩니다.") }
        try Task.checkCancellation()
        if let comparison { try await FileComparisons.verify(comparison, job: job, storage: storage) }
        var archiveParent: String?, archiveName: String?
        if let previous {
            _ = try await fresh(previous, storage: storage)
            if keepBoth { archiveParent = parent; archiveName = name + ".SafeSync-conflict-" + UUID().uuidString }
            else { archiveParent = try await archiveLocation(previous, path: path, root: root, storage: storage); archiveName = "payload" }
        } else {
            guard try await storage.children(parent).filter({ $0.name == name }).isEmpty else { throw BackupError.unsafe("전송 중 같은 이름의 백업 파일이 생겼습니다. 다시 검사하세요.") }
        }
        let tx = Transaction(path: path, parent: parent, name: name, staged: verified, previous: previous, archiveParent: archiveParent, archiveName: archiveName)
        _ = try await verifyRemoteRoot(job, storage: storage, expected: loaded(job).remoteRootIdentity)
        if let google = storage as? GoogleDriveStorage {
            guard try await google.folder(path: (path as NSString).deletingLastPathComponent, root: root) == parent else { throw BackupError.unsafe("전송 준비 후 백업 폴더가 변경되었습니다. 기존 사본을 보존합니다.") }
        }
        try prepared.sourceGuard.verify()
        let journal = transactionDirectory(job).appendingPathComponent("\(UUID()).json")
        try Storage.save(tx, to: journal)
        progress("안전한 교체 및 이전 버전 보존", nil)
        let result = try await finish(tx, storage: storage)
        try fm.removeItem(at: journal)
        try? fm.removeItem(at: snapshot)
        return result
    }
    private func publish(file: URL, path: String, stamp: FileStamp, previous: RemoteItem?, job: BackupJob, storage: any RemoteStorage, keepBoth: Bool = false) async throws -> RemoteItem {
        let prepared = try await prepare(file: file, path: path, stamp: stamp, job: job, storage: storage)
        let staged = try await Self.upload(prepared, storage: storage, progress: { _, _ in })
        return try await commit(prepared, staged: staged, previous: previous, job: job, storage: storage, keepBoth: keepBoth)
    }
    public func run(_ job: BackupJob, storage: any RemoteStorage, fullScan: Bool = false,
                    forceContentVerification: Bool = false, changedPaths: Set<String>? = nil,
                    deferredPaths: Set<String> = [], progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) async throws -> BackupResult {
        return try await RecoveryBatch.withRun { try await runCore(job, storage: storage, fullScan: fullScan, forceContentVerification: forceContentVerification, changedPaths: changedPaths, deferredPaths: deferredPaths, progress: progress) }
    }
    private func runCore(_ job: BackupJob, storage: any RemoteStorage, fullScan: Bool = false,
                    forceContentVerification: Bool = false, changedPaths: Set<String>? = nil,
                    deferredPaths: Set<String> = [], progress: @escaping @Sendable (BackupProgress) -> Void = { _ in }) async throws -> BackupResult {
        try BackupEngine.validate(job)
        let token = try lease(job); defer { release(token) }
        var state = try loaded(job), result = BackupResult()
        let sourceGuard = try LocalRootGuard(job.source, expected: state.sourceIdentity)
        let legacy = state.sourceIdentity == nil || state.remoteRootIdentity == nil
        let remoteRoot = try await verifyRemoteRoot(job, storage: storage, expected: state.remoteRootIdentity)
        try sourceGuard.verify()
        state.sourceIdentity = sourceGuard.identity; state.remoteRootIdentity = remoteRoot
        try Storage.save(state, to: stateURL(job))
        progress(BackupProgress(path: "이전 전송 복구 확인", completed: 0, total: 1))
        try await recover(job, storage: storage)
        progress(BackupProgress(path: "클라우드 변경 목록 확인", completed: 0, total: 1))
        // A missing local watcher checkpoint requires a complete local
        // reconciliation, not a second full cloud crawl. Only the user's
        // explicit full inspection discards the remote delta cursor.
        let index = try await storage.inventory(root: job.cloudFolderID!, previous: forceContentVerification ? nil : state.inventory)
        state.inventory = index
        // Persist the cursor together with the full remote index before processing files.
        try Storage.save(state, to: stateURL(job))
        let groups = try index.groupsByPath()
        let listed = groups.compactMapValues { $0.sorted { $0.id < $1.id }.first }, source = BackupEngine.canonical(job.source)
        let remote: [String: RemoteItem]
        if storage.provider == .dropbox {
            var folded: [String: RemoteItem] = [:]
            for (path, item) in listed { folded[path.lowercased()] = item }
            remote = folded
        } else { remote = listed }
        func entry(_ path: String) -> RemoteItem? { remote[storage.provider == .dropbox ? path.lowercased() : path] }
        func group(_ path: String) -> [RemoteItem] {
            if storage.provider == .dropbox { return groups.first { $0.key.caseInsensitiveCompare(path) == .orderedSame }?.value ?? [] }
            return groups[path] ?? []
        }
        func dirty(_ path: String) -> Bool {
            changedPaths?.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") } == true
        }
        func canReuse(_ path: String, file: URL, stamp: FileStamp) throws -> Bool {
            guard !forceContentVerification, !dirty(path),
                  let prior = state.files[path], prior.verificationVersion == 1,
                  prior.source == stamp, let identity = prior.sourceIdentity,
                  try FileComparisons.identity(file) == identity else { return false }
            let currentGroup = group(path).sorted { $0.id < $1.id }
            if currentGroup.count > 1 {
                guard let verified = prior.verifiedDuplicates?.sorted(by: { $0.id < $1.id }) else { return false }
                return currentGroup == verified && prior.verifiedRemote == currentGroup.first
            }
            guard let verified = prior.verifiedRemote, let current = entry(path) else { return false }
            if current == verified { return true }
            guard current.id == verified.id, current.parent == verified.parent, current.name == verified.name,
                  current.folder == verified.folder, current.size == verified.size,
                  current.modified == verified.modified, current.created == verified.created else { return false }
            if current.hashKind == "sha256", let hash = current.hash, !hash.isEmpty, hash == prior.sourceSHA256 { return true }
            return current.hashKind == verified.hashKind && current.hash != nil && current.hash?.isEmpty == false && current.hash == verified.hash
        }
        let scannedFiles: [String: FileStamp]
        if let changedPaths, !fullScan, !legacy, !MassChanges.blocked(directory: dataDirectory, job: job), !state.files.isEmpty { scannedFiles = try SourceScanner.reconcile(root: source, known: state.files.mapValues(\.source), changed: changedPaths) }
        else { scannedFiles = try SourceScanner.files(source) }
        let excluded = Set(scannedFiles.keys).union(state.files.keys).filter { CloudPathPolicy.isExcluded($0, provider: storage.provider) }
        result.evaluatedPaths.formUnion(excluded); result.skipped += excluded.count
        let files = scannedFiles.filter { !CloudPathPolicy.isExcluded($0.key, provider: storage.provider) }
        if storage.provider == .dropbox, Set(files.keys.map { $0.lowercased() }).count != files.count { throw BackupError.unsafe("원본에 대소문자만 다른 파일이 있습니다. Dropbox는 두 파일을 구분할 수 없습니다.") }
        let massPrior = state.files.filter { $0.value.verificationVersion == 1 }.mapValues(\.source)
        try MassChanges.check(directory: dataDirectory, job: job, baseline: massPrior.count,
                              changes: MassChanges.differences(prior: massPrior, current: files, side: "원본", deletion: job.mirrorDeletes).filter { !deferredPaths.contains($0.path) }, roots: sourceGuard.identity + "|" + remoteRoot)
        // Include removed paths that never had a successful manifest entry (for stale conflict/wait cleanup).
        result.evaluatedPaths.formUnion((changedPaths ?? []).filter { !deferredPaths.contains($0) })
        let paths = try files.keys.filter { path in
            guard !deferredPaths.contains(path) else { return false }
            if group(path).count > 1, let stamp = files[path] {
                let file = try SourceScanner.file(source, path: path)
                if try canReuse(path, file: file, stamp: stamp) { return false }
            }
            guard let changedPaths, !fullScan, !legacy else { return true }
            return group(path).count > 1 || state.files[path]?.verificationVersion != 1 || entry(path)?.revision != state.files[path]?.remote.revision || entry(path)?.id != state.files[path]?.remote.id || changedPaths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.isEmpty }
        }.sorted()
        struct Candidate: Sendable { var file: URL; var path: String; var stamp: FileStamp; var previous: RemoteItem?; var offset: Int }
        var candidates: [Candidate] = []
        for (offset, path) in paths.enumerated() {
            let timing = OperationLog.measure("file.total", path: path); defer { timing.end() }
            result.evaluatedPaths.insert(path)
            try Task.checkCancellation(); progress(BackupProgress(path: path, completed: offset, total: paths.count))
            do {
                try sourceGuard.verify()
                let file = try SourceScanner.file(source, path: path), stamp = files[path]!
                if try canReuse(path, file: file, stamp: stamp) {
                    guard try FileStamp(file) == stamp,
                          try FileComparisons.identity(file) == state.files[path]?.sourceIdentity else {
                        throw BackupError.fileBusy("빠른 비교 중 원본이 변경되었습니다.")
                    }
                    try sourceGuard.verify()
                    progress(BackupProgress(path: path, completed: offset, total: paths.count, stage: "저장된 검증 기록으로 빠른 비교"))
                    result.skipped += 1; continue
                }
                let inspection = try await RemoteDuplicates.inspect(path: path, root: job.cloudFolderID!, storage: storage)
                if !inspection.groups.isEmpty || inspection.candidates.count > 1 {
                    var identical = !inspection.candidates.isEmpty
                    for item in inspection.candidates {
                        if item.folder || item.hash == nil || item.size != stamp.size { identical = false; break }
                        if try ContentHash.compute(file, kind: item.hashKind ?? "") != item.hash { identical = false; break }
                    }
                    let fresh = try await RemoteDuplicates.inspect(path: path, root: job.cloudFolderID!, storage: storage)
                    guard identical, fresh.candidates == inspection.candidates, fresh.groups == inspection.groups, try FileStamp(file) == stamp else {
                        result.issues.append(BackupIssue(jobID: job.id, path: path, reason: "클라우드 중복 사본의 내용이 다릅니다. 문제 해결에서 사본을 보존하며 정리하세요.", conflict: true, source: stamp, backup: inspection.selected?.stamp)); continue
                    }
                    let verified = inspection.candidates.sorted { $0.id < $1.id }
                    if let selected = verified.first {
                        state.files[path] = Record(source: stamp, remote: selected, verificationVersion: 1,
                                                   sourceIdentity: try FileComparisons.identity(file), verifiedRemote: selected,
                                                   verifiedDuplicates: verified)
                    }
                    result.skipped += 1; continue
                }
                if let existing = entry(path) {
                    progress(BackupProgress(path: path, completed: offset, total: paths.count, stage: "클라우드 파일 내용 동일 여부 검증"))
                    if let hash = existing.hash, let kind = existing.hashKind, existing.size == stamp.size, try ContentHash.compute(file, kind: kind) == hash {
                        guard try FileStamp(file) == stamp else { throw BackupError.fileBusy("파일 비교 중 원본이 변경되었습니다.") }
                        try sourceGuard.verify()
                        state.files[path] = Record(source: stamp, remote: existing, verificationVersion: 1,
                                                   sourceIdentity: try FileComparisons.identity(file), verifiedRemote: existing,
                                                   sourceSHA256: existing.hashKind == "sha256" ? existing.hash : nil)
                        result.skipped += 1; continue
                    }
                    if existing.modified.timeIntervalSince(stamp.modified) >= -(storage.provider == .dropbox ? 1 : 0.001) {
                        result.issues.append(BackupIssue(jobID: job.id, path: path, reason: existing.modified > stamp.modified ? "클라우드 백업이 원본보다 최신입니다." : "수정 시간이 같지만 내용이 다릅니다.", conflict: true, source: stamp, backup: existing.stamp, remoteRevision: existing.revision, remoteID: existing.id)); continue
                    }
                }
                candidates.append(Candidate(file: file, path: path, stamp: stamp, previous: entry(path), offset: offset))
            } catch is CancellationError { throw CancellationError() }
            catch { OperationLog.event("file.error", "cloud", path: path, error: error); result.issues.append(FileAccess.issue(error, jobID: job.id, path: path)) }
        }
        var next = 0
        while next < candidates.count {
            try Task.checkCancellation()
            let first = candidates[next]
            let width = storage.provider == .googleDrive && first.stamp.size <= 5 * 1024 * 1024 && next + 1 < candidates.count && candidates[next + 1].stamp.size <= 5 * 1024 * 1024 ? 2 : 1
            var prepared: [(Candidate, PreparedUpload)] = []
            for candidate in candidates[next..<next + width] {
                do {
                    // Folder creation and snapshots are serial; only immutable staging uploads run in parallel.
                    let upload = try await prepare(file: candidate.file, path: candidate.path, stamp: candidate.stamp, job: job, storage: storage)
                    prepared.append((candidate, upload))
                } catch is CancellationError { throw CancellationError() }
                catch { OperationLog.event("file.error", "cloud", path: candidate.path, error: error); result.issues.append(FileAccess.issue(error, jobID: job.id, path: candidate.path)) }
            }
            next += width
            let total = paths.count
            try await withThrowingTaskGroup(of: (Candidate, PreparedUpload, Result<RemoteItem, Error>).self) { group in
                for (candidate, upload) in prepared {
                    group.addTask {
                        do {
                            let staged = try await Self.upload(upload, storage: storage, progress: { stage, bytes in
                                progress(BackupProgress(path: candidate.path, completed: candidate.offset, total: total, size: candidate.stamp.size, transferred: bytes, stage: stage))
                            })
                            return (candidate, upload, .success(staged))
                        } catch is CancellationError { throw CancellationError() }
                        catch { return (candidate, upload, .failure(error)) }
                    }
                }
                for try await (candidate, upload, outcome) in group {
                    try Task.checkCancellation()
                    do {
                        let staged = try outcome.get()
                        let uploaded = try await commit(upload, staged: staged, previous: candidate.previous, job: job, storage: storage, progress: { stage, bytes in
                            progress(BackupProgress(path: candidate.path, completed: candidate.offset, total: total, size: candidate.stamp.size, transferred: bytes, stage: stage))
                        })
                        state.files[candidate.path] = Record(source: candidate.stamp, remote: uploaded, verificationVersion: 1,
                                                             sourceIdentity: upload.sourceIdentity, verifiedRemote: uploaded, sourceSHA256: upload.digest)
                        result.copied += 1
                        try Storage.save(state, to: stateURL(job))
                    } catch is CancellationError { throw CancellationError() }
                    catch { OperationLog.event("file.error", "cloud", path: candidate.path, error: error); result.issues.append(FileAccess.issue(error, jobID: job.id, path: candidate.path)) }
                }
            }
        }
        if job.mirrorDeletes {
            for path in state.files.keys.sorted() where files[path] == nil && !deferredPaths.contains(path) && !CloudPathPolicy.isExcluded(path, provider: storage.provider) {
                result.evaluatedPaths.insert(path)
                try Task.checkCancellation()
                do {
                    guard state.files[path]?.verificationVersion == 1 else {
                        throw BackupError.unsafe("이전 버전 기록의 원본을 재확인하지 못해 클라우드 자동 삭제를 보류합니다. 파일 비교에서 확인하세요.")
                    }
                    guard try sourceGuard.confirmedMissing(path) else { continue }
                    let duplicateCheck = try await RemoteDuplicates.inspect(path: path, root: job.cloudFolderID!, storage: storage)
                    guard duplicateCheck.groups.isEmpty, duplicateCheck.candidates.count <= 1 else { throw BackupError.unsafe("중복 사본이 있어 자동 삭제를 보류합니다.") }
                    if let previous = entry(path) {
                        _ = try await fresh(previous, storage: storage)
                        let archive = try await archiveLocation(previous, path: path, root: job.cloudFolderID!, storage: storage)
                        _ = try await verifyRemoteRoot(job, storage: storage, expected: state.remoteRootIdentity)
                        _ = try await fresh(previous, storage: storage)
                        guard try sourceGuard.confirmedMissing(path) else { continue }
                        _ = try await storage.move(previous, name: "payload", parent: archive)
                        result.removed += 1
                    }
                    try sourceGuard.verify()
                    state.files.removeValue(forKey: path); try Storage.save(state, to: stateURL(job))
                } catch { result.issues.append(FileAccess.issue(error, jobID: job.id, path: path)) }
            }
        }
        try sourceGuard.verify()
        try Storage.save(state, to: stateURL(job))
        progress(BackupProgress(path: "완료", completed: paths.count, total: paths.count)); return result
    }
    public func resolve(_ issue: BackupIssue, job: BackupJob, storage: any RemoteStorage, action: ConflictAction) async throws {
        guard action == .overwrite || action == .keepBoth else { throw BackupError.unsafe("파일 비교 화면에서 처리를 선택하세요.") }
        let token = try lease(job); defer { release(token) }
        let stateBefore = try loaded(job)
        let sourceGuard = try LocalRootGuard(job.source, expected: stateBefore.sourceIdentity)
        _ = try await verifyRemoteRoot(job, storage: storage, expected: stateBefore.remoteRootIdentity)
        try sourceGuard.verify()
        try await recover(job, storage: storage)
        guard let id = issue.remoteID, let previous = try await storage.metadata(id), previous.revision == issue.remoteRevision else { throw BackupError.unsafe("충돌 후 클라우드 파일이 변경되었습니다. 다시 검사하세요.") }
        let file = try SourceScanner.file(BackupEngine.canonical(job.source), path: issue.path), stamp = try FileStamp(file)
        guard stamp == issue.source else { throw BackupError.unsafe("충돌 후 원본이 변경되었습니다. 다시 검사하세요.") }
        let uploaded = try await publish(file: file, path: issue.path, stamp: stamp, previous: previous, job: job, storage: storage, keepBoth: action == .keepBoth)
        var state = try loaded(job); state.files[issue.path] = Record(source: stamp, remote: uploaded, verificationVersion: 1,
                                                                      sourceIdentity: try FileComparisons.identity(file), verifiedRemote: uploaded)
        try Storage.save(state, to: stateURL(job))
    }
    public func prepareSync(_ job: BackupJob, storage: any RemoteStorage) async throws {
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        let token = try lease(job); defer { release(token) }; try await recover(job, storage: storage)
    }
    public func apply(_ comparison: FileComparison, action: ConflictAction, storage: any RemoteStorage, local: BackupEngine) async throws {
        let job = comparison.job
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        let token = try lease(job); defer { release(token) }
        try await recover(job, storage: storage)
        guard comparison.allows(action) else { throw BackupError.unsafe("선택한 처리를 적용할 수 없습니다.") }
        if action == .ignore { return }
        try await FileComparisons.verify(comparison, job: job, storage: storage)
        if action == .normalizeDuplicates {
            try await RemoteDuplicates.preserve(comparison.duplicates, root: job.cloudFolderID!, storage: storage); return
        }
        guard comparison.duplicates.isEmpty, comparison.candidates.count <= 1 else { throw BackupError.unsafe("중복 이름 정리를 먼저 적용하세요. 모든 사본은 보존됩니다.") }
        if action == .useBackup {
            guard let item = comparison.remote else { throw BackupError.unsafe("백업 파일이 없습니다.") }
            let url = dataDirectory.appendingPathComponent("cloud/downloads/" + UUID().uuidString)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: url) }
            try await storage.download(item, to: url)
            try ContentHash.verify(item, file: url)
            try fm.setAttributes([.modificationDate: item.modified], ofItemAtPath: url.path)
            try await FileComparisons.verify(comparison, job: job, storage: storage)
            try await local.installDownload(url, comparison: comparison)
        } else {
            let file = try SourceScanner.file(BackupEngine.canonical(job.source), path: comparison.path)
            let prepared = try await prepare(file: file, path: comparison.path, stamp: comparison.source!.stamp, job: job, storage: storage)
            let staged = try await Self.upload(prepared, storage: storage, progress: { _, _ in })
            _ = try await commit(prepared, staged: staged, previous: comparison.remote, job: job, storage: storage, keepBoth: action == .keepBoth, comparison: comparison)
        }
    }
    public func changeStructure(_ comparison: FileComparison, forward: Bool, deleting: Bool, storage: any RemoteStorage, local: BackupEngine) async throws {
        try Task.checkCancellation()
        let job = comparison.job
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        let token = try lease(job); defer { release(token) }
        try await recover(job, storage: storage)
        try await FileComparisons.verify(comparison, job: job, storage: storage)
        guard comparison.duplicates.isEmpty, comparison.candidates.count <= 1 else { throw BackupError.unsafe("중복 경로는 자동 변경하지 않습니다.") }
        if !forward { try await local.changeStructure(comparison, forward: false, deleting: deleting); return }
        if deleting, let item = comparison.remote {
            if item.folder, !(try await storage.children(item.locator)).isEmpty { throw BackupError.unsafe("폴더에 남은 항목이 있어 삭제를 보류합니다.") }
            let parent = try await archiveLocation(item, path: comparison.path, root: job.cloudFolderID!, storage: storage)
            try await FileComparisons.verify(comparison, job: job, storage: storage)
            _ = try await storage.move(item, name: "payload", parent: parent)
        } else if !deleting {
            _ = try await storage.folder(path: comparison.path, root: job.cloudFolderID!)
        }
    }
    private func trashEntries(_ job: BackupJob, storage: any RemoteStorage) async throws -> [(TrashItem, RemoteItem, RemoteItem)] {
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        let roots = try await storage.children(job.cloudFolderID!).filter { $0.name == ".safesync-trash" && $0.folder }
        guard roots.count <= 1 else { throw BackupError.unsafe("클라우드 휴지통이 중복되었습니다.") }
        guard let root = roots.first else { return [] }
        var result: [(TrashItem, RemoteItem, RemoteItem)] = []
        for folder in try await storage.children(root.locator) where folder.folder {
            let children = try await storage.children(folder.locator)
            if let metadata = children.first(where: { $0.name == "metadata.json" }), let payload = children.first(where: { $0.name == "payload" }) {
                guard metadata.size < 1024 * 1024 else { throw BackupError.unsafe("휴지통 메타데이터가 너무 큽니다.") }
                let item = try JSONDecoder().decode(TrashItem.self, from: await storage.download(metadata))
                guard item.id.uuidString.lowercased() == folder.name.lowercased(), item.size == payload.size else { throw BackupError.unsafe("클라우드 휴지통 기록이 파일과 일치하지 않습니다.") }
                result.append((item, payload, folder))
            }
        }
        return result.sorted { $0.0.deletedAt > $1.0.deletedAt }
    }
    public func listTrash(_ job: BackupJob, storage: any RemoteStorage) async throws -> [TrashItem] { try await trashEntries(job, storage: storage).map { $0.0 } }
    public func verifyBackup(_ job: BackupJob, storage: any RemoteStorage, progress: @Sendable (RestoreCheckRow) -> Void = { _ in }) async throws -> [RestoreCheckRow] {
        let token = try lease(job); defer { release(token) }
        let state = try loaded(job); _ = try await verifyRemoteRoot(job, storage: storage, expected: state.remoteRootIdentity)
        let index = try await storage.inventory(root: job.cloudFolderID!, previous: state.inventory), raw = try index.groupsByPath()
        var groups: [String:[RemoteItem]] = [:]
        for (path,items) in raw { groups[storage.provider == .dropbox ? path.lowercased() : path, default: []] += items }
        var rows: [RestoreCheckRow] = []
        for (path,record) in state.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation(); let row: RestoreCheckRow
            do {
                let candidates = groups[storage.provider == .dropbox ? path.lowercased() : path] ?? []
                guard candidates.count == 1, let current = candidates.first, !current.folder else { throw BackupError.unsafe("백업 파일이 없거나 같은 이름의 사본이 여러 개입니다.") }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-restore-check-\(UUID())")
                try fm.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? fm.removeItem(at: folder) }
                let local = folder.appendingPathComponent("payload"); try await storage.download(current, to: local); try ContentHash.verify(current, file: local); _ = try await fresh(current, storage: storage)
                let expected = record.sourceSHA256 ?? record.verifiedRemote?.hash
                let kind = record.sourceSHA256 != nil ? "sha256" : record.verifiedRemote?.hashKind
                if let expected, let kind { let digest = try ContentHash.compute(local, kind: kind); row = RestoreCheckRow(path: path, length: current.size, status: digest == expected ? "정상" : "실패", detail: digest == expected ? "임시 복원 내용이 성공 백업 체크섬과 일치합니다." : "마지막 성공 백업과 내용이 다릅니다.") }
                else { row = RestoreCheckRow(path: path, length: current.size, status: "기준 없음", detail: "임시 복원은 가능하지만 이전 성공 체크섬 기준이 없습니다.") }
            } catch is CancellationError { throw CancellationError() }
            catch { if NetworkFailurePolicy.isTransient(error) || error is APIError { throw error }; row = RestoreCheckRow(path: path, length: record.source.size, status: "실패", detail: error.localizedDescription) }
            rows.append(row); progress(row)
        }
        _ = try await verifyRemoteRoot(job, storage: storage, expected: state.remoteRootIdentity); return rows
    }
    private func verifyEntry(_ saved: TrashItem, payload: RemoteItem, selected: TrashItem, storage: any RemoteStorage) async throws -> Bool {
        try FileComparisons.validatePath(saved.path)
        guard saved.id == selected.id, saved.path == selected.path, saved.size == selected.size, saved.expectedHash == selected.expectedHash else { throw BackupError.unsafe("휴지통 기록이 바뀌었습니다. 다시 불러오세요.") }
        _ = try await fresh(payload, storage: storage)
        if payload.folder { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-restore-check-\(UUID())")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? fm.removeItem(at: folder) }
        let local = folder.appendingPathComponent("payload")
        try await storage.download(payload, to: local); try ContentHash.verify(payload, file: local)
        guard try FileStamp(local).size == saved.size else { throw BackupError.unsafe("보관 파일 크기가 다릅니다. 복원을 중단했습니다.") }
        _ = try await fresh(payload, storage: storage)
        guard let expected = saved.expectedHash, let kind = saved.hashKind else { return false }
        guard ["sha256", "md5", "dropbox"].contains(kind), try ContentHash.compute(local, kind: kind) == expected else { throw BackupError.unsafe("보관 당시 체크섬과 다릅니다. 복원을 중단했습니다.") }
        return true
    }
    public func verifyTrash(_ item: TrashItem, job: BackupJob, storage: any RemoteStorage) async throws -> Bool {
        let token = try lease(job); defer { release(token) }
        guard let (saved,payload,_) = try await trashEntries(job, storage: storage).first(where: { $0.0.id == item.id }) else { throw BackupError.unsafe("검증할 파일을 찾을 수 없습니다.") }
        return try await verifyEntry(saved, payload: payload, selected: item, storage: storage)
    }
    public func restore(_ items: [TrashItem], job: BackupJob, storage: any RemoteStorage) async throws {
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        let token = try lease(job); defer { release(token) }
        try await recover(job, storage: storage)
        guard Set(items.map(\.path)).count == items.count else { throw BackupError.unsafe("같은 경로는 한 번에 한 버전만 복구하세요.") }
        let entries = try await trashEntries(job, storage: storage)
        for item in items {
            guard !item.path.hasPrefix("/"), !item.path.split(separator: "/").contains(".."), item.path.split(separator: "/").first?.hasPrefix(".safesync-") != true else { throw BackupError.unsafe("안전하지 않은 휴지통 복구 경로입니다.") }
            guard let (saved, payload, originalFolder) = entries.first(where: { $0.0.id == item.id }) else { throw BackupError.unsafe("복구 파일을 찾을 수 없습니다.") }
            _ = try await verifyEntry(saved, payload: payload, selected: item, storage: storage)
            let parent = try await storage.folder(path: (item.path as NSString).deletingLastPathComponent, root: job.cloudFolderID!), name = (item.path as NSString).lastPathComponent
            let matches = try await storage.children(parent).filter { $0.name == name }
            guard matches.count <= 1 else { throw BackupError.unsafe("복구 위치에 파일 이름이 중복되었습니다.") }
            let previous = matches.first
            if payload.folder {
                guard previous == nil, let checked = try await storage.metadata(payload.id), checked == payload else { throw BackupError.unsafe("복구할 폴더 또는 복구 위치가 바뀌었습니다. 기존 폴더는 덮어쓰지 않습니다.") }
                let moved = try await storage.move(payload, name: name, parent: parent)
                guard moved.id == payload.id, moved.folder else { throw BackupError.unsafe("폴더 복구 결과를 확인하세요.") }
                try await storage.remove(originalFolder); continue
            }
            var archive: String?
            if let previous { archive = try await archiveLocation(previous, path: item.path, root: job.cloudFolderID!, storage: storage) }
            let tx = Transaction(path: item.path, parent: parent, name: name, staged: payload, previous: previous, archiveParent: archive, archiveName: "payload")
            let journal = transactionDirectory(job).appendingPathComponent("\(UUID()).json")
            try Storage.save(tx, to: journal); _ = try await finish(tx, storage: storage); try fm.removeItem(at: journal)
            try await storage.remove(originalFolder)
        }
    }
    public func deleteTrash(_ items: [TrashItem], job: BackupJob, storage: any RemoteStorage) async throws {
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        let token = try lease(job); defer { release(token) }
        try await recover(job, storage: storage)
        let entries = try await trashEntries(job, storage: storage)
        for item in items {
            guard let entry = entries.first(where: { $0.0.id == item.id }) else { continue }
            try await storage.remove(entry.2)
        }
    }
    public func pruneTrash(_ job: BackupJob, storage: any RemoteStorage, retentionDays: Int, now: Date = Date()) async throws -> Int {
        if let google = storage as? GoogleDriveStorage { try await google.validateJobAccess(job) }
        guard retentionDays >= 1 else { throw BackupError.unsafe("보관기간은 1일 이상이어야 합니다.") }
        let token = try lease(job); defer { release(token) }
        try await recover(job, storage: storage)
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86400)
        let old = try await trashEntries(job, storage: storage).filter { $0.0.deletedAt < cutoff }
        for entry in old { try await storage.remove(entry.2) }
        return old.count
    }

}
