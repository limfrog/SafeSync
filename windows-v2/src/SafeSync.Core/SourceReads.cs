using System.Diagnostics;
using System.Security.Principal;
using System.Text.RegularExpressions;
namespace SafeSync.Core;

public interface ISourceSnapshot : IAsyncDisposable { string ReadPath(string original); }
public sealed class SourceRead : IDisposable
{
    public string Path {get;}
    public FileInfo Info=>new(Path);
    private readonly FileStream stream;
    internal SourceRead(string path){Path=path;stream=new(path,FileMode.Open,FileAccess.Read,FileShare.Read);}
    public void Dispose()=>stream.Dispose();
}
public sealed class SourceReadScope : IAsyncDisposable
{
    private static readonly AsyncLocal<SourceReadScope?> current=new();
    private readonly SourceReadScope? prior=current.Value;
    private readonly BackupJob job;
    private readonly Func<BackupJob,CancellationToken,Task<ISourceSnapshot>> factory;
    private readonly IProgress<BackupProgress>? progress;
    private readonly SemaphoreSlim gate=new(1,1);
    private ISourceSnapshot? snapshot;
    public SourceReadScope(BackupJob job,Func<BackupJob,CancellationToken,Task<ISourceSnapshot>>? factory=null,IProgress<BackupProgress>? progress=null)
    {this.job=job;this.factory=factory ?? VssSnapshot.CreateAsync;this.progress=progress;current.Value=this;}
    public static async Task<SourceRead> OpenAsync(string source,CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        try{return new(source);}
        catch(IOException ex) when((ex.HResult&0xffff) is 32 or 33 && current.Value is {job.UseVss:true} scope)
        {
            if(!PathPolicy.Inside(scope.job.Source,source))throw new InvalidDataException("VSS 원본 범위를 벗어났습니다.");
            PathPolicy.RejectLinks(scope.job.Source,source);
            try
            {
                await scope.gate.WaitAsync(token);
                try
                {
                    if(scope.snapshot==null){scope.progress?.Report(new(scope.job.Id,scope.job.Name,"VSS 사용 중 파일 사본 준비",Path.GetRelativePath(scope.job.Source,source),0,0));using var timing=OperationLog.Measure("file.vss_prepare");scope.snapshot=await scope.factory(scope.job,token);}
                }
                finally{scope.gate.Release();}
                var mapped=scope.snapshot.ReadPath(source);OperationLog.Event("vss.read","snapshot",source);
                return new(mapped);
            }
            catch(OperationCanceledException){throw;}
            catch(Exception error){throw new IOException("사용 중인 파일 대기 · VSS 사본을 사용할 수 없습니다: "+error.Message,unchecked((int)0x80070020));}
        }
    }
    public async ValueTask DisposeAsync(){current.Value=prior;if(snapshot!=null){progress?.Report(new(job.Id,job.Name,"VSS 임시 사본 정리","",0,0));await snapshot.DisposeAsync();}gate.Dispose();}
}
public sealed class VssSnapshot : ISourceSnapshot
{
    private readonly Process process;private readonly string volume,device;private readonly Task<string> error;
    public string Id {get;}
    private VssSnapshot(Process process,string volume,string device,string id,Task<string> error){this.process=process;this.volume=volume;this.device=device;Id=id;this.error=error;}
    public static bool IsAdministrator=>new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
    public static async Task<ISourceSnapshot> CreateAsync(BackupJob job,CancellationToken token)
        =>await CreateAsync(job,Path.Combine(AppContext.BaseDirectory,"SafeSync.Vss.exe"),token);
    public static async Task<VssSnapshot> CreateAsync(BackupJob job,string helper,CancellationToken token)
    {
        if(job.SyncMode!="OneWay" || job.Source.StartsWith(@"\\"))throw new IOException("VSS는 로컬 NTFS 원본의 단방향 작업에서 사용할 수 있습니다.");
        if(!IsAdministrator)throw new UnauthorizedAccessException("VSS를 사용하려면 SafeSync를 관리자 권한으로 실행하세요.");
        var volume=Path.GetPathRoot(Path.GetFullPath(job.Source))!;var drive=new DriveInfo(volume);
        if(drive.DriveType!=DriveType.Fixed || drive.DriveFormat!="NTFS")throw new IOException("VSS 원본은 로컬 NTFS 드라이브여야 합니다.");
        if(!File.Exists(helper))throw new IOException("VSS 구성 요소가 없습니다. 설치본을 다시 설치하세요.");
        var start=new ProcessStartInfo(helper){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};start.ArgumentList.Add(volume);
        var process=Process.Start(start) ?? throw new IOException("VSS 구성 요소를 시작하지 못했습니다.");var error=process.StandardError.ReadToEndAsync();
        try
        {
            using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromMinutes(3));
            var line=await process.StandardOutput.ReadLineAsync(timeout.Token) ?? throw new IOException(await error);
            var parts=line.Split('|');
            if(parts.Length!=3 || parts[0]!="READY" || !Guid.TryParse(parts[1],out _) || !Regex.IsMatch(parts[2],@"^\\\\\?\\GLOBALROOT\\Device\\HarddiskVolumeShadowCopy\d+\\?$"))throw new IOException("VSS 사본 응답이 올바르지 않습니다.");
            OperationLog.Event("vss.ready","snapshot");return new(process,volume,parts[2].TrimEnd('\\')+"\\",parts[1],error);
        }
        catch{try{process.StandardInput.Close();if(!process.HasExited)process.Kill(true);}catch{}process.Dispose();throw;}
    }
    public string ReadPath(string original)
    {
        var relative=Path.GetRelativePath(volume,original);if(relative.StartsWith("..") || Path.IsPathRooted(relative))throw new InvalidDataException("VSS 볼륨 밖의 경로입니다.");
        return device+relative;
    }
    public async ValueTask DisposeAsync()
    {
        try
        {
            process.StandardInput.Close();await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30));
            if(process.ExitCode!=0)OperationLog.Event("vss.cleanup_error","snapshot",detail:"helper_failed");
            await error;
        }
        catch(Exception ex){OperationLog.Event("vss.cleanup_error","snapshot",error:ex);try{if(!process.HasExited)process.Kill(true);}catch{}}
        finally{process.Dispose();}
    }
}
