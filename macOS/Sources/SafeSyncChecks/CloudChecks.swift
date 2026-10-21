import Foundation
import SafeSyncCore

actor MemoryCloud: RemoteStorage {
    nonisolated let provider: CloudProvider
    private var items: [String: RemoteItem] = [:]
    private var data: [String: Data] = [:]
    private var counter = 0
    private var rootIdentity: String?
    private var trashUploadHook: (@Sendable () -> Void)?
    func setRootIdentity(_ value: String) { rootIdentity = value }
    func onTrashUpload(_ action: @escaping @Sendable () -> Void) { trashUploadHook = action }
    var uploadDelay: UInt64 = 0
    var activeUploads = 0
    var maximumUploads = 0
    var failName: String?
    func setDelay(_ delay: UInt64) { uploadDelay = delay }
    func setFailName(_ name: String?) { failName = name }
    func peakUploads() -> Int { maximumUploads }
    var corruptUpload = false
    var failPublish = false
    var mutateOnUpload = false
    init(_ provider: CloudProvider) { self.provider = provider }
    func setCorruption(_ value: Bool) { corruptUpload = value }
    func setPublishFailure(_ value: Bool) { failPublish = value }
    func setMutation(_ value: Bool) { mutateOnUpload = value }
    private func location(_ name: String, parent: String, id: String) -> String { provider == .dropbox ? (parent + "/" + name).lowercased() : id }
    func children(_ parent: String) -> [RemoteItem] { items.values.filter { $0.parent == parent } }
    func metadata(_ id: String) -> RemoteItem? { if id == "" || id == "root" { return RemoteItem(id: rootIdentity ?? id, name: "root", parent: "", folder: true, locator: id) }; return items[id] ?? items.values.first { $0.locator == id } }
    func createFolder(name: String, parent: String) -> RemoteItem {
        counter += 1; let id = "id-\(counter)"
        let item = RemoteItem(id: id, name: name, parent: parent, folder: true, revision: String(counter), locator: location(name, parent: parent, id: id))
        items[id] = item; return item
    }
    func upload(file: URL, name: String, parent: String, modified: Date, resumeKey: String, progress: @Sendable (Int64, Int64) -> Void) async throws -> RemoteItem {
        activeUploads += 1; maximumUploads = max(maximumUploads, activeUploads)
        defer { activeUploads -= 1 }
        if name == "metadata.json", let hook = trashUploadHook { trashUploadHook = nil; hook() }
        if uploadDelay > 0 { try await Task.sleep(nanoseconds: uploadDelay) }
        if let failName, resumeKey.contains("|" + failName + "|") { throw BackupError.unsafe("Injected file upload failure") }
        if mutateOnUpload, let old = items.values.first(where: { $0.name == "a.txt" }) {
            mutateOnUpload = false; counter += 1
            var changed = old; changed.revision = "external-\(counter)"; changed.hash = "external"; changed.size = 15; changed.modified = Date()
            items[old.id] = changed; data[old.id] = Data("external change".utf8)
        }
        counter += 1; let id = "id-\(counter)", kind = provider == .dropbox ? "dropbox" : "sha256"
        let item = RemoteItem(id: id, name: name, parent: parent, size: try FileStamp(file).size, modified: modified, hash: corruptUpload ? "bad" : try ContentHash.compute(file, kind: kind), hashKind: kind, revision: String(counter), locator: location(name, parent: parent, id: id))
        items[id] = item; data[id] = try Data(contentsOf: file); return item
    }
    func move(_ item: RemoteItem, name: String, parent: String) throws -> RemoteItem {
        if failPublish && name == "a.txt" { failPublish = false; throw BackupError.unsafe("Injected interrupted publish") }
        guard var updated = items[item.id] else { throw BackupError.unsafe("Missing mock item") }
        if provider == .dropbox, items.values.contains(where: { $0.parent == parent && $0.name == name && $0.id != item.id }) { throw BackupError.unsafe("Mock Dropbox target exists") }
        counter += 1; updated.name = name; updated.parent = parent; updated.revision = String(counter); updated.locator = location(name, parent: parent, id: item.id)
        items[item.id] = updated; return updated
    }
    func remove(_ item: RemoteItem) {
        var pending = [item]
        while let current = pending.popLast() { pending += children(current.locator); items.removeValue(forKey: current.id); data.removeValue(forKey: current.id) }
    }
    func download(_ item: RemoteItem) throws -> Data { guard let bytes = data[item.id] else { throw BackupError.unsafe("Missing mock bytes") }; return bytes }
    func inventory(root: String, previous: RemoteIndex?) -> RemoteIndex {
        var result = RemoteIndex(); result.root = root
        for item in items.values { result.nodes[provider == .dropbox ? item.locator : item.id] = item }
        result.cursor = String(counter); return result
    }
    func bytes(name: String, parent: String) -> Data? { items.values.first { $0.name == name && $0.parent == parent }.flatMap { data[$0.id] } }
}

struct CloudChecks {
    static func fixture(_ provider: CloudProvider) throws -> (URL, BackupJob, CloudBackupEngine, MemoryCloud) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-cloud-test-\(UUID())")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var job = BackupJob(); job.name = "cloud-test"; job.source = source.path; job.destination = "mock cloud"; job.cloudProvider = provider; job.cloudAccountID = UUID(); job.cloudFolderID = provider == .dropbox ? "" : "root"
        return (root, job, CloudBackupEngine(dataDirectory: root.appendingPathComponent("settings")), MemoryCloud(provider))
    }
    static func write(_ text: String, job: BackupJob, time: TimeInterval = 1000) throws {
        let file = URL(fileURLWithPath: job.source).appendingPathComponent("a.txt")
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: file.path)
    }
    static func run() async throws {
        for provider in CloudProvider.allCases {
            let (root, job, engine, cloud) = try fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            try write("first", job: job)
            let first = try await engine.run(job, storage: cloud); checkEqual(first.copied, 1); check(first.issues.isEmpty)
            let skipped = try await engine.run(job, storage: cloud); checkEqual(skipped.skipped, 1)
            try write("second", job: job, time: 2000)
            let second = try await engine.run(job, storage: cloud); checkEqual(second.copied, 1); check(second.issues.isEmpty)
            let trash = try await engine.listTrash(job, storage: cloud); checkEqual(trash.count, 1)
            try await engine.restore(trash, job: job, storage: cloud)
            let restored = await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!); checkEqual(restored, Data("first".utf8))
            let afterRestore = try await engine.listTrash(job, storage: cloud); checkEqual(afterRestore.count, 1)
            print("PASS \(provider.title): copy, skip, overwrite, remote trash and restore")
        }
        for provider in CloudProvider.allCases {
            let (root, job, engine, cloud) = try fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            try write("original", job: job); _ = try await engine.run(job, storage: cloud)
            try write("replacement", job: job, time: 2000); await cloud.setCorruption(true)
            let bad = try await engine.run(job, storage: cloud); checkEqual(bad.copied, 0); checkEqual(bad.issues.count, 1)
            let bytes = await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!); checkEqual(bytes, Data("original".utf8))
            print("PASS \(provider.title): checksum failure preserves original")
        }
        for provider in CloudProvider.allCases {
            let (root, job, engine, cloud) = try fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            try write("original", job: job); _ = try await engine.run(job, storage: cloud)
            try write("replacement", job: job, time: 2000); await cloud.setPublishFailure(true)
            let interrupted = try await engine.run(job, storage: cloud); checkEqual(interrupted.copied, 0); checkEqual(interrupted.issues.count, 1)
            let restarted = CloudBackupEngine(dataDirectory: root.appendingPathComponent("settings"))
            let recovered = try await restarted.run(job, storage: cloud); check(recovered.issues.isEmpty)
            let bytes = await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!); checkEqual(bytes, Data("replacement".utf8))
            let trash = try await restarted.listTrash(job, storage: cloud); checkEqual(trash.count, 1)
            print("PASS \(provider.title): interrupted publish recovers after engine restart")
        }
        for provider in CloudProvider.allCases {
            let (root, job, engine, cloud) = try fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            try write("original", job: job, time: 3000); _ = try await engine.run(job, storage: cloud)
            try write("older source", job: job, time: 1000)
            let conflicted = try await engine.run(job, storage: cloud); checkEqual(conflicted.issues.count, 1); check(conflicted.issues[0].conflict)
            try await engine.resolve(conflicted.issues[0], job: job, storage: cloud, action: .keepBoth)
            let copies = try await cloud.children(job.cloudFolderID!); check(copies.contains { $0.name.contains("SafeSync-conflict") })
            try FileManager.default.removeItem(atPath: URL(fileURLWithPath: job.source).appendingPathComponent("a.txt").path)
            let deleted = try await engine.run(job, storage: cloud); checkEqual(deleted.removed, 1)
            let pruned = try await engine.pruneTrash(job, storage: cloud, retentionDays: 100, now: Date().addingTimeInterval(101 * 86400)); checkEqual(pruned, 1)
            print("PASS \(provider.title): conflict keep-both, deletion and retention cleanup")
        }
        for provider in CloudProvider.allCases {
            let (root, job, engine, cloud) = try fixture(provider); defer { try? FileManager.default.removeItem(at: root) }
            try write("original", job: job); _ = try await engine.run(job, storage: cloud)
            try write("replacement", job: job, time: 2000); await cloud.setMutation(true)
            let raced = try await engine.run(job, storage: cloud); checkEqual(raced.copied, 0); checkEqual(raced.issues.count, 1)
            let bytes = await cloud.bytes(name: "a.txt", parent: job.cloudFolderID!); checkEqual(bytes, Data("external change".utf8))
            print("PASS \(provider.title): remote change during upload is preserved")
        }
        print("10 cloud integration scenarios passed (in-memory providers; live APIs still require account validation)")
    }
}
