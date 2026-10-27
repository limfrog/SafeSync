using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace SafeSync.Core;

// Diagnostic failures must never fail a backup. No paths, URLs, headers, bodies,
// exception messages, account names or token material enter this schema.
public sealed class OperationLog : IDisposable
{
    public const long FileLimit = 8 * 1024 * 1024;
    public const int FileCount = 8;
    private static OperationLog? current;
    private static readonly AsyncLocal<Run?> ambient = new();
    private readonly Channel<object> queue=Channel.CreateBounded<object>(new BoundedChannelOptions(8192){FullMode=BoundedChannelFullMode.Wait,SingleReader=true});
    private readonly string root;
    private readonly byte[] salt=RandomNumberGenerator.GetBytes(32);
    private readonly string session=Guid.NewGuid().ToString("N");
    private readonly Task worker;
    private long dropped;
    private int disposed;
    private volatile bool enabled;
    private sealed record Flush(TaskCompletionSource Completion);
    private sealed record Entry(int Schema,string Utc,string Session,string? Run,string Event,string Operation,string? File,
        double? Ms,long? Bytes,int? Completed,int? Total,int? Status,int? Attempt,string? Error,int? HResult,string? Detail);
    public static OperationLog Start(string root,string version,bool enabled=true)
    {
        var log=new OperationLog(root){enabled=enabled};Interlocked.Exchange(ref current,log);
        NetworkTrace.Configure(enabled);
        log.Write("session.start","application",detail:version);return log;
    }
    private OperationLog(string dataRoot){root=Path.Combine(dataRoot,"logs","operations");worker=Task.Run(WriteLoop);}
    public static bool IsEnabled=>Volatile.Read(ref current)?.enabled==true;
    public static void SetEnabled(bool value)
    {
        var log=Volatile.Read(ref current);if(log==null || log.enabled==value)return;
        if(!value)log.Write("logging.disabled","application");
        log.enabled=value;
        NetworkTrace.Configure(value);
        if(value)log.Write("logging.enabled","application");
    }
    private string Tag(string value)=>Convert.ToHexStringLower(HMACSHA256.HashData(salt,Encoding.UTF8.GetBytes(value)))[..20];
    private void Write(string kind,string operation,Run? run=null,string? path=null,double? ms=null,long? bytes=null,
        int? completed=null,int? total=null,int? status=null,int? attempt=null,Exception? error=null,string? detail=null)
    {
        try
        {
            if(Volatile.Read(ref disposed)!=0 || !enabled)return;
            var entry=new Entry(1,DateTime.UtcNow.ToString("O"),session,run?.Id,kind,operation,
                string.IsNullOrEmpty(path) ? null : run?.FileTag(path) ?? Tag(path),ms,bytes,completed,total,status,attempt,
                ErrorTypes(error),error?.HResult,detail);
            if(!queue.Writer.TryWrite(entry))Interlocked.Increment(ref dropped);
        }
        catch { }
    }
    private static string? ErrorTypes(Exception? error)
    {
        if(error==null)return null;
        var types=new List<string>();for(int i=0;error!=null && i<5;i++,error=error.InnerException)types.Add(error.GetType().Name+":"+error.HResult);
        return string.Join('>',types);
    }
    public static Run? Begin(BackupJob job,bool full,bool reconcile)
    {
        var log=Volatile.Read(ref current);if(log==null || !log.enabled)return null;
        var run=new Run(log,ambient.Value,job.Source);ambient.Value=run;
        var provider=job.DestinationType is "Local" or "GoogleDrive" or "Dropbox" ? job.DestinationType : "unknown";
        var mode=job.SyncMode is "OneWay" or "TwoWay" ? job.SyncMode : "unknown";
        log.Write("run.start","backup",run,detail:$"job={log.Tag(job.Id)};provider={provider};mode={mode};full={full};reconcile={reconcile};source={(job.Source.StartsWith(@"\\") ? "network" : "local")}");return run;
    }
    public static Span Measure(string operation,string? path=null,long? bytes=null)=>new(ambient.Value,operation,path,bytes);
    public static void Event(string kind,string operation,string? path=null,long? bytes=null,int? completed=null,int? total=null,int? status=null,int? attempt=null,Exception? error=null,string? detail=null)
    {
        var run=ambient.Value;var log=run?.Log ?? Volatile.Read(ref current);
        log?.Write(kind,operation,run,path,bytes:bytes,completed:completed,total:total,status:status,attempt:attempt,error:error,detail:detail);
    }
    public static void Http(string operation,long started,long? bytes,int? status,int attempt,Exception? error=null,double authMs=0)
    {
        var run=ambient.Value;var log=run?.Log ?? Volatile.Read(ref current);
        log?.Write("http.end",operation,run,ms:Stopwatch.GetElapsedTime(started).TotalMilliseconds,bytes:bytes,status:status,attempt:attempt,error:error,detail:$"authMs={authMs:F2}");
    }
    public static string Endpoint(Uri uri)
    {
        // Match fixed routes only; file IDs and resumable session URLs are secret.
        var p=uri.AbsolutePath;
        if(p.Contains("/token",StringComparison.Ordinal))return "oauth.token";
        if(uri.Host.EndsWith("googleapis.com",StringComparison.Ordinal))
        {
            if(p.Contains("/upload/",StringComparison.Ordinal))return "drive.upload";
            if(p=="/batch/drive/v3")return "drive.batch";
            if(p.Contains("/changes",StringComparison.Ordinal))return "drive.changes";
            if(p=="/drive/v3/files")return "drive.list_or_create";
            if(p.StartsWith("/drive/v3/files/",StringComparison.Ordinal))return "drive.file";
            return "drive.other";
        }
        return p switch
        {
            "/2/files/upload_session/start"=>"dropbox.upload.start",
            "/2/files/upload_session/append_v2"=>"dropbox.upload.append",
            "/2/files/upload_session/finish"=>"dropbox.upload.finish",
            "/2/files/list_folder"=>"dropbox.list",
            "/2/files/list_folder/continue"=>"dropbox.changes",
            "/2/files/get_metadata"=>"dropbox.metadata",
            "/2/files/download"=>"dropbox.download",
            "/2/files/move_v2"=>"dropbox.move",
            _=>"dropbox.other"
        };
    }
    public sealed class Run : IDisposable
    {
        internal OperationLog Log {get;}
        internal string Id {get;}=Guid.NewGuid().ToString("N");
        private readonly Run? previous;
        private readonly string source;
        private readonly long started=Stopwatch.GetTimestamp();
        private readonly object gate=new();
        private readonly Dictionary<string,(double Ms,int Count)> totals=[];
        private string? lastStage;
        private long stageStarted;
        private string outcome="interrupted";
        private int lastCompleted=-1;
        private long lastHeartbeat;
        private bool prepared,uploadStarted;
        internal Run(OperationLog log,Run? previous,string source){Log=log;this.previous=previous;this.source=source;}
        internal string FileTag(string path)
        {
            try{if(Path.IsPathRooted(path)){var relative=Path.GetRelativePath(source,path);if(relative!=".." && !relative.StartsWith(".."+Path.DirectorySeparatorChar,StringComparison.Ordinal))path=relative;}}catch { }
            return Log.Tag(path.Replace('\\','/').ToUpperInvariant());
        }
        public void Progress(BackupProgress p)
        {
            if(!Log.enabled)return;
            lock(gate)
            {
                var now=Stopwatch.GetTimestamp();
                if(lastStage!=p.Stage)
                {
                    if(lastStage!=null)Accumulate(lastStage,Stopwatch.GetElapsedTime(stageStarted).TotalMilliseconds);
                    lastStage=p.Stage;stageStarted=now;
                }
                Log.Write("stage","backup",this,p.CurrentFile,completed:p.Completed,total:p.Total,detail:p.Stage);
                if(p.Completed!=lastCompleted || Stopwatch.GetElapsedTime(lastHeartbeat).TotalSeconds>=30)
                {Log.Write("progress","backup",this,completed:p.Completed,total:p.Total,bytes:p.Bytes);lastCompleted=p.Completed;lastHeartbeat=now;}
            }
        }
        private void Accumulate(string stage,double ms){var old=totals.GetValueOrDefault(stage);totals[stage]=(old.Ms+ms,old.Count+1);}
        internal void NoteSpan(string operation,double ms)
        {
            lock(gate)if(!prepared && operation.StartsWith("prepare.",StringComparison.Ordinal))Log.Write("prepare.phase",operation,this,ms:ms);
        }
        internal void StartingSpan(string operation)
        {
            lock(gate)
            {
                if(!prepared && operation is "file.local" or "file.cloud")
                {prepared=true;Log.Write("prepare.ready","backup",this,ms:Stopwatch.GetElapsedTime(started).TotalMilliseconds);}
                if(!uploadStarted && operation=="file.upload")
                {uploadStarted=true;Log.Write("transfer.first","backup",this,ms:Stopwatch.GetElapsedTime(started).TotalMilliseconds);}
            }
        }
        public void Complete(BackupResult result)
        {
            outcome=result.Canceled ? "canceled" : result.Errors.Count>0 ? "errors" : result.Conflicts.Count>0 ? "conflicts" : "complete";
            Log.Write("run.result","backup",this,completed:result.Copied,total:result.Skipped,detail:$"outcome={outcome};copied={result.Copied};skipped={result.Skipped};trash={result.Trashed};errors={result.Errors.Count};conflicts={result.Conflicts.Count};locked={result.Locked.Count}");
        }
        public void Fail(Exception error){outcome="failed";Log.Write("run.error","backup",this,error:error);}
        public void Dispose()
        {
            lock(gate)
            {
                if(lastStage!=null)Accumulate(lastStage,Stopwatch.GetElapsedTime(stageStarted).TotalMilliseconds);
                foreach(var item in totals)Log.Write("reported_stage.wall","backup",this,ms:item.Value.Ms,completed:item.Value.Count,detail:item.Key);
            }
            Log.Write("run.end","backup",this,ms:Stopwatch.GetElapsedTime(started).TotalMilliseconds,detail:outcome);ambient.Value=previous;
        }
    }
    public sealed class Span : IDisposable
    {
        private readonly Run? run;
        private readonly OperationLog? log;
        private readonly string operation;
        private readonly string? path;
        private readonly long? bytes;
        private readonly long started=Stopwatch.GetTimestamp();
        internal Span(Run? run,string operation,string? path,long? bytes)
        {this.run=run;log=run?.Log ?? Volatile.Read(ref current);this.operation=operation;this.path=path;this.bytes=bytes;run?.StartingSpan(operation);log?.Write("span.start",operation,run,path,bytes:bytes);}
        public void Dispose(){var ms=Stopwatch.GetElapsedTime(started).TotalMilliseconds;run?.NoteSpan(operation,ms);log?.Write("span.end",operation,run,path,ms,bytes);}
    }
    public async Task FlushAsync()
    {
        var completion=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if(queue.Writer.TryWrite(new Flush(completion)))await completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }
    private async Task WriteLoop()
    {
        StreamWriter? writer=null,summary=null;long size=0,summarySize=0;int part=0,summaryPart=0;
        try
        {
            Directory.CreateDirectory(root);Prune();
            await foreach(var item in queue.Reader.ReadAllAsync())
            {
                if(item is Flush flush){if(writer!=null)await writer.FlushAsync();if(summary!=null)await summary.FlushAsync();flush.Completion.TrySetResult();continue;}
                var lost=Interlocked.Exchange(ref dropped,0);
                if(lost>0 && writer!=null)
                {
                    var loss=JsonSerializer.Serialize(new{Schema=1,Utc=DateTime.UtcNow,Session=session,Event="log.dropped",Count=lost});var lossBytes=Encoding.UTF8.GetByteCount(loss)+1;
                    if(size+lossBytes<=FileLimit){await writer.WriteLineAsync(loss);size+=lossBytes;}else Interlocked.Add(ref dropped,lost);
                }
                var line=JsonSerializer.Serialize(item);var length=Encoding.UTF8.GetByteCount(line)+1;
                if(writer==null || size+length>FileLimit)
                {
                    if(writer!=null)await writer.DisposeAsync();
                    var path=Path.Combine(root,$"Diagnostic-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{session[..8]}-{part++:D4}.jsonl");
                    writer=new StreamWriter(new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read,65536,FileOptions.Asynchronous),new UTF8Encoding(false)){AutoFlush=true,NewLine="\n"};size=0;Prune();
                }
                await writer.WriteLineAsync(line);size+=length;
                if(item is Entry entry && (entry.Event is "session.start" or "run.start" or "run.result" or "run.error" or "run.end" or "prepare.phase" or "prepare.ready" or "prepare.plan" or "transfer.first" || entry.Operation=="application.initialize"))
                {
                    if(summary==null || summarySize+length>FileLimit)
                    {
                        if(summary!=null)await summary.DisposeAsync();
                        var path=Path.Combine(root,$"Summary-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{session[..8]}-{summaryPart++:D4}.jsonl");
                        summary=new StreamWriter(new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read,65536,FileOptions.Asynchronous),new UTF8Encoding(false)){AutoFlush=true,NewLine="\n"};summarySize=0;Prune("Summary-",2);
                    }
                    await summary.WriteLineAsync(line);summarySize+=length;
                }
            }
        }
        catch {while(await queue.Reader.WaitToReadAsync())while(queue.Reader.TryRead(out var item))if(item is Flush f)f.Completion.TrySetResult();}
        finally {if(writer!=null)try{await writer.DisposeAsync();}catch { }if(summary!=null)try{await summary.DisposeAsync();}catch { }}
    }
    private void Prune(string prefix="Diagnostic-",int count=FileCount)
    {
        try
        {
            var files=new DirectoryInfo(root).GetFiles(prefix+"*.jsonl").OrderByDescending(f=>f.LastWriteTimeUtc).ToArray();
            for(int i=0;i<files.Length;i++)if(i>=count || files[i].LastWriteTimeUtc<DateTime.UtcNow.AddDays(-14))try{files[i].Delete();}catch { }
        }
        catch { }
    }
    public void Dispose()
    {
        if(Interlocked.Exchange(ref disposed,1)!=0)return;
        if(Interlocked.CompareExchange(ref current,null,this)==this)NetworkTrace.Configure(false);queue.Writer.TryComplete();try{worker.Wait(TimeSpan.FromSeconds(2));}catch { }
    }
}
