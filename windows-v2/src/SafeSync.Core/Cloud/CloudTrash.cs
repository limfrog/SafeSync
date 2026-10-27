using System.Runtime.CompilerServices;

namespace SafeSync.Core.Cloud;

public sealed record CloudTrashItem(string StoragePath,string RelativePath,DateTime DeletedAt,RemoteItem Item,string OriginalPath)
{
    public string BatchId=>RecoveryBatch.FromPath(StoragePath);
    [System.Text.Json.Serialization.JsonIgnore] public string VerificationStatus {get;set;}="미검증";
    public string Name=>RemotePath.Name(RelativePath);
    public string DeletedAtText=>DeletedAt.ToString("yyyy-MM-dd HH:mm:ss");
    public string SizeText=>Item.Length.ToString("N0")+" B";
    public long Length=>Item.Length;
}
public sealed class CloudTrash(IRemoteStore remote,CloudPublisher publisher,ConfigStore? store=null)
{
    public async IAsyncEnumerable<CloudTrashItem> ListAsync([EnumeratorCancellation] CancellationToken token)
    {
        if(store!=null)
        {
            var catalog=new RemoteCatalog(store,remote,".safesync-trash");await catalog.RefreshAsync(false,new(),token);
            foreach(var pair in catalog.State.Items)
            {
                if(pair.Value.Folder)continue;var parts=pair.Key.Split('/');if(parts.Length<3 || !TrashDates.TryParse(parts[1],out var date))continue;
                var relative=string.Join('/',parts.Skip(2));yield return new(pair.Key,relative,date,pair.Value,remote.Provider+" / "+remote.Root+" / "+relative);
            }
            catalog.Acknowledge();yield break;
        }
        if((await remote.StatAsync(".safesync-trash",token))?.Folder!=true)yield break;
        foreach(var batch in await remote.ListAsync(".safesync-trash",token))
        {
            if(!batch.Folder || !TrashDates.TryParse(batch.Name,out var date))continue;
            var prefix=".safesync-trash/"+PathPolicy.Relative(batch.Name)+"/";var folders=new Stack<string>();folders.Push(prefix.TrimEnd('/'));
            while(folders.Count>0)
            {
                token.ThrowIfCancellationRequested();var directory=folders.Pop();var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach(var item in await remote.ListAsync(directory,token))
                {
                    if(!names.Add(item.Name))throw new IOException("휴지통에 중복 파일 이름이 있습니다.");
                    var path=directory+"/"+PathPolicy.Relative(item.Name);
                    if(item.Folder){folders.Push(path);continue;}
                    var original=path[prefix.Length..];yield return new(path,original,date,item,remote.Provider+" / "+remote.Root+" / "+original);
                }
            }
        }
    }
    public async Task OperateAsync(CloudTrashItem item,bool restore,CancellationToken token)
    {
        RemotePath.Normalize(item.StoragePath);RemotePath.Normalize(item.RelativePath);
        var parts=item.StoragePath.Split('/');
        if(parts.Length<3 || parts[0]!=".safesync-trash" || string.Join('/',parts.Skip(2))!=item.RelativePath)throw new InvalidDataException("잘못된 휴지통 항목입니다.");
        if(publisher.ProtectedTrashBatches().Contains(parts[1]))throw new IOException("미완료 전송이 보존 중인 사본입니다. 전송 복구 후 처리하세요.");
        var current=await remote.StatAsync(item.StoragePath,token);
        if(current==null || current.Folder || !RemotePath.Same(current,item.Item))throw new IOException("휴지통 항목이 변경되었습니다. 새로고침하세요.");
        if(restore){await ArchiveIntegrity.VerifyRemoteAsync(store,remote,item,token);await publisher.RestoreAsync(item.StoragePath,item.RelativePath,token);}
        else await remote.DeleteAsync(item.StoragePath,token);
    }
}
