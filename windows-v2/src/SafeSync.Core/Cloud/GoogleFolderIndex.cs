using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SafeSync.Core.Cloud;

public interface IRemoteFolderIndex
{
    void SeedFolders(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> ambiguous);
}

public sealed partial class GoogleDriveStore : IRemoteFolderIndex
{
    private bool folderIndexEnabled;
    private readonly ConcurrentDictionary<string,string> folders=new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string,SemaphoreSlim> folderCreation=new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string,Lazy<Task<List<JsonElement>>>> childReads=new();
    private readonly ConcurrentDictionary<string,Lazy<Task<string?>>> folderReads=new();

    public void SeedFolders(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> ambiguous)
    {
        folders.Clear();folderIndexEnabled=true;var conflicts=ambiguous.ToArray();
        foreach(var (path,item) in known)
            if(item.Folder && !conflicts.Any(c=>path.Equals(c,StringComparison.OrdinalIgnoreCase)||path.StartsWith(c+"/",StringComparison.OrdinalIgnoreCase)))
                folders[RemotePath.Normalize(path)]=Id(item.Id);
    }
    private void InvalidateFolders(string path="")
    {
        foreach(var key in folders.Keys)
            if(path.Length==0 || key.Equals(path,StringComparison.OrdinalIgnoreCase)||key.StartsWith(path+"/",StringComparison.OrdinalIgnoreCase))folders.TryRemove(key,out _);
    }
    // Share overlapping reads only. Completed, failed and canceled responses
    // are never retained as freshness/absence authority for a later operation.
    private static async Task<T> SharedRead<T>(ConcurrentDictionary<string,Lazy<Task<T>>> reads,string key,Func<Task<T>> run,CancellationToken token)
    {
        var pending=reads.GetOrAdd(key,_=>new(run,LazyThreadSafetyMode.ExecutionAndPublication));
        var task=pending.Value;
        _=task.ContinueWith(_=>((ICollection<KeyValuePair<string,Lazy<Task<T>>>>)reads).Remove(new(key,pending)),CancellationToken.None,TaskContinuationOptions.ExecuteSynchronously,TaskScheduler.Default);
        return await task.WaitAsync(token);
    }
    private async Task<string?> CachedFolder(string directory,bool mutation,CancellationToken token)
    {
        if(!folderIndexEnabled || directory.Length==0 || rootId=="root")return null;
        var chain=new List<(string Path,string Name,string Id,string Parent)>();string path="",parent=rootId;
        foreach(var part in directory.Split('/'))
        {
            path=path.Length==0 ? part : path+"/"+part;
            if(!folders.TryGetValue(path,out var id))return null;
            chain.Add((path,part,id,parent));parent=id;
        }
        return await SharedRead(folderReads,(mutation ? "write|" : "read|")+directory,async()=>
        {
            var requests=new List<string>{"/drive/v3/files/"+Id(rootId)+"?"+CloudJson.Query(("fields","id,name,mimeType,trashed,appProperties"),("supportsAllDrives","true"))};
            foreach(var node in chain)
                requests.Add(mutation
                    ? "/drive/v3/files?"+CloudJson.Query(("q",$"'{Id(node.Parent)}' in parents and trashed = false"),("pageSize","1000"),("fields","nextPageToken,files(id,name,mimeType)"),("supportsAllDrives","true"),("includeItemsFromAllDrives","true"))
                    : "/drive/v3/files/"+Id(node.Id)+"?"+CloudJson.Query(("fields","id,name,mimeType,parents,trashed"),("supportsAllDrives","true")));
            var answers=await FolderBatch(requests,token);
            var rootMetadata=answers[0];
            if(rootMetadata==null || rootMetadata.Value.True("trashed") || rootMetadata.Value.String("id")!=rootId || !Parse(rootMetadata.Value).Folder || requireManagedRoot && !Managed(rootMetadata.Value))
            {InvalidateFolders();throw new CloudBindingException("백업 루트가 삭제·변경되었거나 접근할 수 없습니다. 기존 백업을 보존합니다.");}
            for(int i=0;i<chain.Count;i++)
            {
                var node=chain[i];var response=answers[i+1];bool valid=false;
                if(mutation && response!=null)
                {
                    // A batch page is not a complete name/duplicate check if
                    // the directory has more than 1000 entries.
                    var items=response.Value.String("nextPageToken").Length>0
                        ? await ChildrenCore(node.Parent,token,true)
                        : response.Value.GetProperty("files").EnumerateArray().Select(x=>x.Clone()).ToList();
                    var matches=items.Where(x=>x.String("name").Equals(node.Name,StringComparison.OrdinalIgnoreCase)).ToArray();
                    if(matches.Length>1){InvalidateFolders(node.Path);throw new CloudDuplicateNameException(node.Path);}
                    valid=matches.Length==1 && matches[0].String("id")==node.Id && Parse(matches[0]).Folder;
                }
                else if(response!=null)
                    valid=!response.Value.True("trashed") && Parse(response.Value).Folder && response.Value.String("id")==node.Id && response.Value.String("name").Equals(node.Name,StringComparison.OrdinalIgnoreCase) &&
                        response.Value.TryGetProperty("parents",out var parents) && parents.EnumerateArray().Any(p=>p.GetString()==node.Parent);
                if(!valid){InvalidateFolders(node.Path);return null;}
            }
            return chain[^1].Id;
        },token);
    }
    private async Task<List<JsonElement?>> FolderBatch(IReadOnlyList<string> requests,CancellationToken token)
    {
        var result=new List<JsonElement?>();
        foreach(var chunk in requests.Chunk(100))
        {
            var boundary="safesync_"+Guid.NewGuid().ToString("N");
            var body=string.Concat(chunk.Select((path,i)=>$"--{boundary}\r\nContent-Type: application/http\r\nContent-ID: <{i}>\r\n\r\nGET {path} HTTP/1.1\r\n\r\n"))+"--"+boundary+"--\r\n";
            using var response=await http.SendAsync(()=>new HttpRequestMessage(HttpMethod.Post,"https://www.googleapis.com/batch/drive/v3")
            {Content=new StringContent(body,Encoding.UTF8,"multipart/mixed"){Headers={ContentType=new("multipart/mixed"){Parameters={new("boundary",boundary)}}}}},token);
            var responseBoundary=response.Content.Headers.ContentType?.Parameters.FirstOrDefault(p=>p.Name=="boundary")?.Value?.Trim('"');
            if(string.IsNullOrWhiteSpace(responseBoundary))throw new IOException("폴더 일괄 확인 응답 경계가 없습니다.");
            var answers=new JsonElement?[chunk.Length];var seen=new HashSet<int>();
            foreach(var part in (await response.Content.ReadAsStringAsync(token)).Split("--"+responseBoundary,StringSplitOptions.RemoveEmptyEntries))
            {
                var match=Regex.Match(part,@"Content-ID:\s*<response-(\d+)>",RegexOptions.IgnoreCase);
                if(!match.Success)continue;
                if(!int.TryParse(match.Groups[1].Value,out int index) || index>=chunk.Length || !seen.Add(index))throw new IOException("폴더 일괄 확인 응답이 중복되거나 범위를 벗어났습니다.");
                var status=Regex.Match(part,@"HTTP/\d(?:\.\d)?\s+(\d{3})");
                if(!status.Success)throw new IOException("폴더 일괄 확인 상태가 없습니다.");
                var code=int.Parse(status.Groups[1].Value);if(code==404)continue;
                if(code!=200)throw new CloudApiException((HttpStatusCode)code,"Google Drive folder batch");
                int start=part.IndexOf('{');if(start<0)throw new IOException("폴더 확인 응답 내용이 없습니다.");
                using var json=JsonDocument.Parse(part[start..].Trim());answers[index]=json.RootElement.Clone();
            }
            if(seen.Count!=chunk.Length)throw new IOException("폴더 일괄 확인 응답이 누락되었습니다.");
            result.AddRange(answers);
        }
        return result;
    }
}
