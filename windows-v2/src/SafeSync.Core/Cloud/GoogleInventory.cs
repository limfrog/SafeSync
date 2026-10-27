using System.Text.Json;

namespace SafeSync.Core.Cloud;

public sealed record RemoteNode(RemoteItem Item,string Parent);
public sealed record RemoteInventory(string Cursor,Dictionary<string,RemoteNode> Nodes,string Root);
public interface IRemoteInventory
{
    Task<RemoteInventory> InventoryAsync(string cursor,IReadOnlyDictionary<string,RemoteNode>? prior,PauseGate pause,CancellationToken token);
}

public sealed partial class GoogleDriveStore : IRemoteInventory
{
    // Parent IDs, not repeated path walks, form the inventory. Every change page
    // is read before resolving ancestry; older events for the same ID collapse.
    public async Task<RemoteInventory> InventoryAsync(string cursor,IReadOnlyDictionary<string,RemoteNode>? prior,PauseGate pause,CancellationToken token)
    {
        using var timing=OperationLog.Measure("prepare.id_inventory");
        var rootMetadata=await Metadata(rootId,token);
        if(rootMetadata==null || rootMetadata.Value.True("trashed") || !Parse(rootMetadata.Value).Folder || requireManagedRoot && !Managed(rootMetadata.Value))
            throw new CloudBindingException("Google Drive 백업 루트에 접근할 수 없습니다. 기존 백업을 보존합니다.");
        bool full=prior==null || cursor.Length==0;
        var nodes=full ? new Dictionary<string,RemoteNode>(StringComparer.Ordinal) : new Dictionary<string,RemoteNode>(prior!,StringComparer.Ordinal);
        var oldFolders=nodes.Where(p=>p.Value.Item.Folder).Select(p=>p.Key).ToHashSet(StringComparer.Ordinal);
        nodes[rootId]=Node(rootMetadata.Value);
        if(full)
        {
            cursor=await CaptureCursorAsync(token);
            await Expand(new[]{rootId});
        }
        else
        {
            var seen=new HashSet<string>(StringComparer.Ordinal);
            while(true)
            {
                await pause.WaitAsync(token);pause.ThrowIfStopRequested();
                if(!seen.Add(cursor))throw new IOException("Google Drive 변경 페이지가 반복됩니다.");
                var query=CloudJson.Query(("pageToken",cursor),("pageSize","1000"),("supportsAllDrives","true"),("includeItemsFromAllDrives","true"),("includeRemoved","true"),("fields","nextPageToken,newStartPageToken,changes(fileId,removed,file("+Fields+"))"));
                var page=await http.JsonAsync(HttpMethod.Get,Api+"changes?"+query,null,token);
                foreach(var change in page.GetProperty("changes").EnumerateArray())
                {
                    var id=Id(change.String("fileId"));
                    if(change.True("removed") || !change.TryGetProperty("file",out var file) || file.True("trashed"))
                    {if(id==rootId)throw new CloudBindingException("Google Drive 백업 루트가 변경되었습니다.");nodes.Remove(id);continue;}
                    if(file.String("id")!=id)throw new IOException("Google Drive 변경 응답 ID가 다릅니다.");
                    if(id==rootId && (requireManagedRoot && !Managed(file) || !Parse(file).Folder))throw new CloudBindingException("백업 루트의 보호 정보가 변경되었습니다.");
                    nodes[id]=Node(file);
                }
                var next=page.String("nextPageToken");if(next.Length>0){cursor=next;continue;}
                cursor=page.String("newStartPageToken");if(cursor.Length==0)throw new IOException("Google Drive 변경 기준점 응답이 없습니다.");break;
            }
            // Resolve each unknown ancestor once, in batches. A forbidden or
            // incomplete batch aborts; it never commits an empty inventory.
            var missing=new HashSet<string>(StringComparer.Ordinal);
            for(int depth=0;;depth++)
            {
                var ids=nodes.Where(p=>p.Key!=rootId).Select(p=>p.Value.Parent).Where(id=>id.Length>0 && !nodes.ContainsKey(id) && !missing.Contains(id)).Distinct(StringComparer.Ordinal).ToArray();
                if(ids.Length==0)break;
                if(depth>=128)throw new IOException("Google Drive 상위 폴더 경로가 너무 깊습니다.");
                await pause.WaitAsync(token);pause.ThrowIfStopRequested();
                var urls=ids.Select(id=>"/drive/v3/files/"+Id(id)+"?"+CloudJson.Query(("fields",Fields),("supportsAllDrives","true"))).ToArray();
                var answers=await FolderBatch(urls,token);
                for(int i=0;i<ids.Length;i++)
                    if(answers[i] is {} answer && !answer.True("trashed"))
                    {if(answer.String("id")!=ids[i])throw new IOException("상위 폴더 응답 ID가 다릅니다.");nodes[ids[i]]=Node(answer);}
                    else missing.Add(ids[i]);
            }
            var paths=Paths(nodes,rootId);
            // An unknown folder moved into our root may carry children absent
            // from the feed. Enumerate those subtrees by ID, never by path.
            var expand=nodes.Where(p=>p.Value.Item.Folder && !oldFolders.Contains(p.Key) && p.Key!=rootId && paths.TryGetValue(p.Key,out var path) && !PathPolicy.Internal(path)).Select(p=>p.Key).ToArray();
            await Expand(expand);
        }
        var reachable=Paths(nodes,rootId);
        nodes=nodes.Where(p=>p.Key==rootId || reachable.TryGetValue(p.Key,out var path) && !PathPolicy.Internal(path)).ToDictionary(p=>p.Key,p=>p.Value,StringComparer.Ordinal);
        OperationLog.Event("inventory.ready","drive",total:nodes.Count,detail:$"full={full}");
        return new(cursor,nodes,rootId);

        async Task Expand(IEnumerable<string> roots)
        {
            var queue=new Queue<(string Id,string Page)>();var visited=new HashSet<string>(StringComparer.Ordinal);
            foreach(var id in roots.Distinct(StringComparer.Ordinal))queue.Enqueue((id,""));
            while(queue.Count>0)
            {
                await pause.WaitAsync(token);pause.ThrowIfStopRequested();token.ThrowIfCancellationRequested();
                var batch=new List<(string Id,string Page)>();
                while(queue.Count>0 && batch.Count<100)
                {var item=queue.Dequeue();if(!visited.Add(item.Id+"|"+item.Page))continue;batch.Add(item);}
                if(batch.Count==0)continue;
                var requests=batch.Select(p=>"/drive/v3/files?"+CloudJson.Query(("q",$"'{Id(p.Id)}' in parents and trashed = false"),("pageSize","1000"),("fields","nextPageToken,files("+Fields+")"),("supportsAllDrives","true"),("includeItemsFromAllDrives","true"),("pageToken",p.Page))).ToArray();
                OperationLog.Event("http.batch_items","drive.inventory_children",completed:batch.Count);
                var answers=await FolderBatch(requests,token);
                for(int i=0;i<batch.Count;i++)
                {
                    var page=answers[i] ?? throw new IOException("목록 확인 중 폴더가 사라졌습니다. 다음 실행에서 다시 확인합니다.");
                    foreach(var file in page.GetProperty("files").EnumerateArray())
                    {
                        var node=Node(file);if(node.Parent!=batch[i].Id)throw new IOException("폴더 목록의 상위 관계가 다릅니다.");
                        if(batch[i].Id==rootId && PathPolicy.Internal(node.Item.Name))continue;
                        nodes[node.Item.Id]=node;
                        if(node.Item.Folder)queue.Enqueue((node.Item.Id,""));
                    }
                    var next=page.String("nextPageToken");if(next.Length>0)queue.Enqueue((batch[i].Id,next));
                }
            }
        }
    }
    private static RemoteNode Node(JsonElement json)
    {
        var item=Parse(json);Id(item.Id);
        var parents=json.TryGetProperty("parents",out var list) ? list.EnumerateArray().Select(v=>v.GetString()!).ToArray() : [];
        if(parents.Length>1)throw new IOException("Google Drive 상위 폴더 관계를 확인할 수 없습니다.");
        return new(item,parents.Length==1 ? Id(parents[0]) : "");
    }
    internal static Dictionary<string,string> Paths(IReadOnlyDictionary<string,RemoteNode> nodes,string root)
    {
        var paths=new Dictionary<string,string>(StringComparer.Ordinal){{root,""}};var outside=new HashSet<string>(StringComparer.Ordinal);
        string? Resolve(string id,HashSet<string> visiting)
        {
            if(paths.TryGetValue(id,out var path))return path;
            if(outside.Contains(id) || !nodes.TryGetValue(id,out var node))return null;
            if(!visiting.Add(id) || visiting.Count>128)throw new IOException("Google Drive 폴더 경로가 순환하거나 너무 깊습니다.");
            var parent=Resolve(node.Parent,visiting);visiting.Remove(id);
            if(parent==null){outside.Add(id);return null;}
            var relative=parent.Length==0 ? PathPolicy.Relative(node.Item.Name) : parent+"/"+PathPolicy.Relative(node.Item.Name);
            paths[id]=relative;return relative;
        }
        foreach(var id in nodes.Keys)Resolve(id,new(StringComparer.Ordinal));
        return paths;
    }
}
