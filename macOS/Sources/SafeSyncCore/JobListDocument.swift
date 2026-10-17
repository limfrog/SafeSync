import Foundation

/// The v1 field names and allowlist match Windows SafeSync 1.9.11.
public struct PortableJob: Codable, Sendable {
    public var Id: String
    public var Name: String
    public var Source: String
    public var DestinationType: String
    public var Destination: String
    public var CloudFolderId: String
    public var TriggerType: String
    public var ScheduleTime: String
    public var MirrorDeletes: Bool
    public var Paused: Bool

    public init(_ job: BackupJob) {
        Id = job.id.uuidString; Name = job.name; Source = job.source
        DestinationType = job.cloudProvider == .dropbox ? "Dropbox" : job.cloudProvider == .googleDrive ? "GoogleDrive" : "Local"
        Destination = job.destination
        CloudFolderId = job.cloudProvider == .dropbox && job.cloudFolderID == "" ? "/" : job.cloudFolderID ?? ""
        TriggerType = job.scheduled ? "Scheduled" : "Realtime"; ScheduleTime = job.scheduleTime
        MirrorDeletes = job.mirrorDeletes; Paused = job.paused
    }
    public var provider: CloudProvider? { DestinationType == "Dropbox" ? .dropbox : DestinationType == "GoogleDrive" ? .googleDrive : nil }
    public var folderID: String? { provider == nil ? nil : provider == .dropbox && CloudFolderId == "/" ? "" : CloudFolderId }
}
public struct JobListDocument: Codable, Sendable {
    public var Format: String
    public var Version: Int
    public var ExportedAtUtc: String?
    public var Jobs: [PortableJob]
    public init(jobs: [BackupJob], now: Date = Date()) {
        Format = "SafeSyncJobList"; Version = 1; ExportedAtUtc = HTTP.dateString(now, fractional: true); Jobs = jobs.map(PortableJob.init)
    }
}
public struct JobListImportPlan: Sendable {
    public var jobs: [BackupJob]
    public var reusedIDs: Set<UUID>
    public var newJobCount: Int { jobs.count - reusedIDs.count }
}
public enum JobListCodec {
    public static let maximumBytes = 10 * 1024 * 1024
    public static let maximumJobs = 1000
    public static func encode(_ jobs: [BackupJob]) throws -> Data {
        let document = JobListDocument(jobs: jobs)
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw BackupError.unsafe("작업 목록 파일이 너무 큽니다(최대 10 MB).") }; return data
    }
    public static func decode(_ bytes: Data) throws -> JobListDocument {
        guard bytes.count <= maximumBytes else { throw BackupError.unsafe("작업 목록 파일이 너무 큽니다(최대 10 MB).") }
        var data = bytes
        if data.starts(with: [0xef, 0xbb, 0xbf]) { data.removeFirst(3) }
        let document: JobListDocument
        do { document = try JSONDecoder().decode(JobListDocument.self, from: data) }
        catch { throw BackupError.unsafe("SafeSync 작업 목록 파일 형식이 아니거나 필수 항목의 형식이 잘못되었습니다.") }
        try validate(document); return document
    }
    public static func validate(_ document: JobListDocument) throws {
        guard document.Format == "SafeSyncJobList", document.Version == 1 else { throw BackupError.unsafe("SafeSync 작업 목록 파일 형식이 아닙니다.") }
        guard document.Jobs.count <= maximumJobs else { throw BackupError.unsafe("작업은 최대 1000개까지 가져올 수 있습니다.") }
        var ids: Set<String> = []
        for job in document.Jobs {
            guard job.Id.range(of: "^[a-zA-Z0-9_.-]{1,128}$", options: .regularExpression) != nil, ids.insert(job.Id.lowercased()).inserted else { throw BackupError.unsafe("작업 ID가 잘못되었거나 중복되었습니다: \(job.Id)") }
            guard !job.Name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, job.Name.utf16.count <= 200 else { throw BackupError.unsafe("작업 이름이 비어 있거나 너무 깁니다.") }
            guard [job.Name, job.Source, job.Destination, job.CloudFolderId].allSatisfy({ !$0.contains("\0") }) else { throw BackupError.unsafe("작업 설정에 사용할 수 없는 문자가 있습니다.") }
            guard ["Local", "Dropbox", "GoogleDrive"].contains(job.DestinationType) else { throw BackupError.unsafe("지원하지 않는 백업 위치입니다: \(job.DestinationType)") }
            guard absolute(job.Source), !job.Destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackupError.unsafe("원본 경로나 백업 위치가 잘못되었습니다: \(job.Name)") }
            if job.provider == nil {
                guard absolute(job.Destination), !overlap(normalized(job.Source), normalized(job.Destination)) else { throw BackupError.unsafe("백업 경로가 잘못되었거나 원본과 겹칩니다: \(job.Name)") }
            } else if job.CloudFolderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw BackupError.unsafe("클라우드 폴더 ID가 없습니다: \(job.Name)") }
            guard ["Realtime", "Scheduled"].contains(job.TriggerType), job.ScheduleTime.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil else { throw BackupError.unsafe("실행 방식 또는 예약 시간이 잘못되었습니다: \(job.Name)") }
        }
    }
    private static func absolute(_ path: String) -> Bool {
        path.hasPrefix("/") || path.range(of: "^[a-zA-Z]:[\\\\/]", options: .regularExpression) != nil || path.hasPrefix("\\\\")
    }
    private static func normalized(_ path: String) -> String {
        let value = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        return value == "/" ? value : value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    private static func overlap(_ a: String, _ b: String) -> Bool { a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
    public static func plan(_ document: JobListDocument, replacing current: [BackupJob]) throws -> JobListImportPlan {
        try validate(document)
        var reused: Set<UUID> = [], jobs: [BackupJob] = []
        for portable in document.Jobs {
            guard portable.Source.hasPrefix("/"), portable.provider != nil || portable.Destination.hasPrefix("/") else {
                throw BackupError.unsafe("‘\(portable.Name)’에 Windows 경로가 있습니다. macOS의 실제 폴더 경로로 수정한 뒤 가져오세요. 현재 작업 목록은 바뀌지 않았습니다.")
            }
            var job = BackupJob(); job.name = portable.Name; job.source = portable.Source; job.destination = portable.Destination
            job.cloudProvider = portable.provider; job.cloudFolderID = portable.folderID
            job.scheduled = portable.TriggerType == "Scheduled"; job.scheduleTime = portable.ScheduleTime
            job.mirrorDeletes = portable.MirrorDeletes; job.paused = portable.Paused
            if let id = UUID(uuidString: portable.Id), let old = current.first(where: { $0.id == id }), old.source == job.source, old.destination == job.destination, old.cloudProvider == job.cloudProvider, old.cloudFolderID == job.cloudFolderID {
                job.id = old.id; job.cloudAccountID = old.cloudAccountID; job.lastScheduledDay = old.lastScheduledDay; reused.insert(old.id)
            }
            jobs.append(job)
        }
        // Import must not bypass the path-overlap checks used by the job editor.
        let endpoints = jobs.map { (source: BackupEngine.canonical($0.source), target: $0.cloudProvider == nil ? BackupEngine.canonical($0.destination) : nil) }
        for i in jobs.indices {
            if let target = endpoints[i].target, BackupEngine.overlaps(endpoints[i].source, target) { throw BackupError.unsafe("원본과 백업 위치가 겹칩니다: \(jobs[i].name)") }
            for j in jobs.indices where j < i {
                if jobs[i].cloudProvider != nil, jobs[i].cloudProvider == jobs[j].cloudProvider, jobs[i].cloudFolderID == jobs[j].cloudFolderID, jobs[i].cloudAccountID == jobs[j].cloudAccountID { throw BackupError.unsafe("여러 작업이 같은 클라우드 백업 폴더를 사용합니다.") }
                if let target = endpoints[i].target, BackupEngine.overlaps(target, endpoints[j].source) { throw BackupError.unsafe("작업 간 원본·백업 위치가 겹칩니다.") }
                if let target = endpoints[j].target, BackupEngine.overlaps(target, endpoints[i].source) { throw BackupError.unsafe("작업 간 원본·백업 위치가 겹칩니다.") }
                if let a = endpoints[i].target, let b = endpoints[j].target, BackupEngine.overlaps(a, b) { throw BackupError.unsafe("여러 작업의 백업 위치가 겹칩니다.") }
            }
        }
        return JobListImportPlan(jobs: jobs, reusedIDs: reused)
    }
}
public enum JobListFiles {
    public static func read(_ url: URL) throws -> JobListDocument {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: min(64 * 1024, JobListCodec.maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= JobListCodec.maximumBytes else { throw BackupError.unsafe("작업 목록 파일이 너무 큽니다(최대 10 MB).") }
        }
        return try JobListCodec.decode(data)
    }
    public static func write(_ jobs: [BackupJob], to url: URL) throws {
        let data = try JobListCodec.encode(jobs)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue else { throw BackupError.unsafe("저장할 폴더에 접근할 수 없습니다.") }
        try data.write(to: url, options: .atomic)
    }
    /// Archive first, then atomically commit jobs.json. Accounts, secrets and snapshots are never written here.
    @discardableResult public static func replace(_ plan: JobListImportPlan, current: [BackupJob], settingsURL: URL, backupDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = backupDirectory.appendingPathComponent("SafeSync-jobs-before-import-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).safesync-jobs.json")
        try write(current, to: backup)
        try Storage.save(plan.jobs, to: settingsURL)
        return backup
    }
}
