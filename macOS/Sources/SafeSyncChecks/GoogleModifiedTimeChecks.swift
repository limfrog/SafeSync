import Foundation
import SafeSyncCore

enum GoogleModifiedTimeChecks {
    static func run() async throws {
        for scenario in ["unchanged", "remoteChanged", "noProof", "olderSource"] {
            let (root,job,engine,cloud) = try CloudChecks.fixture(.googleDrive)
            defer { try? FileManager.default.removeItem(at:root) }
            await cloud.setMovedTime(Date(timeIntervalSince1970:9000))
            try CloudChecks.write("original",job:job,time:1000)
            let first = try await engine.run(job,storage:cloud)
            checkEqual(first.copied,1);check(first.issues.isEmpty)
            await cloud.setMovedTime(nil)
            if scenario == "remoteChanged" { await cloud.reviseMetadata() }
            try CloudChecks.write("replacement",job:job,time:scenario == "olderSource" ? 500 : 2000)
            let data = root.appendingPathComponent(scenario == "noProof" ? "new-settings" : "settings")
            let restarted = CloudBackupEngine(dataDirectory:data)
            let second = try await restarted.run(job,storage:cloud)
            if scenario == "unchanged" {
                checkEqual(second.copied,1);check(second.issues.isEmpty)
                let bytes = await cloud.bytes(name:"a.txt",parent:job.cloudFolderID!)
                checkEqual(bytes,Data("replacement".utf8))
                let trash = try await restarted.listTrash(job,storage:cloud);checkEqual(trash.count,1)
                let skipped = try await restarted.run(job,storage:cloud);checkEqual(skipped.skipped,1)
            } else {
                checkEqual(second.copied,0);check(second.issues.contains { $0.conflict })
                let bytes = await cloud.bytes(name:"a.txt",parent:job.cloudFolderID!)
                checkEqual(bytes,Data("original".utf8))
            }
            print("PASS Google old publication timestamp: \(scenario), prior proof and external-change safety")
        }
    }
}
