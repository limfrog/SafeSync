using System.Runtime.CompilerServices;
using SafeSync.Core.Cloud;
namespace SafeSync.Core;

public sealed record RestoreCheckRow(string Path,long Length,string Status,string Detail);
public sealed class RestoreChecks(ConfigStore store)
{
    public async IAsyncEnumerable<RestoreCheckRow> CheckAsync(BackupJob job,IRemoteStore? remote,[EnumeratorCancellation] CancellationToken token)
    {
        ConfigStore.ValidateJob(job);var state=store.LoadState(job);
        if(remote!=null){if(remote.Provider!=job.DestinationType || remote.AccountId!=job.CloudAccountId)throw new IOException("검증 계정이 작업과 다릅니다.");await remote.InitializeAsync(token);}
        var gate=remote==null ? null : CloudBackupEngine.ScopeGate(remote);if(gate!=null)await gate.WaitAsync(token);
        try
        {
            string expectedRoot=remote==null ? job.SyncMode=="TwoWay" ? state.SyncBackupIdentity : state.OneWayBackupIdentity : job.CloudFolderIdentity;
            async Task CheckRoot()
            {
                if(remote==null){PathPolicy.RejectLinks(job.Destination,job.Destination);if(!Directory.Exists(job.Destination) || expectedRoot.Length>0 && OfflineJournal.RequiredRootIdentity(job.Destination)!=expectedRoot)throw new IOException("백업 폴더의 연결 또는 식별 정보가 바뀌었습니다.");}
                else{var root=await remote.StatAsync("",token);if(root?.Folder!=true || expectedRoot.Length>0 && root.Id!=expectedRoot)throw new IOException("클라우드 백업 폴더가 바뀌었거나 접근할 수 없습니다.");}
            }
            await CheckRoot();
            foreach(var entry in state.Files.Where(e=>e.Length>=0 && !PathPolicy.Internal(e.RelativePath)).OrderBy(e=>e.RelativePath,StringComparer.OrdinalIgnoreCase))
            {
                token.ThrowIfCancellationRequested();PathPolicy.Relative(entry.RelativePath);RestoreCheckRow row;
                try
                {
                    if(remote==null)
                    {
                        await CheckRoot();var file=PathPolicy.Combine(job.Destination,entry.RelativePath);PathPolicy.RejectLinks(job.Destination,file);
                        using var read=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read);
                        var folder=Path.Combine(Path.GetTempPath(),"SafeSync-restore-check-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);
                        try
                        {
                            var temporary=Path.Combine(folder,"payload");
                            await using(var output=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){await read.CopyToAsync(output,token);await output.FlushAsync(token);}
                            var digest=await VerifiedFiles.HashAsync(temporary,token);var expected=entry.SyncBackup?.Hash ?? entry.VerifiedBackupSha256;
                            row=expected.Length==0 ? new(entry.RelativePath,read.Length,"기준 없음","임시 복원은 가능하지만 이전 성공 체크섬이 없습니다.") : digest==expected ? new(entry.RelativePath,read.Length,"정상","임시 복원 내용이 성공 백업의 SHA-256과 일치합니다.") : new(entry.RelativePath,read.Length,"실패","성공 백업 기록과 내용이 다릅니다. 현재 파일을 보존했습니다.");
                        }
                        finally{if(Directory.Exists(folder))Directory.Delete(folder,true);}
                    }
                    else
                    {
                        var current=await remote.StatAsync(entry.RelativePath,token) ?? throw new IOException("백업 파일이 없습니다.");
                        var folder=Path.Combine(Path.GetTempPath(),"SafeSync-restore-check-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);
                        try
                        {
                            var file=Path.Combine(folder,"payload");await remote.DownloadAsync(entry.RelativePath,file,token);
                            var digest=await RemotePath.HashAsync(remote.Provider,file,token);
                            if(new FileInfo(file).Length!=current.Length || current.Hash.Length>0 && digest!=current.Hash)throw new IOException("서비스의 체크섬과 실제 읽은 내용이 다릅니다.");
                            if(!RemotePath.Same(current,await remote.StatAsync(entry.RelativePath,token) ?? throw new IOException("검증 중 파일이 사라졌습니다.")))throw new IOException("검증 중 백업이 변경되었습니다.");
                            var expected=entry.VerifiedRemote?.Hash ?? entry.SyncBackup?.Hash ?? "";
                            row=expected.Length==0 ? new(entry.RelativePath,current.Length,"기준 없음","읽기는 가능하지만 성공 백업의 체크섬 기준이 없습니다.") : expected==digest ? new(entry.RelativePath,current.Length,"정상","임시 위치에 읽은 내용이 성공 백업 체크섬과 일치합니다.") : new(entry.RelativePath,current.Length,"실패","성공 백업과 내용이 다릅니다. 현재 파일을 보존했습니다.");
                        }
                        finally{if(Directory.Exists(folder))Directory.Delete(folder,true);}
                    }
                }
                catch(OperationCanceledException){throw;}
                catch(Exception ex) when(ex is not CloudApiException && ex is not HttpRequestException){row=new(entry.RelativePath,entry.Length,"실패",ex.Message);}
                yield return row;
            }
            await CheckRoot();
        }
        finally{gate?.Release();}
    }
}
