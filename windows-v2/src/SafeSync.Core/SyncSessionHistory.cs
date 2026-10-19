using System.Collections.ObjectModel;
using System.ComponentModel;

namespace SafeSync.Core;

public enum SyncRunOutcome { Running, Paused, Completed, Attention, Failed, Canceled }

public sealed class SyncRun : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    public string RunId {get;}=Guid.NewGuid().ToString("N");
    public string JobId {get;}
    public string JobName {get;}
    public string Source {get;}
    public string Destination {get;}
    public string DestinationType {get;}
    public string SyncMode {get;}
    public string ModeText=>SyncMode=="TwoWay" ? "양방향 동기화 ↔" : "단방향 백업 →";
    public DateTimeOffset StartedUtc {get;}
    public DateTimeOffset? EndedUtc {get;private set;}
    private DateTimeOffset updatedUtc;
    public SyncRunOutcome Outcome {get;private set;}=SyncRunOutcome.Running;
    public bool IsActive=>Outcome is SyncRunOutcome.Running or SyncRunOutcome.Paused;
    public string Stage {get;private set;}="작업 준비 중";
    public string CurrentFile {get;private set;}="";
    public int CompletedFiles {get;private set;}
    public int TotalFiles {get;private set;}
    public double Percent=>TotalFiles>0 ? Math.Clamp(100d*CompletedFiles/TotalFiles,0,100) : 0;
    public string ProgressText=>TotalFiles>0 ? $"{CompletedFiles:N0} / {TotalFiles:N0}" : "작업량 확인 중";
    public int? Copied {get;private set;}
    public int? Skipped {get;private set;}
    public int? Trashed {get;private set;}
    public IReadOnlyList<FileIssue> Conflicts {get;private set;}=[];
    public IReadOnlyList<FileIssue> Locked {get;private set;}=[];
    public IReadOnlyList<FileIssue> Errors {get;private set;}=[];
    public string FailureReason {get;private set;}="";
    public string StartedText=>StartedUtc.ToLocalTime().ToString("MM-dd HH:mm:ss");
    public string EndedText=>EndedUtc?.ToLocalTime().ToString("HH:mm:ss") ?? "—";
    public string DurationText {get{var elapsed=(EndedUtc ?? updatedUtc)-StartedUtc;if(elapsed<TimeSpan.Zero)elapsed=TimeSpan.Zero;return $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}";}}
    public string CopiedText=>Count(Copied);
    public string SkippedText=>Count(Skipped);
    public string TrashedText=>Count(Trashed);
    public string LockedText=>IsActive ? "—" : Locked.Count.ToString("N0");
    public string ConflictsText=>IsActive ? "—" : Conflicts.Count.ToString("N0");
    public string ErrorsText=>IsActive ? "—" : (Errors.Count+(FailureReason.Length>0 ? 1 : 0)).ToString("N0");
    public string StatusText=>Outcome switch
    {
        SyncRunOutcome.Running=>"진행 중",SyncRunOutcome.Paused=>"일시정지",SyncRunOutcome.Failed=>"실패",SyncRunOutcome.Canceled=>"중단됨",
        SyncRunOutcome.Attention=>Errors.Count>0 ? "오류 확인" : Conflicts.Count>0 ? "충돌 확인" : "사용 중 파일 대기",
        _=>Copied==0 && Trashed==0 ? "변경 없음" : "완료"
    };
    public string Tone=>Outcome switch {SyncRunOutcome.Failed=>"Danger",SyncRunOutcome.Attention=>Errors.Count>0 ? "Danger" : "Warning",SyncRunOutcome.Completed=>"Success",SyncRunOutcome.Running=>"Active",_=>"Muted"};
    public string Summary=>FailureReason.Length>0 ? FailureReason : IsActive ? Stage : $"복사 {Copied:N0} · 동일 {Skipped:N0} · 휴지통 {Trashed:N0} · 사용 중 {Locked.Count:N0} · 충돌 {Conflicts.Count:N0} · 오류 {Errors.Count:N0}";
    private static string Count(int? value)=>value?.ToString("N0") ?? "—";
    internal SyncRun(BackupJob job,DateTimeOffset now){JobId=job.Id;JobName=job.Name;Source=job.Source;Destination=job.Destination;DestinationType=job.DestinationType;SyncMode=job.SyncMode;StartedUtc=updatedUtc=now;}
    internal void Update(BackupProgress progress,bool paused,DateTimeOffset now)
    {Stage=progress.Stage;CurrentFile=progress.CurrentFile;CompletedFiles=progress.Completed;TotalFiles=progress.Total;updatedUtc=now;Outcome=paused ? SyncRunOutcome.Paused : SyncRunOutcome.Running;Changed();}
    internal void SetPaused(bool value){if(IsActive){Outcome=value ? SyncRunOutcome.Paused : SyncRunOutcome.Running;Changed();}}
    internal void Tick(DateTimeOffset now){if(IsActive){updatedUtc=now;PropertyChanged?.Invoke(this,new(nameof(DurationText)));}}
    internal void Finish(BackupResult result,DateTimeOffset now)
    {
        Copied=result.Copied;Skipped=result.Skipped;Trashed=result.Trashed;Conflicts=result.Conflicts.ToArray();Locked=result.Locked.ToArray();Errors=result.Errors.ToArray();EndedUtc=updatedUtc=now;
        Outcome=result.Canceled ? SyncRunOutcome.Canceled : Conflicts.Count+Locked.Count+Errors.Count>0 ? SyncRunOutcome.Attention : SyncRunOutcome.Completed;Changed();
    }
    internal void Fail(Exception exception,DateTimeOffset now){FailureReason=exception.Message;EndedUtc=updatedUtc=now;Outcome=SyncRunOutcome.Failed;Changed();}
    private void Changed()=>PropertyChanged?.Invoke(this,new PropertyChangedEventArgs(""));
}

// Session-only history: no credentials, config migration or on-disk logs.
public sealed class SyncSessionHistory
{
    public ObservableCollection<SyncRun> Runs {get;}=[];
    private readonly Dictionary<string,SyncRun> active=[];
    private readonly Dictionary<string,SyncRun> latest=[];
    public SyncRun Begin(BackupJob job,DateTimeOffset? now=null)
    {
        if(active.TryGetValue(job.Id,out var running))return running;
        var run=new SyncRun(job,now ?? DateTimeOffset.UtcNow);active[job.Id]=run;latest[job.Id]=run;Runs.Insert(0,run);return run;
    }
    public SyncRun Progress(BackupJob job,BackupProgress progress,DateTimeOffset? now=null)
    {var run=Begin(job,now);run.Update(progress,job.Paused,now ?? DateTimeOffset.UtcNow);return run;}
    public SyncRun Complete(BackupJob job,BackupResult result,DateTimeOffset? now=null)
    {var run=Begin(job,now);run.Finish(result,now ?? DateTimeOffset.UtcNow);active.Remove(job.Id);return run;}
    public SyncRun Fail(BackupJob job,Exception exception,DateTimeOffset? now=null)
    {var run=Begin(job,now);run.Fail(exception,now ?? DateTimeOffset.UtcNow);active.Remove(job.Id);return run;}
    public void SetPaused(string jobId,bool paused){if(active.TryGetValue(jobId,out var run))run.SetPaused(paused);}
    public void Tick(DateTimeOffset? now=null){foreach(var run in active.Values)run.Tick(now ?? DateTimeOffset.UtcNow);}
    public bool IsLatest(SyncRun run)=>latest.TryGetValue(run.JobId,out var current) && ReferenceEquals(run,current);
}
