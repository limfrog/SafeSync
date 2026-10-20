import Foundation
import SafeSyncCore

struct DropboxMetadataChecks {
    private struct LegacyTransaction: Codable {
        var path: String; var parent: String; var name: String; var staged: RemoteItem
        var previous: RemoteItem?; var archiveParent: String?; var archiveName: String?
    }
    static func run() async throws {
        do {
            let (root, job, engine, remote) = try CloudChecks.fixture(.dropbox)
            defer { try? FileManager.default.removeItem(at: root) }
            try CloudChecks.write("ordinary user data", job: job)
            let meta = URL(fileURLWithPath: job.source).appendingPathComponent(".DS_Store")
            try Data("Finder metadata".utf8).write(to: meta)
            let staged = try await remote.upload(file: meta, name: "legacy-staged", parent: "", modified: Date(), resumeKey: "legacy", progress: { _, _ in })
            let journal = root.appendingPathComponent("settings/cloud/transactions/\(job.id)/legacy.json")
            try Storage.save(LegacyTransaction(path: ".DS_Store", parent: "", name: ".DS_Store", staged: staged), to: journal)
            let first = try await engine.run(job, storage: remote)
            check(first.issues.isEmpty); checkEqual(first.copied, 1); check(first.evaluated(".DS_Store"))
            check(FileManager.default.fileExists(atPath: meta.path))
            checkFalse(FileManager.default.fileExists(atPath: journal.path))
            let retained = root.appendingPathComponent("settings/cloud/excluded-transactions/\(job.id)")
            let journals = try FileManager.default.contentsOfDirectory(at: retained, includingPropertiesForKeys: nil)
            checkEqual(journals.count, 1)
            checkEqual(try Storage.load(LegacyTransaction.self, from: journals[0]).staged, staged)
            let stillStaged = await remote.metadata(staged.id); checkEqual(stillStaged, staged)
            let unsupported = await remote.bytes(name: ".DS_Store", parent: ""); check(unsupported == nil)
            let ordinary = await remote.bytes(name: "a.txt", parent: ""); checkEqual(ordinary, Data("ordinary user data".utf8))
            try Data("Finder changes again".utf8).write(to: meta)
            let again = try await engine.run(job, storage: remote)
            check(again.issues.isEmpty); checkEqual(again.copied, 0)
            print("PASS Dropbox reserved metadata and legacy failed publish do not block ordinary backups; source, staged copy and journal preserved")
        }
        do {
            let (root, original, _, remote) = try CloudChecks.fixture(.dropbox)
            defer { try? FileManager.default.removeItem(at: root) }
            var job = original; job.syncMode = .twoWay
            try CloudChecks.write("normal two-way file", job: job)
            for name in [".DS_Store", "DESKTOP.INI", "Thumbs.db"] { try Data("metadata".utf8).write(to: URL(fileURLWithPath: job.source).appendingPathComponent(name)) }
            let sync = SyncCoordinator(dataDirectory: root.appendingPathComponent("sync"))
            let first = try await sync.run(job, storage: remote)
            check(first.issues.isEmpty); checkEqual(first.copied, 1); checkEqual(first.skipped, 3)
            let again = try await sync.run(job, storage: remote)
            check(again.issues.isEmpty); checkEqual(again.copied, 0); checkEqual(again.removed, 0)
            for name in [".DS_Store", "DESKTOP.INI", "Thumbs.db"] { check(FileManager.default.fileExists(atPath: URL(fileURLWithPath: job.source).appendingPathComponent(name).path)) }
            print("PASS Dropbox two-way repeated runs exclude reserved OS metadata without conflicts or local deletion")
        }
        do {
            let (root, job, engine, remote) = try CloudChecks.fixture(.googleDrive)
            defer { try? FileManager.default.removeItem(at: root) }
            let meta = URL(fileURLWithPath: job.source).appendingPathComponent(".DS_Store")
            try Data("Google should still back this up".utf8).write(to: meta)
            let result = try await engine.run(job, storage: remote)
            check(result.issues.isEmpty); checkEqual(result.copied, 1)
            checkFalse(CloudPathPolicy.isExcluded(".git/config", provider: .dropbox))
            print("PASS reserved-name policy is Dropbox-specific and does not exclude arbitrary hidden files")
        }
        do {
            let url = URL(string: "https://api.dropboxapi.com/2/files/move_v2")!
            let data = try HTTP.json(["error_summary": "sensitive path/token must not appear", "error": [".tag": "to", "to": [".tag": "disallowed_name"]]] as [String: Any])
            let error = HTTP.responseError(status: 409, url: url, data: data)
            checkEqual(error.code, "to/disallowed_name"); check(error.summary.contains("파일 이름")); checkFalse(error.localizedDescription.contains("sensitive")); checkFalse(error.summary.contains("변경"))
            let missing = HTTP.responseError(status: 409, url: url, data: try HTTP.json(["error": [".tag": "path", "path": [".tag": "not_found"]]]))
            checkEqual(missing.code, "path/not_found")
            let permission = HTTP.responseError(status: 409, url: url, data: try HTTP.json(["error": [".tag": "to", "to": [".tag": "no_write_permission"]]]))
            check(permission.summary.contains("쓰기 권한")); checkEqual(permission.code, "to/no_write_permission")
            print("PASS Dropbox 409 reserved names, missing paths and write permissions have distinct sanitized messages")
        }
    }
}
