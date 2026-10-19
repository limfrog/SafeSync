namespace SafeSync.Core.Cloud;

public sealed record DuplicateGroup(string Relative,string ParentId,RemoteItem[] Items);
public sealed record DuplicatePlan(RemoteItem? Selected,DuplicateGroup[] Groups);
public interface IRemoteDuplicates
{
    Task<DuplicatePlan> InspectDuplicatesAsync(string relative,CancellationToken token);
    Task<IReadOnlyList<RemoteItem>> CandidatesAsync(string relative,CancellationToken token);
    Task PreserveDuplicatesAsync(DuplicatePlan expected,CancellationToken token);
}

public static class RemoteDuplicates
{
    // A name (or a timestamp) is never proof of identity. All physical copies
    // must match the guarded source, including across duplicate parent folders.
    public static async Task<RemoteItem?> IdenticalAsync(IRemoteStore remote,string source,string relative,CancellationToken token)
    {
        if(remote is not IRemoteDuplicates duplicates || !File.Exists(source))return null;
        using var guard=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read);
        var info=new FileInfo(source);var candidates=await duplicates.CandidatesAsync(relative,token);
        if(candidates.Count==0 || candidates.Any(c=>c.Folder || !c.Binary || c.Length!=info.Length || c.Hash.Length+c.Sha256.Length==0))return null;
        string hash,sha="";
        if(remote.Provider=="GoogleDrive"){var hashes=await RemotePath.GoogleHashesAsync(source,token);hash=hashes.Md5;sha=hashes.Sha256;}
        else hash=await RemotePath.HashAsync(remote.Provider,source,token);
        var snapshot=new UploadSnapshot(source,info.Length,info.LastWriteTimeUtc,info.CreationTimeUtc,hash,sha);
        if(!candidates.All(c=>RemotePath.Content(c,snapshot)))return null;
        var after=await duplicates.CandidatesAsync(relative,token);
        if(!Same(candidates,after))throw new CloudConflictException(relative,"동일 내용 확인 중 중복 사본이 변경되었습니다. 다시 비교하세요.");
        return candidates.OrderBy(c=>c.Id,StringComparer.Ordinal).First();
    }
    public static bool Same(IReadOnlyList<RemoteItem> a,IReadOnlyList<RemoteItem> b)=>a.Count==b.Count && a.OrderBy(i=>i.Id,StringComparer.Ordinal).Zip(b.OrderBy(i=>i.Id,StringComparer.Ordinal)).All(p=>p.First==p.Second);
    public static bool Same(DuplicatePlan? a,DuplicatePlan? b)=>a==null ? b==null : b!=null && a.Selected==b.Selected && a.Groups.Length==b.Groups.Length && a.Groups.Zip(b.Groups).All(p=>p.First.Relative==p.Second.Relative && p.First.ParentId==p.Second.ParentId && Same(p.First.Items,p.Second.Items));
}
