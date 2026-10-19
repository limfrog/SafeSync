using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace SafeSync.Core.Cloud;

public sealed partial class GoogleDriveStore(CloudHttp http,ISecretVault vault,string root,string accountId) : IRemoteStore
{
    private const string Api="https://www.googleapis.com/drive/v3/";
    private const string Fields="id,name,mimeType,size,modifiedTime,createdTime,md5Checksum,sha256Checksum,version,parents,trashed";
    public string Provider=>"GoogleDrive";
    public string Root=>rootId.Length==0 ? Id(root) : rootId;
    public string AccountId=>accountId;
    private string rootId="";
    private readonly SemaphoreSlim folderCreation=new(1,1);
    private static string Id(string value)=>Regex.IsMatch(value,"^[a-zA-Z0-9_-]{1,200}$") ? value : throw new InvalidDataException("Google Drive 폴더 ID가 잘못되었습니다.");
    private async Task<JsonElement?> Metadata(string id,CancellationToken token)
    {
        try{return await http.JsonAsync(HttpMethod.Get,Api+"files/"+Id(id)+"?"+CloudJson.Query(("fields",Fields),("supportsAllDrives","true")),null,token);}
        catch(CloudApiException ex) when(ex.NotFound){return null;}
    }
    public async Task InitializeAsync(CancellationToken token)
    {
        var profile=await http.JsonAsync(HttpMethod.Get,Api+"about?fields=user",null,token);
        if(profile.GetProperty("user").String("permissionId")!=accountId)throw new InvalidOperationException("백업 작업에 연결된 Google 계정과 현재 계정이 다릅니다.");
        var metadata=await Metadata(Root,token);
        if(metadata==null || metadata.Value.True("trashed") || !Parse(metadata.Value).Folder)throw new DirectoryNotFoundException("Google Drive 백업 폴더에 접근할 수 없습니다.");
        rootId=metadata.Value.String("id");Id(rootId);
    }
    private async Task<List<JsonElement>> Children(string parent,CancellationToken token)
    {
        Id(parent);var result=new List<JsonElement>();string next="";
        do
        {
            var query=CloudJson.Query(("q",$"'{parent}' in parents and trashed = false"),("pageSize","1000"),("fields","nextPageToken,files("+Fields+")"),("supportsAllDrives","true"),("includeItemsFromAllDrives","true"),("pageToken",next));
            var page=await http.JsonAsync(HttpMethod.Get,Api+"files?"+query,null,token);
            foreach(var file in page.GetProperty("files").EnumerateArray())result.Add(file.Clone());next=page.String("nextPageToken");
        }while(next.Length>0);
        return result;
    }
    private async Task<string?> Folder(string directory,bool create,CancellationToken token)
    {
        if(!create)return await FolderCore(directory,false,token);
        await folderCreation.WaitAsync(token);try{return await FolderCore(directory,true,token);}finally{folderCreation.Release();}
    }
    private async Task<string?> FolderCore(string directory,bool create,CancellationToken token)
    {
        RemotePath.Normalize(directory);
        if(rootId.Length==0)throw new InvalidOperationException("Cloud store is not initialized.");
        var rootMetadata=await Metadata(rootId,token);
        if(rootMetadata==null || rootMetadata.Value.True("trashed") || !Parse(rootMetadata.Value).Folder)throw new IOException("Google Drive 백업 루트에 접근할 수 없습니다.");
        string current=rootId;
        foreach(var part in directory.Split('/',StringSplitOptions.RemoveEmptyEntries))
        {
            var matches=(await Children(current,token)).Where(f=>f.String("name").Equals(part,StringComparison.OrdinalIgnoreCase)).ToArray();
            if(matches.Length>1)throw new IOException("Google Drive에 이름이 중복된 폴더/파일이 있습니다: "+part);
            if(matches.Length==1)
            {
                if(!Parse(matches[0]).Folder)throw new IOException("폴더 경로에 일반 파일이 있습니다: "+part);
                current=matches[0].String("id");continue;
            }
            if(!create)return null;
            var folder=await http.JsonAsync(HttpMethod.Post,Api+"files?fields="+Uri.EscapeDataString(Fields)+"&supportsAllDrives=true",new{name=part,mimeType="application/vnd.google-apps.folder",parents=new[]{current}},token);
            var confirmed=(await Children(current,token)).Where(f=>f.String("name").Equals(part,StringComparison.OrdinalIgnoreCase)).ToArray();
            if(confirmed.Length!=1 || confirmed[0].String("id")!=folder.String("id"))throw new IOException("Google Drive 폴더 생성 충돌이 발생했습니다.");
            current=folder.String("id");
        }
        return current;
    }
    private async Task<JsonElement?> Find(string relative,CancellationToken token)
    {
        RemotePath.Normalize(relative);
        if(relative.Length==0)return await Metadata(rootId,token);
        var parent=await Folder(RemotePath.Parent(relative),false,token);if(parent==null)return null;
        var matches=(await Children(parent,token)).Where(f=>f.String("name").Equals(RemotePath.Name(relative),StringComparison.OrdinalIgnoreCase)).ToArray();
        if(matches.Length>1)throw new IOException("Google Drive에 이름이 중복된 파일이 있습니다: "+relative);
        return matches.Length==0 ? null : matches[0];
    }
    public async Task<RemoteItem?> StatAsync(string relative,CancellationToken token)
    {
        var metadata=await Find(relative,token);return metadata==null || metadata.Value.True("trashed") ? null : Parse(metadata.Value);
    }
    public async Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken token)
    {
        var folder=await Folder(directory,false,token) ?? throw new DirectoryNotFoundException("클라우드 폴더가 없습니다.");
        return (await Children(folder,token)).Select(Parse).ToArray();
    }
    public async Task EnsureFolderAsync(string directory,CancellationToken token){await Folder(directory,true,token);}
    private async Task<HttpResponseMessage> Put(string uri,byte[] bytes,long? start,long total,CancellationToken token)
    {
        CloudHttp.ValidateUri(new Uri(uri));
        return await http.SendAsync(()=>
        {
            var message=new HttpRequestMessage(HttpMethod.Put,uri){Content=new ByteArrayContent(bytes)};
            message.Content.Headers.ContentType=new("application/octet-stream");
            message.Content.Headers.ContentRange=start==null ? new ContentRangeHeaderValue(total) : new ContentRangeHeaderValue(start.Value,start.Value+bytes.Length-1,total);
            return message;
        },token,true);
    }
    private static long Accepted(HttpResponseMessage response)
    {
        if(!response.Headers.TryGetValues("Range",out var values))return 0;
        var match=Regex.Match(values.Single(),"^bytes=0-(\\d+)$");
        if(!match.Success || !long.TryParse(match.Groups[1].Value,out var last))throw new IOException("Google Drive 전송 위치 응답이 잘못되었습니다.");
        return checked(last+1);
    }
    public async Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string relative,UploadSession session,Action save,PauseGate pause,CancellationToken token)
    {
        if(!relative.StartsWith(".safesync-staging/",StringComparison.Ordinal))throw new InvalidDataException("직접 덮어쓰기 업로드는 허용하지 않습니다.");
        var existing=await StatAsync(relative,token);
        if(existing!=null){if(RemotePath.Content(existing,snapshot))return existing;throw new IOException("임시 파일의 해시가 다릅니다.");}
        string uri="";bool resumed=false;
        if(session.SessionProtected.Length>0)
        {
            uri=vault.Unprotect(session.SessionProtected);CloudHttp.ValidateUri(new Uri(uri));
            try
            {
                using var status=await Put(uri,[],null,snapshot.Length,token);
                if((int)status.StatusCode!=308)return Parse(await CloudJson.ReadAsync(status,token));
                session.Offset=Accepted(status);save();resumed=true;
            }
            catch(CloudApiException ex) when(ex.NotFound){session.SessionProtected="";session.Offset=0;save();}
        }
        if(!resumed)
        {
            var parent=await Folder(RemotePath.Parent(relative),true,token) ?? throw new IOException("업로드 폴더를 만들지 못했습니다.");
            if(session.FileId.Length==0)
            {
                var ids=await http.JsonAsync(HttpMethod.Get,Api+"files/generateIds?count=1&space=drive&type=files",null,token);
                session.FileId=Id(ids.GetProperty("ids")[0].GetString()!);save();
            }
            using var started=await http.SendAsync(()=>
            {
                var request=new HttpRequestMessage(HttpMethod.Post,"https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields="+Uri.EscapeDataString(Fields))
                {Content=CloudJson.Body(new{id=session.FileId,name=RemotePath.Name(relative),parents=new[]{parent},modifiedTime=snapshot.ModifiedUtc.ToString("O"),createdTime=snapshot.CreatedUtc.ToString("O")})};
                request.Headers.TryAddWithoutValidation("X-Upload-Content-Type","application/octet-stream");request.Headers.TryAddWithoutValidation("X-Upload-Content-Length",snapshot.Length.ToString(System.Globalization.CultureInfo.InvariantCulture));return request;
            },token);
            uri=started.Headers.Location?.AbsoluteUri ?? throw new IOException("Google Drive 업로드 세션 주소가 없습니다.");CloudHttp.ValidateUri(new Uri(uri));
            session.SessionProtected=vault.Protect(uri);session.Offset=0;save();
        }
        using var input=new FileStream(snapshot.Path,FileMode.Open,FileAccess.Read,FileShare.Read,1024*1024,FileOptions.Asynchronous);
        int noProgress=0;
        while(true)
        {
            await pause.WaitAsync(token);token.ThrowIfCancellationRequested();
            long offset=session.Offset;if(offset<0 || offset>snapshot.Length)throw new InvalidDataException("잘못된 Google 업로드 재개 위치입니다.");
            input.Position=offset;var size=(int)Math.Min(8L*1024*1024,snapshot.Length-offset);var bytes=new byte[size];await input.ReadExactlyAsync(bytes,token);
            using var uploaded=await Put(uri,bytes,size==0 ? null : offset,snapshot.Length,token);
            if((int)uploaded.StatusCode!=308){session.Offset=snapshot.Length;save();return Parse(await CloudJson.ReadAsync(uploaded,token));}
            var accepted=Accepted(uploaded);
            if(accepted<offset || accepted>offset+size || (accepted==offset && ++noProgress>1))throw new IOException("Google Drive 전송이 진행되지 않았습니다. 다음 실행에서 재개합니다.");
            session.Offset=accepted;save();
        }
    }
    public async Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token)
    {
        var source=await Find(from,token) ?? throw new FileNotFoundException("이동할 클라우드 파일이 없습니다.");
        if(await StatAsync(to,token)!=null)throw new IOException("이동 대상에 이미 파일이 있습니다.");
        var parent=await Folder(RemotePath.Parent(to),true,token) ?? throw new IOException("클라우드 대상 폴더가 없습니다.");
        var oldParents=source.GetProperty("parents").EnumerateArray().Select(v=>v.GetString()).Where(v=>!string.IsNullOrEmpty(v)).ToArray();
        var query=CloudJson.Query(("addParents",oldParents.Contains(parent) ? "" : parent),("removeParents",string.Join(',',oldParents.Where(p=>p!=parent))),("supportsAllDrives","true"),("fields",Fields));
        var moved=await http.JsonAsync(HttpMethod.Patch,Api+"files/"+Id(source.String("id"))+"?"+query,new{name=RemotePath.Name(to),modifiedTime=source.String("modifiedTime")},token);
        var confirmed=await StatAsync(to,token);
        if(confirmed==null || confirmed.Id!=moved.String("id"))throw new IOException("Google Drive 파일 이동 중 충돌이 발생했습니다.");
        return confirmed;
    }
    public async Task DownloadAsync(string relative,string localPath,CancellationToken token)
    {
        var item=await StatAsync(relative,token) ?? throw new FileNotFoundException();if(!item.Binary || item.Folder)throw new IOException("일반 파일만 내려받을 수 있습니다.");
        using var response=await http.SendAsync(()=>new HttpRequestMessage(HttpMethod.Get,Api+"files/"+Id(item.Id)+"?alt=media&supportsAllDrives=true"),token);
        await using var file=new FileStream(localPath,FileMode.CreateNew,FileAccess.Write,FileShare.None,1024*1024,true);await response.Content.CopyToAsync(file,token);file.Flush(true);
    }
    public async Task DeleteAsync(string relative,CancellationToken token)
    {
        if(!relative.StartsWith(".safesync-trash/",StringComparison.Ordinal) && !relative.StartsWith(".safesync-staging/",StringComparison.Ordinal))throw new InvalidDataException("휴지통/임시 파일만 삭제할 수 있습니다.");
        var item=await StatAsync(relative,token);if(item==null)return;
        using var response=await http.SendAsync(()=>new HttpRequestMessage(HttpMethod.Delete,Api+"files/"+Id(item.Id)+"?supportsAllDrives=true"),token);
    }
    private static RemoteItem Parse(JsonElement metadata)
    {
        var mime=metadata.String("mimeType");bool folder=mime=="application/vnd.google-apps.folder";
        return new(metadata.String("id"),metadata.String("name"),folder,metadata.Number("size"),metadata.Time("modifiedTime"),metadata.Time("createdTime"),metadata.String("md5Checksum"),metadata.String("version"),!mime.StartsWith("application/vnd.google-apps.",StringComparison.Ordinal),metadata.String("sha256Checksum"));
    }
}
