using System.Security.Cryptography;
using System.Text;
using SafeSync.Core.Cloud;
namespace SafeSync.Core;

public static class ArchiveIntegrity
{
    private sealed record LocalProof(string Path,long Length,string Sha256);
    private sealed record RemoteProof(string Provider,string Account,string Root,string Path,RemoteItem Item);
    private static string Key(string value)=>Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static string LocalProofPath(string root,string storage)=>PathPolicy.Combine(root,".safesync-integrity/"+Key(Path.GetRelativePath(root,storage).Replace('\\','/').ToLowerInvariant())+".json");
    public static void RecordLocal(string root,string storage,string hash)
    {
        if(!PathPolicy.Inside(Path.Combine(root,".safesync-trash"),storage) || !File.Exists(storage))return;
        PathPolicy.RejectLinks(root,storage);var proofPath=LocalProofPath(root,storage);PathPolicy.RejectLinks(root,proofPath);
        JsonFile.Save(proofPath,new LocalProof(Path.GetRelativePath(root,storage).Replace('\\','/'),new FileInfo(storage).Length,hash));
    }
    public static void ForgetLocal(string root,string storage){var path=LocalProofPath(root,storage);PathPolicy.RejectLinks(root,path);if(File.Exists(path))File.Delete(path);}
    public static async Task<bool> VerifyLocalAsync(string root,TrashItem item,CancellationToken token)
    {
        if(!PathPolicy.Inside(Path.Combine(root,".safesync-trash"),item.StoragePath) || !string.Equals(PathPolicy.Combine(root,item.RelativePath),item.OriginalPath,StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("복원 경로가 휴지통 기록과 다릅니다.");
        PathPolicy.RejectLinks(root,item.StoragePath);var proofPath=LocalProofPath(root,item.StoragePath);PathPolicy.RejectLinks(root,proofPath);
        var hash=await VerifiedFiles.HashAsync(item.StoragePath,token);
        if(!File.Exists(proofPath))return false;
        var proof=JsonFile.Read<LocalProof>(proofPath);
        if(!string.Equals(Path.GetRelativePath(root,item.StoragePath).Replace('\\','/'),proof.Path,StringComparison.OrdinalIgnoreCase) ||
           proof.Length!=new FileInfo(item.StoragePath).Length || proof.Sha256.Length!=64 || !proof.Sha256.Equals(hash,StringComparison.OrdinalIgnoreCase))
            throw new IOException("보관 시점의 체크섬과 다릅니다. 손상 가능성이 있어 복원하지 않았습니다.");
        return true;
    }
    private static string RemoteProofPath(ConfigStore store,IRemoteStore remote,string path)=>Path.Combine(store.Root,"trash-integrity",Key(remote.Provider+"|"+remote.AccountId+"|"+remote.Root+"|"+path)+".json");
    public static void RecordRemote(ConfigStore store,IRemoteStore remote,string path,RemoteItem item)
    {
        if(!path.StartsWith(".safesync-trash/",StringComparison.Ordinal))return;
        RemotePath.Normalize(path);JsonFile.Save(RemoteProofPath(store,remote,path),new RemoteProof(remote.Provider,remote.AccountId,remote.Root,path,item));
    }
    public static async Task<bool> VerifyRemoteAsync(ConfigStore? store,IRemoteStore remote,CloudTrashItem item,CancellationToken token,bool download=true)
    {
        RemotePath.Normalize(item.StoragePath);if(!item.StoragePath.StartsWith(".safesync-trash/",StringComparison.Ordinal))throw new InvalidDataException("휴지통 밖의 파일입니다.");
        var current=await remote.StatAsync(item.StoragePath,token) ?? throw new IOException("검증할 사본이 사라졌습니다.");
        if(!RemotePath.Same(current,item.Item))throw new IOException("목록 확인 후 사본이 변경되었습니다. 새로고침하세요.");
        bool known=false;
        if(store!=null && File.Exists(RemoteProofPath(store,remote,item.StoragePath)))
        {
            var proof=JsonFile.Read<RemoteProof>(RemoteProofPath(store,remote,item.StoragePath));known=true;
            if(proof.Provider!=remote.Provider || proof.Account!=remote.AccountId || proof.Root!=remote.Root || proof.Path!=item.StoragePath || !RemotePath.Same(proof.Item,current))
                throw new IOException("보관 시점의 클라우드 체크섬 또는 파일 ID가 다릅니다. 복원을 중단했습니다.");
        }
        if(!download)return known;
        var folder=Path.Combine(Path.GetTempPath(),"SafeSync-restore-check-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(folder);
        try
        {
            var file=Path.Combine(folder,"payload");await remote.DownloadAsync(item.StoragePath,file,token);
            if(new FileInfo(file).Length!=current.Length || current.Hash.Length==0 || await RemotePath.HashAsync(remote.Provider,file,token)!=current.Hash)
                throw new IOException("보관 파일을 읽은 결과가 서비스 체크섬과 다릅니다. 복원을 중단했습니다.");
            if(!RemotePath.Same(current,await remote.StatAsync(item.StoragePath,token) ?? throw new IOException("검증 중 사본이 사라졌습니다.")))throw new IOException("검증 중 사본이 바뀌었습니다.");
            return known;
        }
        finally{if(Directory.Exists(folder))Directory.Delete(folder,true);}
    }
}
