using System.Text;

namespace SafeSync.Core.Cloud;

public static class CloudConnectionDiagnostics
{
    public static async Task<string> RunAsync(IRemoteStore remote,IProgress<BackupProgress>? progress,CancellationToken token)
    {
        var tokenText=Guid.NewGuid().ToString("N");
        var workspace=Path.Combine(Path.GetTempPath(),"SafeSync-connection-diagnostic-"+tokenText);
        var source=Path.Combine(workspace,"source");
        Directory.CreateDirectory(Path.Combine(source,"한글 폴더"));
        try
        {
            await remote.InitializeAsync(token);
            var store=new ConfigStore(Path.Combine(workspace,"state"));
            var job=new BackupJob
            {
                Name="클라우드 연결 검증",Source=source,Destination=remote.Provider+" / SafeSync-test",
                DestinationType=remote.Provider,CloudFolderId=remote.Root,CloudAccountId=remote.AccountId,MirrorDeletes=true
            };
            var engine=new CloudBackupEngine(store,remote);var gate=new PauseGate();
            var file=Path.Combine(source,"한글 폴더","검증.txt");
            void Write(string value,DateTime modified)
            {
                File.WriteAllText(file,value,Encoding.UTF8);File.SetLastWriteTimeUtc(file,modified);
            }
            Task<BackupResult> Run()=>engine.RunAsync(job,true,null,gate,progress,token,null,false,100);

            Write("SafeSync diagnostic original "+tokenText,DateTime.UtcNow.AddMinutes(-2));
            var first=await Run();
            Require(first.Copied==1 && Empty(first),"최초 전송/검증 실패",first);
            var unchanged=await Run();
            Require(unchanged.Skipped==1 && unchanged.Copied==0 && Empty(unchanged),"변경 없는 파일 건너뛰기 검증 실패",unchanged);
            Write("SafeSync diagnostic replacement "+tokenText,DateTime.UtcNow.AddSeconds(10));
            var updated=await Run();
            Require(updated.Copied==1 && Empty(updated),"안전한 교체 검증 실패",updated);
            File.Delete(file);
            var removed=await Run();
            Require(removed.Trashed==1 && Empty(removed),"휴지통 이동 검증 실패",removed);
            var publisher=new CloudPublisher(store,job,remote);var trash=new CloudTrash(remote,publisher);var items=new List<CloudTrashItem>();
            await foreach(var item in trash.ListAsync(token))if(item.RelativePath=="한글 폴더/검증.txt")items.Add(item);
            if(items.Count==0)throw new IOException("휴지통 목록에서 검증 파일을 찾지 못했습니다.");
            await trash.OperateAsync(items.OrderByDescending(i=>i.DeletedAt).First(),true,token);
            if(await remote.StatAsync("한글 폴더/검증.txt",token) is not {Folder:false})throw new IOException("휴지통 파일 복구 검증에 실패했습니다.");
            return $"{Display(remote.Provider)} 실제 검증 통과: 전송·체크섬·변경 없음·교체·휴지통·복구";
        }
        finally { try { if(Directory.Exists(workspace))Directory.Delete(workspace,true); } catch(IOException){} catch(UnauthorizedAccessException){} }
    }

    private static bool Empty(BackupResult result)=>result.Errors.Count==0 && result.Conflicts.Count==0 && result.Locked.Count==0 && !result.Canceled;
    private static void Require(bool condition,string message,BackupResult result)
    {
        if(condition)return;
        var detail=result.Errors.Concat(result.Conflicts).Concat(result.Locked).Select(i=>i.Reason).FirstOrDefault();
        throw new IOException(message+(string.IsNullOrWhiteSpace(detail) ? $" (복사 {result.Copied}, 동일 {result.Skipped}, 휴지통 {result.Trashed})" : ": "+detail));
    }
    private static string Display(string provider)=>provider=="GoogleDrive" ? "Google Drive" : provider;
}
