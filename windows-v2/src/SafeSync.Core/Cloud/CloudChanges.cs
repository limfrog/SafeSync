using System.Net;
using System.Text.Json;

namespace SafeSync.Core.Cloud;

public sealed partial class GoogleDriveStore : IRemoteChanges,IRemoteBatch,IRemoteParallel
{
    public async Task<string> CaptureCursorAsync(CancellationToken token)
    {
        var response=await http.JsonAsync(HttpMethod.Get,Api+"changes/startPageToken?supportsAllDrives=true",null,token);
        var cursor=response.String("startPageToken");if(cursor.Length==0)throw new IOException("Google Drive 변경 기준점이 없습니다.");return cursor;
    }
    public async Task<RemoteChanges> ChangesAsync(string cursor,IReadOnlyDictionary<string,RemoteItem> known,CancellationToken token)
    {
        InvalidateFolders();
        var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var byId=known.GroupBy(p=>p.Value.Id).ToDictionary(g=>g.Key,g=>g.First().Key,StringComparer.Ordinal);
        var resolved=new Dictionary<string,string?>(StringComparer.Ordinal){{rootId,""}};
        // Resolve current parent ancestry instead of trusting an old cached path
        // after a folder move. Account-wide changes outside our root are ignored.
        async Task<string?> Resolve(string id,HashSet<string> visiting)
        {
            if(resolved.TryGetValue(id,out var cached))return cached;
            if(!visiting.Add(id) || visiting.Count>128)throw new IOException("Google Drive 폴더 경로가 순환합니다.");
            var metadata=await Metadata(id,token);string? path=null;
            if(metadata!=null && !metadata.Value.True("trashed") && metadata.Value.TryGetProperty("parents",out var parents))
            foreach(var parent in parents.EnumerateArray())
            {
                var prefix=await Resolve(parent.GetString()!,visiting);
                if(prefix!=null){path=prefix.Length==0 ? PathPolicy.Relative(metadata.Value.String("name")) : prefix+"/"+PathPolicy.Relative(metadata.Value.String("name"));break;}
            }
            visiting.Remove(id);resolved[id]=path;return path;
        }
        var seen=new HashSet<string>(StringComparer.Ordinal);
        while(true)
        {
            if(!seen.Add(cursor))throw new IOException("Google Drive 변경 페이지가 반복됩니다.");
            var query=CloudJson.Query(("pageToken",cursor),("pageSize","1000"),("supportsAllDrives","true"),("includeItemsFromAllDrives","true"),("includeRemoved","true"),("fields","nextPageToken,newStartPageToken,changes(fileId,removed,file("+Fields+"))"));
            var page=await http.JsonAsync(HttpMethod.Get,Api+"changes?"+query,null,token);
            foreach(var change in page.GetProperty("changes").EnumerateArray())
            {
                string id=change.String("fileId");if(byId.TryGetValue(id,out var old))paths.Add(old);
                if(change.True("removed") || !change.TryGetProperty("file",out var file) || file.True("trashed"))continue;
                if(file.TryGetProperty("parents",out var parents))foreach(var parent in parents.EnumerateArray())
                {
                    var prefix=await Resolve(parent.GetString()!,new());if(prefix==null)continue;
                    var relative=prefix.Length==0 ? PathPolicy.Relative(file.String("name")) : prefix+"/"+PathPolicy.Relative(file.String("name"));paths.Add(relative);break;
                }
            }
            var next=page.String("nextPageToken");if(next.Length>0){cursor=next;continue;}
            cursor=page.String("newStartPageToken");if(cursor.Length==0)throw new IOException("Google Drive 변경 기준점 응답이 없습니다.");return new(cursor,paths.ToArray());
        }
    }
    public async Task<IReadOnlyDictionary<string,RemoteItem?>> StatManyAsync(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> paths,CancellationToken token)
    {
        var result=new Dictionary<string,RemoteItem?>(StringComparer.OrdinalIgnoreCase);
        foreach(var batch in paths.Distinct(StringComparer.OrdinalIgnoreCase).Chunk(100))
        {
            var eligible=batch.Where(p=>known.TryGetValue(p,out var item) && item.Id.Length>0 && !item.Folder).ToArray();
            if(eligible.Length>0)
            {
                string boundary="safesync_"+Guid.NewGuid().ToString("N");
                string body=string.Join("",eligible.Select((p,i)=>"--"+boundary+"\r\nContent-Type: application/http\r\nContent-ID: <"+i+">\r\n\r\nGET /drive/v3/files/"+Id(known[p].Id)+"?supportsAllDrives=true&fields="+Uri.EscapeDataString(Fields)+" HTTP/1.1\r\n\r\n"))+"--"+boundary+"--\r\n";
                using var response=await http.SendAsync(()=>new HttpRequestMessage(HttpMethod.Post,"https://www.googleapis.com/batch/drive/v3"){Content=new StringContent(body,System.Text.Encoding.UTF8,"multipart/mixed"){Headers={ContentType=new("multipart/mixed"){Parameters={new("boundary",boundary)}}}}},token);
                var content=await response.Content.ReadAsStringAsync(token);
                var responseBoundary=response.Content.Headers.ContentType?.Parameters.FirstOrDefault(p=>p.Name=="boundary")?.Value?.Trim('"') ?? throw new IOException("Google Drive 일괄 응답 경계가 없습니다.");
                var observed=new HashSet<int>();
                foreach(var part in content.Split("--"+responseBoundary,StringSplitOptions.RemoveEmptyEntries))
                {
                    var idMatch=System.Text.RegularExpressions.Regex.Match(part,@"Content-ID:\s*<response-(\d+)>",System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                    if(!idMatch.Success)continue;int index=int.Parse(idMatch.Groups[1].Value);if(index>=eligible.Length || !observed.Add(index))throw new IOException("일괄 응답 항목이 중복되거나 범위를 벗어났습니다.");
                    var status=System.Text.RegularExpressions.Regex.Match(part,@"HTTP/\d(?:\.\d)?\s+(\d{3})");if(!status.Success)throw new IOException("일괄 응답 상태가 없습니다.");
                    int code=int.Parse(status.Groups[1].Value);if(code==404){result[eligible[index]]=null;continue;}if(code!=200)throw new CloudApiException((HttpStatusCode)code,"Google Drive metadata batch");
                    int start=part.IndexOf('{');if(start<0)throw new IOException("일괄 응답 내용이 없습니다.");using var document=JsonDocument.Parse(part[start..].Trim());var item=Parse(document.RootElement);
                    // Verify current parent/name to avoid trusting a stale ID after
                    // an external move. Unexpected changes use a fresh path lookup.
                    var parentPath=RemotePath.Parent(eligible[index]);string? expectedParent=parentPath.Length==0 ? rootId : known.GetValueOrDefault(parentPath)?.Id;
                    bool parentMatches=expectedParent!=null && document.RootElement.TryGetProperty("parents",out var parents) && parents.EnumerateArray().Any(v=>v.GetString()==expectedParent);
                    result[eligible[index]]=parentMatches && item.Name.Equals(RemotePath.Name(eligible[index]),StringComparison.Ordinal) && !document.RootElement.True("trashed") && RemotePath.Same(item,known[eligible[index]]) ? item : await StatAsync(eligible[index],token);
                }
                if(observed.Count!=eligible.Length)throw new IOException("일괄 응답에서 파일 정보가 누락되었습니다.");
            }
            foreach(var relative in batch.Where(p=>!result.ContainsKey(p)))result[relative]=await StatAsync(relative,token);
        }
        return result;
    }
}

public sealed partial class DropboxStore : IRemoteChanges
{
    public async Task<string> CaptureCursorAsync(CancellationToken token)
    {
        var page=await Rpc("files/list_folder/get_latest_cursor",new{path=Full(""),recursive=true,include_deleted=true,include_non_downloadable_files=true},token);
        var cursor=page.String("cursor");if(cursor.Length==0)throw new IOException("Dropbox 변경 기준점이 없습니다.");return cursor;
    }
    public async Task<RemoteChanges> ChangesAsync(string cursor,IReadOnlyDictionary<string,RemoteItem> known,CancellationToken token)
    {
        var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);var pages=new HashSet<string>();
        while(true)
        {
            if(!pages.Add(cursor))throw new IOException("Dropbox 변경 페이지가 반복됩니다.");
            var page=await Rpc("files/list_folder/continue",new{cursor},token);
            foreach(var entry in page.GetProperty("entries").EnumerateArray())
            {
                var path=entry.String("path_display");if(path.Length==0)path=entry.String("path_lower");
                if(!path.StartsWith(Root+"/",StringComparison.OrdinalIgnoreCase))continue;
                paths.Add(PathPolicy.Relative(path[(Root.Length+1)..]));
            }
            cursor=page.String("cursor");if(cursor.Length==0)throw new IOException("Dropbox 변경 기준점 응답이 없습니다.");
            if(!page.True("has_more"))return new(cursor,paths.ToArray());
        }
    }
}
