using System.Text.Json;
using System.Text.Json.Serialization;

namespace SafeSync.Core;

public sealed class BackupJob
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "새 백업 작업";
    public string Source { get; set; } = "";
    public string DestinationType { get; set; } = "Local";
    public string Destination { get; set; } = "";
    public string SyncMode { get; set; } = "OneWay";
    public string CloudFolderId { get; set; } = "";
    public string CloudFolderIdentity { get; set; } = "";
    public string CloudAccountId { get; set; } = "";
    public bool CloudBindingReviewRequired { get; set; }
    public string CloudAccessMode { get; set; } = "";
    public string TriggerType { get; set; } = "Realtime";
    public string ScheduleTime { get; set; } = "23:00";
    public bool MirrorDeletes { get; set; }
    public bool Paused { get; set; }
    public bool Stopped { get; set; }
    public string LastScheduledRun { get; set; } = "";
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    [JsonIgnore] public string TriggerText => TriggerType == "Realtime" ? "파일 변경 시" : $"매일 {ScheduleTime}";
    [JsonIgnore] public string ModeText => SyncMode == "TwoWay" ? "양방향 동기화 ↔" : "단방향 백업 →";
    [JsonIgnore] public string Status { get; set; } = "대기 중";
}

public sealed class AppConfig
{
    public int Version { get; set; } = 8;
    public string ThemeMode { get; set; } = "Light";
    public int TrashRetentionDays { get; set; } = 100;
    public bool AutoStart { get; set; }
    public bool SoundOnMinimize { get; set; }
    public bool SoundOnBackupError { get; set; } = true;
    public bool SoundOnBackupComplete { get; set; }
    public bool AutomaticallyCheckUpdates {get;set;}=true;
    public bool AutomaticallyDownloadUpdates {get;set;}=true;
    public bool OperationLogEnabled {get;set;}
    public WindowLayout WindowLayout { get; set; } = new();
    public List<BackupJob> Jobs { get; set; } = [];
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed class WindowLayout
{
    public double MainWidth { get; set; } = 1180;
    public double MainHeight { get; set; } = 720;
    public double MainActivityHeight { get; set; } = 155;
    public double ProgressWidth { get; set; } = 1180;
    public double ProgressHeight { get; set; } = 720;
    public double ProgressLockedHeight { get; set; } = 125;
    public double ProgressHistoryHeight {get;set;}=210;
}

public sealed class FileEntry
{
    public string RelativePath { get; set; } = "";
    public long Length { get; set; }
    public string CreationTimeUtc { get; set; } = "";
    public string LastWriteTimeUtc { get; set; } = "";
    public string Status { get; set; } = "BackedUp";
    public string LastError { get; set; } = "";
    public string LastAttemptUtc { get; set; } = "";
    public string LockedSinceUtc {get;set;}="";
    public long SourceFileId {get;set;}
    public long BackupFileId {get;set;}
    public int LockRetryCount {get;set;}
    public string RemoteId { get; set; } = "";
    // Only populated after verified content equality or a verified upload.
    public Cloud.RemoteItem? VerifiedRemote { get; set; }
    public string RemoteParentId { get; set; } = "";
    // Older snapshots must not authorize deletion until this source was observed
    // under a verified root. Missing legacy files remain reviewable conflicts.
    public bool DeletionSourceVerified { get; set; }
    public SyncSide? SyncSource { get; set; }
    public SyncSide? SyncBackup { get; set; }
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
    public static FileEntry From(FileInfo info, string relative, string status = "BackedUp", string error = "") => new()
    {
        RelativePath = relative, Length = info.Exists ? info.Length : 0,SourceFileId=info.Exists ? OfflineJournal.FileIdentity(info.FullName) : 0,
        CreationTimeUtc = info.Exists ? info.CreationTimeUtc.ToString("O") : "",
        LastWriteTimeUtc = info.Exists ? info.LastWriteTimeUtc.ToString("O") : "",
        Status = status, LastError = error, LastAttemptUtc = DateTime.UtcNow.ToString("O"),DeletionSourceVerified=info.Exists
    };
}

public sealed class JobState
{
    public int Version { get; set; } = 2;
    public string Generation {get;set;}="";
    public UsnCheckpoint? SourceJournal {get;set;}
    public UsnCheckpoint? DestinationJournal {get;set;}
    public string JobId { get; set; } = "";
    public string SyncMode { get; set; } = "OneWay";
    public string SyncSourceIdentity { get; set; } = "";
    public string SyncBackupIdentity { get; set; } = "";
    public string OneWaySourceIdentity { get; set; } = "";
    public string OneWayBackupIdentity { get; set; } = "";
    public string CloudFolderIdentity { get; set; } = "";
    public string Source { get; set; } = "";
    public string Destination { get; set; } = "";
    public string LastFullScanUtc { get; set; } = "";
    public string DestinationType { get; set; } = "Local";
    public string CloudFolderId { get; set; } = "";
    public string CloudAccountId { get; set; } = "";
    public string LastRunUtc { get; set; } = "";
    public bool FullScanRequired { get; set; } = true;
    public bool CheckpointActive { get; set; }
    public List<string> PendingPaths { get; set; } = [];
    public List<FileEntry> Files { get; set; } = [];
    [JsonExtensionData] public Dictionary<string, JsonElement>? Extra { get; set; }
}

public sealed record SyncSide(long Length, string Modified, string Created, string Hash, string Identity);

public enum ConflictAction { Overwrite, KeepBoth, Ignore, UseBackup, NormalizeDuplicates }
public sealed record FileIssue(string JobId, string JobName, string File, string Reason,
    long SourceSize, long BackupSize, string SourceModified, string BackupModified,string WaitingSinceUtc="",int RetryCount=0,string LastAttemptUtc="",
    string SourceCreated="",string BackupCreated="",bool? SourceExists=null,bool? BackupExists=null,bool AutomaticNetworkRetry=false)
{
    [JsonIgnore] public string Handling=>NetworkFailures.Automatic(this) ? "자동 재시도" : "확인 필요";
}
public sealed record BackupProgress(string JobId, string JobName, string Stage, string CurrentFile,
    int Completed, int Total, long Bytes = 0, long TotalBytes = 0);
public sealed class BackupResult
{
    public int Copied { get; set; }
    public int Skipped { get; set; }
    public int Trashed { get; set; }
    public bool Canceled { get; set; }
    public List<FileIssue> Conflicts { get; } = [];
    public List<FileIssue> Locked { get; } = [];
    public List<FileIssue> Errors { get; } = [];
    public List<string> ResolvedPaths {get;}=[];
}

public sealed record TrashItem(string StoragePath, string Name, DateTime DeletedAt, string OriginalPath,
    string RelativePath, long Length)
{
    public string DeletedAtText => DeletedAt.ToString("yyyy-MM-dd HH:mm:ss");
    public string SizeText => Length < 1024 ? $"{Length} B" : $"{Length / 1024d:N1} KB";
}

public sealed class PauseGate
{
    private readonly object gate = new();
    private TaskCompletionSource? paused;
    private bool stopRequested;
    private readonly CancellationTokenSource boundaryStop=new();
    public bool IsStopRequested { get { lock(gate)return stopRequested; } }
    public void RequestStop() { lock(gate){stopRequested=true;paused?.TrySetResult();paused=null;}boundaryStop.Cancel(); }
    public void ThrowIfStopRequested() { if(IsStopRequested)throw new JobStoppedException(); }
    public async Task WaitForBoundaryAsync(SemaphoreSlim semaphore,CancellationToken token)
    {
        using var linked=CancellationTokenSource.CreateLinkedTokenSource(token,boundaryStop.Token);
        try{await semaphore.WaitAsync(linked.Token);}
        catch(OperationCanceledException) when(!token.IsCancellationRequested && IsStopRequested){throw new JobStoppedException();}
    }
    public bool IsPaused { get { lock (gate) return paused != null; } }
    public void Pause() { lock (gate) paused ??= new(TaskCreationOptions.RunContinuationsAsynchronously); }
    public void Resume() { lock (gate) { paused?.TrySetResult(); paused = null; } }
    public Task WaitAsync(CancellationToken token)
    {
        lock (gate) return paused?.Task.WaitAsync(token) ?? Task.CompletedTask;
    }
}

public sealed class JobStoppedException : OperationCanceledException
{
    public JobStoppedException() : base("현재 파일을 안전하게 마친 뒤 작업을 종료했습니다.") { }
}
