import Foundation

public struct ComparedFile: Codable, Equatable, Sendable {
    public var stamp: FileStamp
    public var identity: String
    public var hash: String?
    public var folder: Bool
}
public struct DuplicateGroup: Codable, Equatable, Sendable {
    public var path: String
    public var parent: String
    public var items: [RemoteItem]
}
public struct FileComparison: Sendable {
    public var job: BackupJob
    public var path: String
    public var sourceRoot: String
    public var backupRoot: String
    public var source: ComparedFile?
    public var backup: ComparedFile?
    public var remote: RemoteItem?
    public var duplicates: [DuplicateGroup] = []
    public var candidates: [RemoteItem] = []
    public var sourceError = ""
    public var backupError = ""
    public var waiting = false
    public var readable: Bool { sourceError.isEmpty && backupError.isEmpty }
    public var canForward: Bool { readable && source != nil && source?.folder == false && backup?.folder != true && (job.cloudProvider == nil || backup == nil || remote?.hash != nil) }
    public var canReverse: Bool { readable && backup != nil && backup?.folder == false && source?.folder != true && (job.cloudProvider == nil || remote?.hash != nil) }
    public func allows(_ action: ConflictAction) -> Bool {
        switch action {
        case .overwrite: return canForward
        case .useBackup: return canReverse
        case .keepBoth: return canForward && backup != nil
        case .ignore: return true
        case .normalizeDuplicates: return readable && !duplicates.isEmpty
        }
    }
}
public struct ResolutionDecision: Sendable {
    public var comparison: FileComparison
    public var action: ConflictAction
    public init(_ comparison: FileComparison, action: ConflictAction) { self.comparison = comparison; self.action = action }
}

public enum FileComparisons {
    public static func sameEndpoints(_ a: BackupJob, _ b: BackupJob) -> Bool {
        a.id == b.id && a.source == b.source && a.destination == b.destination && a.cloudProvider == b.cloudProvider &&
        a.cloudAccountID == b.cloudAccountID && a.cloudFolderID == b.cloudFolderID && a.mode == b.mode
    }
    public static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              parts.first?.hasPrefix(".safesync-") != true else { throw BackupError.unsafe("처리할 수 없는 파일 경로입니다: \(path)") }
    }
    public static func identity(_ url: URL) throws -> String {
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = info[.systemNumber] as? NSNumber, let inode = info[.systemFileNumber] as? NSNumber else {
            throw BackupError.unsafe("파일시스템 식별정보를 확인할 수 없습니다: \(url.path)")
        }
        return "\(device):\(inode)"
    }
    public static func local(root: String, path: String) throws -> ComparedFile? {
        try validatePath(path)
        let base = BackupEngine.canonical(root)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &directory), directory.boolValue else { throw BackupError.unsafe("폴더에 연결할 수 없습니다: \(root)") }
        var cursor = base
        for part in path.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            let values: URLResourceValues
            do { values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey]) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return nil }
            guard values.isSymbolicLink != true else { throw BackupError.unsafe("심볼릭 링크는 처리하지 않습니다.") }
        }
        let values = try cursor.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard values.isDirectory == true || values.isRegularFile == true else { throw BackupError.unsafe("일반 파일 또는 폴더가 아닙니다.") }
        let fd = values.isRegularFile == true ? try FileAccess.readLock(cursor) : nil
        defer { if let fd { FileAccess.unlock(fd) } }
        let before = try FileStamp(cursor), id = try identity(cursor)
        let digest = values.isRegularFile == true ? try BackupEngine.hash(cursor) : nil
        guard try FileStamp(cursor) == before, try identity(cursor) == id else { throw BackupError.fileBusy("파일 정보 확인 중 내용이 변경되었습니다.") }
        return ComparedFile(stamp: before, identity: id, hash: digest, folder: values.isDirectory == true)
    }
    public static func localPair(job: BackupJob, path: String) throws -> FileComparison {
        try validatePath(path)
        return FileComparison(job: job, path: path, sourceRoot: try identity(BackupEngine.canonical(job.source)),
            backupRoot: try identity(BackupEngine.canonical(job.destination)), source: try local(root: job.source, path: path), backup: try local(root: job.destination, path: path))
    }
    public static func read(job: BackupJob, path: String, storage: (any RemoteStorage)? = nil) async throws -> FileComparison {
        try validatePath(path)
        if storage == nil {
            return await Task.detached {
                var snapshot = FileComparison(job: job, path: path, sourceRoot: "", backupRoot: "")
                do { snapshot.sourceRoot = try identity(BackupEngine.canonical(job.source)); snapshot.source = try local(root: job.source, path: path) }
                catch { snapshot.sourceError = error.localizedDescription; snapshot.waiting = FileAccess.isBusy(error) }
                do { snapshot.backupRoot = try identity(BackupEngine.canonical(job.destination)); snapshot.backup = try local(root: job.destination, path: path) }
                catch { snapshot.backupError = error.localizedDescription; snapshot.waiting = snapshot.waiting || FileAccess.isBusy(error) }
                return snapshot
            }.value
        }
        var snapshot = FileComparison(job: job, path: path, sourceRoot: "", backupRoot: "")
        do {
            let side = try await Task.detached { (try identity(BackupEngine.canonical(job.source)), try local(root: job.source, path: path)) }.value
            snapshot.sourceRoot = side.0; snapshot.source = side.1
        } catch { snapshot.sourceError = error.localizedDescription; snapshot.waiting = FileAccess.isBusy(error) }
        do {
            let storage = storage!
            let plan = try await RemoteDuplicates.inspect(path: path, root: job.cloudFolderID!, storage: storage)
            snapshot.remote = plan.selected; snapshot.duplicates = plan.groups; snapshot.candidates = plan.candidates
            if let item = plan.selected { snapshot.backup = ComparedFile(stamp: item.stamp, identity: item.id, hash: item.hash, folder: item.folder) }
            snapshot.backupRoot = plan.root.id
        } catch { snapshot.backupError = error.localizedDescription; snapshot.waiting = snapshot.waiting || FileAccess.isBusy(error) }
        return snapshot
    }
    public static func verify(_ expected: FileComparison, job: BackupJob, storage: (any RemoteStorage)? = nil) async throws {
        guard sameEndpoints(expected.job, job) else { throw BackupError.unsafe("비교 후 작업의 위치·계정·모드가 바뀌었습니다. 다시 확인하세요.") }
        let current = try await read(job: job, path: expected.path, storage: storage)
        try verify(expected, current: current)
    }
    public static func verify(_ expected: FileComparison, current: FileComparison) throws {
        guard sameEndpoints(expected.job, current.job), expected.path == current.path, expected.readable, current.readable,
              expected.sourceRoot == current.sourceRoot, expected.backupRoot == current.backupRoot,
              expected.source == current.source, expected.backup == current.backup, expected.remote == current.remote,
              expected.duplicates == current.duplicates, expected.candidates == current.candidates else {
            throw BackupError.unsafe("비교 후 파일·중복 사본 또는 연결 위치가 변경되었습니다. 덮어쓰지 않았습니다. 정보를 다시 확인하세요.")
        }
    }
}

public enum RemoteDuplicates {
    public struct Inspection: Sendable { public var root: RemoteItem; public var selected: RemoteItem?; public var groups: [DuplicateGroup]; public var candidates: [RemoteItem] }
    public static func inspect(path: String, root: String, storage: any RemoteStorage) async throws -> Inspection {
        try FileComparisons.validatePath(path)
        guard let rootItem = try await storage.metadata(root), rootItem.folder else { throw BackupError.unsafe("백업 루트 폴더에 접근할 수 없습니다.") }
        var parents = [rootItem], selectedParent = rootItem, groups: [DuplicateGroup] = [], candidates: [RemoteItem] = [], relative = ""
        for (offset, component) in path.split(separator: "/").enumerated() {
            relative = relative.isEmpty ? String(component) : relative + "/" + component
            var next: [RemoteItem] = [], chosen: [RemoteItem] = []
            for parent in parents {
                guard parent.folder else { throw BackupError.unsafe("폴더 경로에 일반 파일이 있습니다.") }
                let matches = try await storage.children(parent.locator).filter {
                    storage.provider == .dropbox ? $0.name.caseInsensitiveCompare(String(component)) == .orderedSame : $0.name == String(component)
                }.sorted { $0.id < $1.id }
                if parent.id == selectedParent.id { chosen = matches }
                next += matches
            }
            guard next.count <= 1000 else { throw BackupError.unsafe("중복 사본이 너무 많습니다. 폴더를 먼저 정리하세요.") }
            if Set(next.map(\.folder)).count > 1 { throw BackupError.unsafe("파일과 폴더가 섞인 중복 경로입니다. 각각 다른 이름으로 보존한 뒤 다시 비교하세요.") }
            if chosen.count > 1 { groups.append(DuplicateGroup(path: relative, parent: selectedParent.locator, items: chosen)) }
            guard let selected = chosen.first else { return Inspection(root: rootItem, selected: nil, groups: groups, candidates: []) }
            selectedParent = selected; parents = next
            if offset == path.split(separator: "/").count - 1 { candidates = next.sorted { $0.id < $1.id } }
        }
        return Inspection(root: rootItem, selected: selectedParent, groups: groups, candidates: candidates)
    }
    public static func preserve(_ groups: [DuplicateGroup], root: String, storage: any RemoteStorage) async throws {
        for group in groups.sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
            try Task.checkCancellation()
            let fresh = try await inspect(path: group.path, root: root, storage: storage)
            guard let current = fresh.groups.first(where: { $0.path == group.path }), current == group else { throw BackupError.unsafe("확인 후 중복 사본이 변경되었습니다. 이름을 바꾸지 않았습니다.") }
            for extra in group.items.sorted(by: { $0.id < $1.id }).dropFirst() {
                try Task.checkCancellation()
                let before = try await inspect(path: group.path, root: root, storage: storage)
                guard before.selected?.id == group.items.first?.id, before.groups.first(where: { $0.path == group.path })?.parent == group.parent,
                      let item = try await storage.metadata(extra.id), item == extra else { throw BackupError.unsafe("이름 변경 직전 사본 또는 상위 폴더가 바뀌었습니다.") }
                let newName = String(extra.name.prefix(140)) + ".SafeSync-conflict-" + UUID().uuidString
                let moved = try await storage.move(item, name: newName, parent: group.parent)
                guard moved.id == extra.id, moved.name == newName, moved.folder == extra.folder, moved.size == extra.size,
                      moved.hash == extra.hash, moved.hashKind == extra.hashKind else { throw BackupError.unsafe("중복 사본 이름 변경 결과를 확인하세요. 파일은 삭제하지 않았습니다.") }
            }
        }
    }
}
