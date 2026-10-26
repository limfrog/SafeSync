using System.Text.RegularExpressions;

namespace SafeSync.Core.Cloud;

public class CloudConflictException(string relative,string message) : IOException(message)
{
    public string RelativePath {get;}=relative;
}
public sealed class CloudDuplicateNameException(string relative) : CloudConflictException(relative,"클라우드에 중복 이름의 다른 사본이 있습니다. 동기화 상태의 문제 해결에서 사본 정보를 확인하고 덮어쓰기·이름 보존·제외를 선택하세요.");
public sealed class CloudTransaction
{
    public string JobId {get;set;}="";
    public string SourceRoot {get;set;}="";
    public string Provider {get;set;}="";
    public string Root {get;set;}="";
    public string AccountId {get;set;}="";
    public string Relative {get;set;}="";
    public string Staged {get;set;}="";
    public string PreviousPath {get;set;}="";
    public RemoteItem? Previous {get;set;}
    public UploadSnapshot? Snapshot {get;set;}
    public UploadSession Session {get;set;}=new();
    public bool DeleteOnly {get;set;}
    public bool Restore {get;set;}
    public string StagedId {get;set;}="";
}
public sealed class CloudPublisher(ConfigStore store,BackupJob job,IRemoteStore remote)
{
    // Also applied to interrupted deletion journals immediately before mutation.
    public Action<string>? ValidateDeletion {get;set;}
    private string JournalRoot=>Path.Combine(store.Root,"cloud-transactions-v2");
    private static string TrashPath(string relative,string reason)=>".safesync-trash/"+DateTime.Now.ToString("yyyyMMdd-HHmmssfff")+"-"+reason+"-"+Guid.NewGuid().ToString("N")+"/"+RemotePath.Normalize(relative);
    private CloudTransaction Record(string relative,RemoteItem? previous,bool keepBoth=false)=>new()
    {
        JobId=job.Id,SourceRoot=job.Source,Provider=remote.Provider,Root=remote.Root,AccountId=remote.AccountId,
        Relative=RemotePath.Normalize(relative),Previous=previous,
        PreviousPath=keepBoth ? relative+".SafeSync-conflict-"+DateTime.Now.ToString("yyyyMMdd-HHmmssfff")+"-"+Guid.NewGuid().ToString("N")[..8] : TrashPath(relative,"replaced")
    };
    private string NewJournal()=>Path.Combine(JournalRoot,job.Id+"."+Guid.NewGuid().ToString("N")+".json");
    public async Task<UploadSnapshot> StageAsync(string source,CancellationToken token)
    {
        var directory=Path.Combine(store.Root,"cloud-upload-v2",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        await new VerifiedFiles().CopyAsync(source,directory,"payload",token);
        var path=Path.Combine(directory,"payload");var info=new FileInfo(path);
        if(remote.Provider=="GoogleDrive"){var hashes=await RemotePath.GoogleHashesAsync(path,token);return new(path,info.Length,info.LastWriteTimeUtc,info.CreationTimeUtc,hashes.Md5,hashes.Sha256);}
        return new(path,info.Length,info.LastWriteTimeUtc,info.CreationTimeUtc,await RemotePath.HashAsync(remote.Provider,path,token));
    }
    public async Task<RemoteItem> PublishAsync(string relative,UploadSnapshot snapshot,RemoteItem? previous,bool keepBoth,PauseGate pause,CancellationToken token)
    {
        var record=Record(relative,previous,keepBoth);record.Snapshot=snapshot;record.Staged=".safesync-staging/"+Guid.NewGuid().ToString("N")+".part";
        var journal=NewJournal();JsonFile.Save(journal,record);
        return (await ContinueAsync(journal,record,pause,token))!;
    }
    public async Task TrashAsync(string relative,RemoteItem previous,CancellationToken token)
    {
        if(previous.Folder || !previous.Binary)throw new InvalidDataException("일반 파일만 휴지통으로 이동할 수 있습니다.");
        var record=Record(relative,previous);record.DeleteOnly=true;record.PreviousPath=TrashPath(relative,"deleted");
        var journal=NewJournal();JsonFile.Save(journal,record);await ContinueAsync(journal,record,new(),token);
    }
    public async Task RestoreAsync(string from,string original,CancellationToken token)
    {
        if(!from.StartsWith(".safesync-trash/",StringComparison.Ordinal))throw new InvalidDataException("클라우드 휴지통 경로가 아닙니다.");
        var item=await remote.StatAsync(from,token) ?? throw new FileNotFoundException("휴지통 파일이 없습니다.");
        if(item.Folder || !item.Binary || (item.Hash.Length==0 && item.Sha256.Length==0))throw new IOException("검증 가능한 일반 파일만 복구할 수 있습니다.");
        var record=Record(original,await remote.StatAsync(original,token));record.Restore=true;record.Staged=RemotePath.Normalize(from);
        record.Snapshot=new("",item.Length,item.ModifiedUtc,item.CreatedUtc,item.Hash,item.Sha256);
        var journal=NewJournal();JsonFile.Save(journal,record);await ContinueAsync(journal,record,new(),token);
    }
    private void Validate(CloudTransaction record)
    {
        if(record.JobId!=job.Id || record.SourceRoot!=job.Source || record.Provider!=remote.Provider || record.Root!=remote.Root || record.AccountId!=remote.AccountId)
            throw new InvalidDataException("미완료 전송의 계정 또는 백업 위치가 현재 작업과 다릅니다.");
        RemotePath.Normalize(record.Relative);RemotePath.Normalize(record.PreviousPath);
        if(record.Relative.Length==0 || PathPolicy.Internal(record.Relative))throw new InvalidDataException("잘못된 전송 대상 경로입니다.");
        if(!record.PreviousPath.StartsWith(".safesync-trash/",StringComparison.Ordinal) && !record.PreviousPath.StartsWith(record.Relative+".SafeSync-conflict-",StringComparison.Ordinal))throw new InvalidDataException("잘못된 이전 파일 보관 경로입니다.");
        if(!record.DeleteOnly)
        {
            RemotePath.Normalize(record.Staged);
            if(record.Restore ? !record.Staged.StartsWith(".safesync-trash/",StringComparison.Ordinal) : !Regex.IsMatch(record.Staged,"^\\.safesync-staging/[a-f0-9]{32}\\.part$"))throw new InvalidDataException("잘못된 임시 업로드 경로입니다.");
            if(record.Snapshot==null || (record.Snapshot.Hash.Length==0 && record.Snapshot.Sha256.Length==0))throw new InvalidDataException("파일 검증 정보가 없습니다.");
            if(!record.Restore)
            {
                var local=PathPolicy.Relative(Path.GetRelativePath(store.Root,record.Snapshot.Path));
                if(!Regex.IsMatch(local,"^cloud-upload-v2/[a-f0-9]{32}/payload$"))throw new InvalidDataException("잘못된 로컬 업로드 사본 경로입니다.");
                PathPolicy.Combine(store.Root,local);
            }
        }
    }
    private async Task<RemoteItem?> ContinueAsync(string journal,CloudTransaction record,PauseGate pause,CancellationToken token)
    {
        Validate(record);await pause.WaitAsync(token);
        var destination=await remote.StatAsync(record.Relative,token);
        var prior=record.Previous==null ? null : await remote.StatAsync(record.PreviousPath,token);
        if(record.DeleteOnly)
        {
            if(record.Previous==null)throw new InvalidDataException("삭제 전 백업 정보가 없습니다.");
            if(destination==null && prior!=null && RemotePath.Same(record.Previous,prior)){File.Delete(journal);return null;}
            if(destination==null || !RemotePath.Same(record.Previous,destination) || prior!=null)throw new CloudConflictException(record.Relative,"삭제 처리 중 클라우드 파일이 변경되었습니다.");
            ValidateDeletion?.Invoke(record.Relative);
            var moved=await remote.MoveAsync(record.Relative,record.PreviousPath,token);
            if(!RemotePath.Same(record.Previous,moved))throw new CloudConflictException(record.Relative,"삭제된 파일의 내용이 예상과 다릅니다. 휴지통 사본을 보존했습니다.");
            File.Delete(journal);return null;
        }
        var snapshot=record.Snapshot!;
        if(destination!=null && RemotePath.Content(destination,snapshot)){await FinishAsync(journal,record,token);return destination;}
        if(destination!=null && record.StagedId.Length>0 && destination.Id==record.StagedId)
        {
            await RollbackAsync(journal,record,destination,token);
            throw new IOException("교체 파일 검증에 실패하여 해당 사본을 보존하고 이전 백업을 복구했습니다. 다시 시도합니다.");
        }
        var staged=await remote.StatAsync(record.Staged,token);
        if(staged==null)
        {
            if(record.Restore)throw new CloudConflictException(record.Relative,"복구할 클라우드 휴지통 파일이 사라졌습니다.");
            if(!File.Exists(snapshot.Path) || new FileInfo(snapshot.Path).Length!=snapshot.Length || await RemotePath.HashAsync(remote.Provider,snapshot.Path,token)!=snapshot.Hash)
                throw new CloudConflictException(record.Relative,"로컬 전송 사본의 검증에 실패했습니다. 기존 백업을 유지합니다.");
            if(record.StagedId.Length>0){ResetStage(journal,record);}
            staged=await remote.UploadAsync(snapshot,record.Staged,record.Session,()=>JsonFile.Save(journal,record),pause,token);
        }
        if(!RemotePath.Content(staged,snapshot))
        {
            if(!record.Restore)ResetStage(journal,record);
            throw new IOException("임시 업로드의 서비스 체크섬이 다릅니다. 기존 백업을 유지하고 다음 실행에서 새 세션으로 재시도합니다.");
        }
        record.StagedId=staged.Id;JsonFile.Save(journal,record);
        await pause.WaitAsync(token);destination=await remote.StatAsync(record.Relative,token);prior=record.Previous==null ? null : await remote.StatAsync(record.PreviousPath,token);
        if(destination!=null)
        {
            if(record.Previous==null || !RemotePath.Same(record.Previous,destination) || prior!=null)
                throw new CloudConflictException(record.Relative,"전송 중 기존 클라우드 파일이 변경되었습니다. 두 사본을 보존합니다.");
            var moved=await remote.MoveAsync(record.Relative,record.PreviousPath,token);
            if(!RemotePath.Same(record.Previous,moved))
            {
                await RestorePreviousAsync(record,token);
                throw new CloudConflictException(record.Relative,"기존 백업의 변경이 확인되어 교체를 중단했습니다.");
            }
        }
        else if(record.Previous!=null && (prior==null || !RemotePath.Same(record.Previous,prior)))
            throw new CloudConflictException(record.Relative,"이전 백업 사본을 확인하지 못해 교체를 중단했습니다.");
        // Cancellation is allowed here: the journal and retained old copy make
        // a restart deterministic even after a lost server response.
        var final=await remote.MoveAsync(record.Staged,record.Relative,token);
        if(!RemotePath.Content(final,snapshot))
        {
            await RollbackAsync(journal,record,final,token);
            throw new IOException("교체 후 검증에 실패하여 이전 백업을 복구했습니다.");
        }
        var confirmed=await remote.StatAsync(record.Relative,token);
        if(confirmed==null || confirmed.Id!=final.Id || !RemotePath.Content(confirmed,snapshot))throw new CloudConflictException(record.Relative,"최종 백업 확인 중 파일이 변경되었습니다.");
        await FinishAsync(journal,record,token);return confirmed;
    }
    private static void ResetStage(string journal,CloudTransaction record)
    {
        // A rejected copy is retained for inspection; never overwrite it.
        record.Staged=".safesync-staging/"+Guid.NewGuid().ToString("N")+".part";
        record.Session=new();record.StagedId="";JsonFile.Save(journal,record);
    }
    private async Task RollbackAsync(string journal,CloudTransaction record,RemoteItem rejected,CancellationToken token)
    {
        var current=await remote.StatAsync(record.Relative,token);
        if(current==null || current.Id!=record.StagedId || !RemotePath.Same(current,rejected))throw new CloudConflictException(record.Relative,"검증 중 파일이 다시 변경되어 자동 복구를 중단했습니다. 모든 사본을 보존합니다.");
        await remote.MoveAsync(record.Relative,TrashPath(record.Relative,"verification-failed"),token);
        await RestorePreviousAsync(record,token);
        if(!record.Restore)ResetStage(journal,record);
    }
    public HashSet<string> ProtectedTrashBatches()
    {
        var batches=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if(!Directory.Exists(JournalRoot))return batches;
        foreach(var path in Directory.EnumerateFiles(JournalRoot,"*.json"))
        {
            var record=JsonFile.Read<CloudTransaction>(path);
            if(record.Provider!=remote.Provider || record.Root!=remote.Root || record.AccountId!=remote.AccountId)continue;
            foreach(var value in new[]{record.PreviousPath,record.Restore ? record.Staged : ""})
                if(value.StartsWith(".safesync-trash/",StringComparison.Ordinal))
                {RemotePath.Normalize(value);var parts=value.Split('/');if(parts.Length>=3)batches.Add(parts[1]);}
        }
        return batches;
    }
    private async Task RestorePreviousAsync(CloudTransaction record,CancellationToken token)
    {
        if(record.Previous==null || await remote.StatAsync(record.Relative,token)!=null)return;
        var previous=await remote.StatAsync(record.PreviousPath,token);
        if(previous!=null && RemotePath.Same(record.Previous,previous))await remote.MoveAsync(record.PreviousPath,record.Relative,token);
    }
    private async Task FinishAsync(string journal,CloudTransaction record,CancellationToken token)
    {
        if(record.Snapshot is {} snapshot && !record.Restore && File.Exists(snapshot.Path) && await RemotePath.HashAsync(remote.Provider,snapshot.Path,token)==snapshot.Hash)File.Delete(snapshot.Path);
        File.Delete(journal);
    }
    public async Task<IReadOnlyList<(string Relative,Exception Error)>> RecoverAsync(IReadOnlyDictionary<string,ConflictAction>? resolutions,PauseGate pause,CancellationToken token)
    {
        var failures=new List<(string,Exception)>();if(!Directory.Exists(JournalRoot))return failures;
        foreach(var journal in Directory.EnumerateFiles(JournalRoot,job.Id+".*.json"))
        {
            pause.ThrowIfStopRequested();
            token.ThrowIfCancellationRequested();var record=JsonFile.Read<CloudTransaction>(journal);Validate(record);
            try
            {
                if(resolutions?.ContainsKey(record.Relative)==true)
                {
                    await RestorePreviousAsync(record,token);
                    // Keep abandoned immutable data for inspection; never replay
                    // this older intent after the user starts a new resolution.
                    File.Move(journal,journal+".abandoned");continue;
                }
                await ContinueAsync(journal,record,pause,token);
            }
            catch(Exception ex) when(ex is IOException or HttpRequestException || (NetworkFailures.IsTransient(ex) && !token.IsCancellationRequested && !pause.IsStopRequested)){failures.Add((record.Relative,ex));}
        }
        return failures;
    }
}
