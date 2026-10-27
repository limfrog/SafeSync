using System.Security.Cryptography;

namespace SafeSync.Core.Cloud;

public sealed record RemoteItem(string Id,string Name,bool Folder,long Length,DateTime ModifiedUtc,DateTime CreatedUtc,string Hash,string Revision,bool Binary=true,string Sha256="");
public sealed class UploadSession
{
    public string SessionProtected {get;set;}="";
    public long Offset {get;set;}
    public string FileId {get;set;}="";
}
public sealed record UploadSnapshot(string Path,long Length,DateTime ModifiedUtc,DateTime CreatedUtc,string Hash,string Sha256="");
public interface IRemoteStore
{
    string Provider {get;}
    string Root {get;}
    string AccountId {get;}
    Task InitializeAsync(CancellationToken token);
    Task<RemoteItem?> StatAsync(string relative,CancellationToken token);
    Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken token);
    Task EnsureFolderAsync(string directory,CancellationToken token);
    Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string relative,UploadSession session,Action save,PauseGate pause,CancellationToken token);
    Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token);
    Task DownloadAsync(string relative,string localPath,CancellationToken token);
    Task DeleteAsync(string relative,CancellationToken token);
}
public static class RemotePath
{
    // Provider version counters may advance for a metadata-only operation.
    // Reuse requires the same ID/name/type/times and verified content hashes.
    public static bool VerifiedSame(RemoteItem a,RemoteItem b)=>Same(a,b) && a.Name==b.Name && a.CreatedUtc==b.CreatedUtc &&
        a.Binary==b.Binary && (a.Sha256.Length>0 && b.Sha256.Length>0 || a.Hash.Length>0 && b.Hash.Length>0);
    public static string Normalize(string relative)=>relative.Length==0 ? "" : PathPolicy.Relative(relative);
    public static string Parent(string relative){relative=Normalize(relative);var slash=relative.LastIndexOf('/');return slash<0 ? "" : relative[..slash];}
    public static string Name(string relative){relative=Normalize(relative);var slash=relative.LastIndexOf('/');return relative[(slash+1)..];}
    public static bool Same(RemoteItem a,RemoteItem b)=>a.Id==b.Id && a.Folder==b.Folder && a.Length==b.Length && a.Hash==b.Hash && a.ModifiedUtc==b.ModifiedUtc && (a.Sha256.Length==0 || b.Sha256.Length==0 || a.Sha256==b.Sha256);
    public static bool Content(RemoteItem item,UploadSnapshot snapshot)=>!item.Folder && item.Binary && item.Length==snapshot.Length && (item.Sha256.Length>0 && snapshot.Sha256.Length>0 ? item.Sha256.Equals(snapshot.Sha256,StringComparison.OrdinalIgnoreCase) : item.Hash.Length>0 && item.Hash.Equals(snapshot.Hash,StringComparison.OrdinalIgnoreCase));
    public static async Task<(string Md5,string Sha256)> GoogleHashesAsync(string path,CancellationToken token)
    {
        using var timing=OperationLog.Measure("file.md5_sha256",path);
        using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,1024*1024,FileOptions.Asynchronous|FileOptions.SequentialScan);
        using var md5=IncrementalHash.CreateHash(HashAlgorithmName.MD5);using var sha=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);var buffer=new byte[1024*1024];int count;
        while((count=await input.ReadAsync(buffer,token))>0){md5.AppendData(buffer,0,count);sha.AppendData(buffer,0,count);}
        return(Convert.ToHexStringLower(md5.GetHashAndReset()),Convert.ToHexStringLower(sha.GetHashAndReset()));
    }
    public static async Task<string> HashAsync(string provider,string path,CancellationToken token)
    {
        using var timing=OperationLog.Measure("file.provider_hash",path);
        using var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,1024*1024,FileOptions.Asynchronous|FileOptions.SequentialScan);
        if(provider=="GoogleDrive")return Convert.ToHexStringLower(await MD5.HashDataAsync(file,token));
        if(provider!="Dropbox")throw new ArgumentException("Unknown cloud provider.");
        using var total=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);var block=new byte[4*1024*1024];
        while(true)
        {
            int filled=0,read;
            while(filled<block.Length && (read=await file.ReadAsync(block.AsMemory(filled),token))>0)filled+=read;
            if(filled==0)break;total.AppendData(SHA256.HashData(block.AsSpan(0,filled)));
        }
        return Convert.ToHexStringLower(total.GetHashAndReset());
    }
}
