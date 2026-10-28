import Foundation
import SafeSyncCore

enum GoogleTrashChecks {
    static func run() async throws {
        let (root,job,engine,storage) = try CloudChecks.fixture(.googleDrive);defer { try? FileManager.default.removeItem(at:root) }
        try CloudChecks.write("original",job:job);_ = try await engine.run(job,storage:storage)
        try CloudChecks.write("second",job:job,time:2000);_ = try await engine.run(job,storage:storage)
        let first = try await engine.listTrash(job,storage:storage);checkEqual(first.count,1)
        let before = await storage.discardedArchives;check(before.isEmpty)
        try await engine.deleteTrash(first,job:job,storage:storage)
        let manuallyRemoved = await storage.discardedArchives;checkEqual(manuallyRemoved.count,1)
        let current = await storage.bytes(name:"a.txt",parent:job.cloudFolderID!);checkEqual(current,Data("second".utf8))
        try CloudChecks.write("third",job:job,time:3000);_ = try await engine.run(job,storage:storage)
        let count = try await engine.pruneTrash(job,storage:storage,retentionDays:100,now:Date().addingTimeInterval(101*86400));checkEqual(count,1)
        let discarded = await storage.discardedArchives;checkEqual(discarded.count,2)
        let remaining = try await engine.listTrash(job,storage:storage);check(remaining.isEmpty)
        let final = await storage.bytes(name:"a.txt",parent:job.cloudFolderID!);checkEqual(final,Data("third".utf8))
        print("PASS Google archive disposal: explicit removal and retention use trash route; current backup stays intact")
    }
}
