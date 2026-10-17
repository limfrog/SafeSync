import Foundation
import SafeSyncCore

struct JobListChecks {
    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); fail("Invalid job list was accepted") } catch {}
    }
    static func run() throws {
        var local = BackupJob(); local.name = "한글 작업"; local.source = "/missing/source"; local.destination = "/missing/backup"
        local.scheduled = true; local.scheduleTime = "23:10"; local.paused = true; local.lastScheduledDay = "2026-10-17"
        var cloud = BackupJob(); cloud.name = "Drive"; cloud.source = "/missing/cloud-source"; cloud.destination = "Google Drive API · 시험 폴더"
        cloud.cloudProvider = .googleDrive; cloud.cloudFolderID = "folder-id"; cloud.cloudAccountID = UUID()
        let encoded = try JobListCodec.encode([local, cloud])
        let text = String(decoding: encoded, as: UTF8.self)
        for key in ["cloudAccountID", "lastScheduledDay", "accessToken", "refreshToken", "clientSecret", "manifests"] { checkFalse(text.contains(key)) }
        let document = try JobListCodec.decode(encoded)
        checkEqual(document.Format, "SafeSyncJobList"); checkEqual(document.Version, 1)
        checkEqual(document.Jobs.count, 2); checkEqual(document.Jobs[0].Name, local.name)
        check(document.Jobs[0].Paused); checkEqual(document.Jobs[0].ScheduleTime, "23:10")
        checkEqual(document.Jobs[1].DestinationType, "GoogleDrive")
        print("PASS job list: Windows v1 schema, Korean settings round-trip and credential/runtime exclusion")

        let bom = Data([0xef, 0xbb, 0xbf]) + encoded
        let bomDocument = try JobListCodec.decode(bom); checkEqual(bomDocument.Jobs.count, 2)
        let empty = try JobListCodec.decode(JobListCodec.encode([])); check(empty.Jobs.isEmpty)
        let unknown = try JobListCodec.plan(document, replacing: [])
        check(unknown.reusedIDs.isEmpty); checkEqual(unknown.newJobCount, 2)
        check(unknown.jobs[1].cloudAccountID == nil); check(unknown.jobs[0].lastScheduledDay == nil)
        check(unknown.jobs[0].id != local.id)
        var dropbox = cloud; dropbox.cloudProvider = .dropbox; dropbox.cloudFolderID = ""; dropbox.destination = "Dropbox API · Dropbox"
        let rootDocument = try JobListCodec.decode(JobListCodec.encode([dropbox]))
        let rootPlan = try JobListCodec.plan(rootDocument, replacing: [dropbox])
        checkEqual(rootPlan.jobs[0].cloudFolderID, ""); checkEqual(rootPlan.jobs[0].id, dropbox.id)
        print("PASS job list: Windows UTF-8 BOM, empty array and fresh identities for unknown jobs")

        let identical = try JobListCodec.plan(document, replacing: [local, cloud])
        checkEqual(identical.reusedIDs, Set([local.id, cloud.id])); checkEqual(identical.jobs[1].cloudAccountID, cloud.cloudAccountID)
        checkEqual(identical.jobs[0].lastScheduledDay, local.lastScheduledDay)
        var changed = document; changed.Jobs[0].Destination = "/missing/new-backup"
        let newLocation = try JobListCodec.plan(changed, replacing: [local, cloud])
        check(newLocation.jobs[0].id != local.id); checkEqual(newLocation.newJobCount, 1); checkEqual(newLocation.jobs[1].id, cloud.id)
        print("PASS job list: only unchanged ID/endpoints reuse snapshots, schedule state and local account binding")

        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var jobs = json["Jobs"] as! [[String: Any]]
        jobs[0]["Id"] = "Same-ID"; jobs[1]["Id"] = "same-id"; json["Jobs"] = jobs
        rejected { _ = try JobListCodec.decode(HTTP.json(json)) }
        json["Jobs"] = "bad"; rejected { _ = try JobListCodec.decode(HTTP.json(json)) }
        json["Jobs"] = [NSNull()]; rejected { _ = try JobListCodec.decode(HTTP.json(json)) }
        json["Jobs"] = []; json["Version"] = 2; rejected { _ = try JobListCodec.decode(HTTP.json(json)) }
        rejected { _ = try JobListCodec.decode(Data(repeating: 32, count: JobListCodec.maximumBytes + 1)) }
        var tooMany = document; tooMany.Jobs = (0...1000).map { i in var item = document.Jobs[0]; item.Id = "job-\(i)"; return item }
        rejected { try JobListCodec.validate(tooMany) }
        print("PASS job list: duplicate IDs, malformed arrays, null jobs, unknown version and size/count limits rejected")

        for field in ["Id", "Source", "DestinationType", "TriggerType", "ScheduleTime", "Paused"] {
            var entry = (try JSONSerialization.jsonObject(with: encoded) as! [String: Any])["Jobs"] as! [[String: Any]]
            entry[0].removeValue(forKey: field)
            rejected { _ = try JobListCodec.decode(HTTP.json(["Format": "SafeSyncJobList", "Version": 1, "Jobs": entry])) }
        }
        var wrong = document; wrong.Jobs[0].Id = "../escape"; rejected { try JobListCodec.validate(wrong) }
        wrong = document; wrong.Jobs[0].Source = "relative"; rejected { try JobListCodec.validate(wrong) }
        wrong = document; wrong.Jobs[0].Destination = "/missing/source/nested"; rejected { try JobListCodec.validate(wrong) }
        wrong = document; wrong.Jobs[0].ScheduleTime = "24:00"; rejected { try JobListCodec.validate(wrong) }
        var invalidBool = (try JSONSerialization.jsonObject(with: encoded) as! [String: Any])["Jobs"] as! [[String: Any]]
        invalidBool[0]["Paused"] = "false"
        rejected { _ = try JobListCodec.decode(HTTP.json(["Format": "SafeSyncJobList", "Version": 1, "Jobs": invalidBool])) }
        print("PASS job list: missing fields, unsafe IDs/paths, nested roots, invalid times and non-boolean flags rejected")

        var windows = document; windows.Jobs = [document.Jobs[0]]
        windows.Jobs[0].Source = "C:\\source"; windows.Jobs[0].Destination = "D:\\backup"
        try JobListCodec.validate(windows)
        rejected { _ = try JobListCodec.plan(windows, replacing: [local]) }
        var overlap = document; overlap.Jobs[1].Source = local.destination + "/child"
        rejected { _ = try JobListCodec.plan(overlap, replacing: []) }
        print("PASS job list: Windows paths require explicit Mac mapping and cross-job source/target overlap is rejected")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSync-list-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("jobs.json"), archive = root.appendingPathComponent("job-list-backups")
        let accountFile = root.appendingPathComponent("accounts.json"), snapshot = root.appendingPathComponent("snapshot.json")
        try Storage.save([local], to: settings)
        let untouched = Data("private-placeholder".utf8); try untouched.write(to: accountFile); try untouched.write(to: snapshot)
        let plan = try JobListCodec.plan(document, replacing: [local])
        let backup = try JobListFiles.replace(plan, current: [local], settingsURL: settings, backupDirectory: archive)
        let before = try JobListFiles.read(backup); checkEqual(before.Jobs.count, 1); checkEqual(before.Jobs[0].Id.lowercased(), local.id.uuidString.lowercased())
        let committed = try Storage.load([BackupJob].self, from: settings); checkEqual(committed.count, 2)
        checkEqual(try Data(contentsOf: accountFile), untouched); checkEqual(try Data(contentsOf: snapshot), untouched)
        print("PASS job list: previous list archived before atomic replacement; accounts and snapshots unchanged")

        let previousBytes = try Data(contentsOf: settings)
        let blockedArchive = root.appendingPathComponent("archive-is-a-file"); try Data("blocked".utf8).write(to: blockedArchive)
        rejected { _ = try JobListFiles.replace(plan, current: committed, settingsURL: settings, backupDirectory: blockedArchive) }
        checkEqual(try Data(contentsOf: settings), previousBytes)
        let notAFile = root.appendingPathComponent("commit-is-a-directory"); try FileManager.default.createDirectory(at: notAFile, withIntermediateDirectories: true)
        rejected { _ = try JobListFiles.replace(plan, current: committed, settingsURL: notAFile, backupDirectory: archive) }
        checkEqual(try Data(contentsOf: settings), previousBytes)
        let emptyPlan = try JobListCodec.plan(empty, replacing: committed)
        let secondBackup = try JobListFiles.replace(emptyPlan, current: committed, settingsURL: settings, backupDirectory: archive)
        let restoredPrevious = try JobListFiles.read(secondBackup); checkEqual(restoredPrevious.Jobs.count, 2)
        let cleared = try Storage.load([BackupJob].self, from: settings); check(cleared.isEmpty)
        print("PASS job list: archive/commit failure preserves existing settings; empty import keeps a recoverable prior list")
    }
}
