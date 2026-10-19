using SafeSync.Core.Cloud;

namespace SafeSync.Core;

// An explicit decision belongs to the endpoints and metadata the user actually
// inspected, never to a later file or a newly rebound cloud account.
public sealed record ComparedFile(bool Exists,bool Folder,long Length,string Created,string Modified,string Identity,string Checksum="",string Revision="",bool Binary=true);
public sealed record FileComparison(string JobId,string SourceRoot,string BackupRoot,string Provider,string Account,string FolderId,
    string Relative,ComparedFile? Source,ComparedFile? Backup,string SourceError,string BackupError,string SourceRootIdentity="",string BackupRootIdentity="",DuplicatePlan? Duplicates=null)
{
    public bool Readable=>SourceError.Length==0 && BackupError.Length==0;
    public bool CanForward=>Readable && Source is {Exists:true,Folder:false} && Backup is not {Folder:true} && Backup?.Binary!=false;
    public bool CanReverse=>Readable && Backup is {Exists:true,Folder:false,Binary:true} && Source is not {Folder:true};
}

public sealed class ComparedResolutions : Dictionary<string,ConflictAction>
{
    public Dictionary<string,FileComparison> Comparisons {get;}=new(StringComparer.OrdinalIgnoreCase);
    public ComparedResolutions():base(StringComparer.OrdinalIgnoreCase){}
    public void Choose(FileComparison comparison,ConflictAction action){Add(comparison.Relative,action);Comparisons.Add(comparison.Relative,comparison);}
}

public static class FileComparisons
{
    public static async Task<FileComparison> ReadAsync(BackupJob job,string relative,IRemoteStore? remote,CancellationToken token)
    {
        relative=PathPolicy.Relative(relative);ComparedFile? a=null,b=null;DuplicatePlan? duplicates=null;string ae="",be="",sourceIdentity="",backupIdentity="";
        try{a=ReadLocal(job.Source,relative);sourceIdentity=OfflineJournal.RootIdentity(job.Source);}catch(Exception ex) when(ex is IOException or UnauthorizedAccessException){ae=ex.Message;}
        try
        {
            if(job.DestinationType=="Local"){b=ReadLocal(job.Destination,relative);backupIdentity=OfflineJournal.RootIdentity(job.Destination);}
            else
            {
                if(remote==null || remote.AccountId!=job.CloudAccountId)throw new IOException("작업의 클라우드 계정 연결을 확인하세요.");
                await remote.InitializeAsync(token);
                backupIdentity=(await remote.StatAsync("",token))?.Id ?? throw new DirectoryNotFoundException("백업 루트 폴더를 확인할 수 없습니다.");
                try{b=FromRemote(await remote.StatAsync(relative,token));}
                catch(CloudDuplicateNameException) when(remote is IRemoteDuplicates)
                {
                    duplicates=await ((IRemoteDuplicates)remote).InspectDuplicatesAsync(relative,token);b=FromRemote(duplicates.Selected);
                }
            }
        }
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or HttpRequestException){be=ex.Message;}
        return new(job.Id,job.Source,job.Destination,job.DestinationType,job.CloudAccountId,job.CloudFolderId,relative,a,b,ae,be,sourceIdentity,backupIdentity,duplicates);
    }

    public static ComparedFile? ReadLocal(string root,string relative)
    {
        if(!Directory.Exists(root))throw new DirectoryNotFoundException("위치에 연결할 수 없습니다: "+root);
        var path=PathPolicy.Combine(root,relative);PathPolicy.RejectLinks(root,path);
        FileAttributes attributes;
        try{attributes=File.GetAttributes(path);}
        catch(FileNotFoundException){return null;}
        catch(DirectoryNotFoundException){return null;}
        bool folder=(attributes&FileAttributes.Directory)!=0;
        FileSystemInfo info=folder ? new DirectoryInfo(path) : new FileInfo(path);info.Refresh();
        return new(true,folder,folder ? -1 : ((FileInfo)info).Length,info.CreationTimeUtc.ToString("O"),info.LastWriteTimeUtc.ToString("O"),OfflineJournal.FileIdentity(path).ToString());
    }
    public static ComparedFile? FromRemote(RemoteItem? item)=>item==null ? null : new(true,item.Folder,item.Length,item.CreatedUtc.ToString("O"),item.ModifiedUtc.ToString("O"),item.Id,item.Hash+"|"+item.Sha256,item.Revision,item.Binary);

    public static async Task VerifyAsync(BackupJob job,string relative,IRemoteStore? remote,IReadOnlyDictionary<string,ConflictAction>? choices,CancellationToken token)
    {
        if(choices is not ComparedResolutions checkedChoices || !checkedChoices.Comparisons.TryGetValue(relative,out var expected) || checkedChoices[relative]==ConflictAction.Ignore)return;
        if(expected.JobId!=job.Id || expected.SourceRoot!=job.Source || expected.BackupRoot!=job.Destination || expected.Provider!=job.DestinationType || expected.Account!=job.CloudAccountId || expected.FolderId!=job.CloudFolderId)
            throw new CloudConflictException(relative,"비교 후 작업의 위치 또는 계정이 변경되었습니다. 파일 정보를 다시 확인하세요.");
        var current=await ReadAsync(job,relative,remote,token);
        if(!expected.Readable || !current.Readable || current.Source!=expected.Source || current.Backup!=expected.Backup || current.SourceRootIdentity!=expected.SourceRootIdentity || current.BackupRootIdentity!=expected.BackupRootIdentity || !RemoteDuplicates.Same(expected.Duplicates,current.Duplicates))
            throw new CloudConflictException(relative,"비교 후 파일 정보가 변경되었거나 읽을 수 없습니다. 덮어쓰지 않았습니다. 정보를 다시 확인한 뒤 선택하세요.");
    }

    // Called inside the account-wide run gate. Validate the entire selection
    // before preserving any duplicate; no unchecked force-overwrite authority.
    public static async Task<bool> PrepareDuplicatesAsync(BackupJob job,IRemoteStore remote,IReadOnlyDictionary<string,ConflictAction>? choices,CancellationToken token)
    {
        if(choices is not ComparedResolutions checkedChoices || remote is not IRemoteDuplicates duplicates)return false;
        var selected=checkedChoices.Comparisons.Values.Where(c=>checkedChoices[c.Relative]!=ConflictAction.Ignore).ToArray();
        var groups=selected.Where(c=>c.Duplicates!=null).SelectMany(c=>c.Duplicates!.Groups).GroupBy(g=>g.Relative,StringComparer.OrdinalIgnoreCase).Select(g=>g.First()).OrderBy(g=>g.Relative.Count(c=>c=='/')).ToArray();
        if(groups.Length==0)return false;
        foreach(var comparison in selected)await VerifyAsync(job,comparison.Relative,remote,choices,token);
        foreach(var group in groups)await duplicates.PreserveDuplicatesAsync(new(null,[group]),token);
        foreach(var previous in selected)
        {
            var current=await ReadAsync(job,previous.Relative,remote,token);
            if(!current.Readable || current.Duplicates!=null || current.Source!=previous.Source || current.Backup!=previous.Backup || current.SourceRootIdentity!=previous.SourceRootIdentity || current.BackupRootIdentity!=previous.BackupRootIdentity)
                throw new CloudConflictException(previous.Relative,"중복 사본 보존 중 파일 정보가 변경되었습니다. 복사는 진행하지 않았습니다. 다시 비교하세요.");
            checkedChoices.Comparisons[previous.Relative]=current;
            if(checkedChoices[previous.Relative]==ConflictAction.NormalizeDuplicates){checkedChoices.Remove(previous.Relative);checkedChoices.Comparisons.Remove(previous.Relative);}
        }
        return true;
    }

    public static async Task RestoreAsync(ConfigStore store,BackupJob job,string relative,IRemoteStore? remote,RemoteItem? backup,CancellationToken token,IReadOnlyDictionary<string,ConflictAction>? choices=null)
    {
        var files=new VerifiedFiles();await files.RecoverAsync(job.Source,token);
        var source=PathPolicy.Combine(job.Source,relative);
        var before=ReadLocal(job.Source,relative);
        if(before?.Folder==true)throw new CloudConflictException(relative,"원본 폴더를 파일로 교체하지 않습니다.");
        string expected=before==null ? "" : await VerifiedFiles.HashAsync(source,token);
        if(ReadLocal(job.Source,relative)!=before)throw new CloudConflictException(relative,"복원 준비 중 원본이 변경되었습니다.");
        if(remote==null)
        {
            var path=PathPolicy.Combine(job.Destination,relative);var side=ReadLocal(job.Destination,relative);
            if(side==null || side.Folder)throw new CloudConflictException(relative,"복원할 백업 파일이 없습니다.");
            using var guard=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);
            if(ReadLocal(job.Destination,relative)!=side)throw new CloudConflictException(relative,"복원 준비 중 백업 파일이 변경되었습니다.");
            await VerifyAsync(job,relative,null,choices,token);
            await files.CopyAsync(path,job.Source,relative,token,expectedDestinationHash:expected);return;
        }
        if(backup==null || backup.Folder || !backup.Binary || (backup.Hash.Length==0 && backup.Sha256.Length==0))
            throw new CloudConflictException(relative,"검증 가능한 일반 백업 파일만 복원할 수 있습니다.");
        if(await remote.StatAsync(relative,token) is not {} current || !RemotePath.Same(backup,current))throw new CloudConflictException(relative,"비교 후 클라우드 백업이 변경되었습니다.");
        var directory=Path.Combine(store.Root,"cloud-download-v2",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);var temp=Path.Combine(directory,"payload");
        try
        {
            await remote.DownloadAsync(relative,temp,token);
            string hash="",sha="";
            if(remote.Provider=="GoogleDrive"){var hashes=await RemotePath.GoogleHashesAsync(temp,token);hash=hashes.Md5;sha=hashes.Sha256;}
            else hash=await RemotePath.HashAsync(remote.Provider,temp,token);
            if(!RemotePath.Content(backup,new(temp,new FileInfo(temp).Length,backup.ModifiedUtc,backup.CreatedUtc,hash,sha)))throw new IOException("다운로드 체크섬이 다릅니다. 기존 원본은 변경하지 않았습니다.");
            if(await remote.StatAsync(relative,token) is not {} after || !RemotePath.Same(backup,after))throw new CloudConflictException(relative,"다운로드 중 클라우드 백업이 변경되었습니다.");
            await VerifyAsync(job,relative,remote,choices,token);
            File.SetLastWriteTimeUtc(temp,backup.ModifiedUtc);
            if(backup.CreatedUtc.Year>1601)File.SetCreationTimeUtc(temp,backup.CreatedUtc);
            await files.CopyAsync(temp,job.Source,relative,token,expectedDestinationHash:expected);
        }
        finally{if(File.Exists(temp))File.Delete(temp);if(!Directory.EnumerateFileSystemEntries(directory).Any())Directory.Delete(directory);}
    }
}
