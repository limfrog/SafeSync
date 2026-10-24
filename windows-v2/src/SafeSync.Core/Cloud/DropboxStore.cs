using System.Globalization;
using System.Text.Json;

namespace SafeSync.Core.Cloud;

public sealed partial class DropboxStore(CloudHttp http,ISecretVault vault,string root,string accountId,string selectedFolderIdentity="") : IRemoteStore
{
    public string Provider=>"Dropbox";
    public string Root {get;}=NormalizeRoot(root);
    public string AccountId=>accountId;
    private string rootId="";
    private static string NormalizeRoot(string value)
    {
        if(value=="/" || value=="")return "";
        if(!value.StartsWith('/') || value.StartsWith("//"))throw new InvalidDataException("Dropbox 폴더 경로가 잘못되었습니다.");
        return "/"+PathPolicy.Relative(value.Trim('/')).ToLowerInvariant();
    }
    private string Full(string relative)=>Root+(relative.Length==0 ? "" : "/"+RemotePath.Normalize(relative));
    private Task<JsonElement> Rpc(string route,object? value,CancellationToken token)=>http.JsonAsync(HttpMethod.Post,"https://api.dropboxapi.com/2/"+route,value,token);
    public async Task InitializeAsync(CancellationToken token)
    {
        var profile=await Rpc("users/get_current_account",null,token);
        if(profile.String("account_id")!=accountId)throw new CloudBindingException("백업 작업에 연결된 Dropbox 계정과 현재 계정이 다릅니다.");
        if(Root.Length>0)
        {
            var entry=await StatAsync("",token);if(entry?.Folder!=true)throw new CloudBindingException("Dropbox 백업 폴더에 접근할 수 없습니다. 사용할 폴더를 다시 선택하세요.");
            if(selectedFolderIdentity.Length>0 && selectedFolderIdentity!=entry.Id)throw new CloudBindingException("선택한 Dropbox 폴더가 이동되거나 다른 폴더로 교체되었습니다. 사용할 폴더를 다시 선택하세요.");
            rootId=entry.Id;
        }
    }
    public async Task<RemoteItem?> StatAsync(string relative,CancellationToken token)
    {
        if(Root.Length==0 && relative.Length==0)return new("root","Dropbox",true,0,DateTime.MinValue,DateTime.MinValue,"","",false);
        try{return Parse(await Rpc("files/get_metadata",new{path=Full(relative),include_deleted=false},token));}
        catch(CloudApiException ex) when(ex.NotFound){return null;}
    }
    public async Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken token)
    {
        var result=new List<RemoteItem>();
        var response=await Rpc("files/list_folder",new{path=Full(directory),recursive=false,include_deleted=false,include_non_downloadable_files=true},token);
        while(true)
        {
            foreach(var entry in response.GetProperty("entries").EnumerateArray())result.Add(Parse(entry));
            if(!response.True("has_more"))return result;
            response=await Rpc("files/list_folder/continue",new{cursor=response.String("cursor")},token);
        }
    }
    private async Task CheckRoot(CancellationToken token)
    {
        if(Root.Length==0)return;
        var current=await StatAsync("",token);
        if(current?.Folder!=true || current.Id!=rootId)throw new IOException("Dropbox 백업 루트가 이동되거나 교체되었습니다.");
    }
    public async Task EnsureFolderAsync(string directory,CancellationToken token)
    {
        RemotePath.Normalize(directory);await CheckRoot(token);
        string current="";
        foreach(var part in directory.Split('/',StringSplitOptions.RemoveEmptyEntries))
        {
            current=current.Length==0 ? part : current+"/"+part;
            var existing=await StatAsync(current,token);
            if(existing!=null){if(!existing.Folder)throw new IOException("폴더 위치에 파일이 있습니다.");continue;}
            try{await Rpc("files/create_folder_v2",new{path=Full(current),autorename=false},token);}
            catch(CloudApiException ex) when(ex.Status==System.Net.HttpStatusCode.Conflict)
            {if((await StatAsync(current,token))?.Folder!=true)throw;}
        }
    }
    private async Task<JsonElement> Content(string route,object argument,byte[] bytes,CancellationToken token)
    {
        using var response=await http.SendAsync(()=>
        {
            var message=new HttpRequestMessage(HttpMethod.Post,"https://content.dropboxapi.com/2/"+route){Content=new ByteArrayContent(bytes)};
            message.Content.Headers.ContentType=new("application/octet-stream");
            // Default JSON escaping keeps non-ASCII file names valid in HTTP headers.
            message.Headers.TryAddWithoutValidation("Dropbox-API-Arg",JsonSerializer.Serialize(argument));return message;
        },token);
        var body=await response.Content.ReadAsStringAsync(token);
        if(string.IsNullOrWhiteSpace(body))return default;
        using var document=JsonDocument.Parse(body);return document.RootElement.Clone();
    }
    public async Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string relative,UploadSession session,Action save,PauseGate pause,CancellationToken token)
    {
        if(!relative.StartsWith(".safesync-staging/",StringComparison.Ordinal))throw new InvalidDataException("직접 덮어쓰기 업로드는 허용하지 않습니다.");
        await EnsureFolderAsync(RemotePath.Parent(relative),token);
        var existing=await StatAsync(relative,token);
        if(existing!=null){if(RemotePath.Content(existing,snapshot))return existing;throw new IOException("임시 업로드 위치의 해시가 다릅니다.");}
        if(session.SessionProtected.Length==0)
        {
            var started=await Content("files/upload_session/start",new{close=false},[],token);
            var id=started.String("session_id");if(id.Length==0)throw new IOException("Dropbox 전송 세션을 받지 못했습니다.");
            session.SessionProtected=vault.Protect(id);session.Offset=0;save();
        }
        var sessionId=vault.Unprotect(session.SessionProtected);
        using var input=new FileStream(snapshot.Path,FileMode.Open,FileAccess.Read,FileShare.Read,1024*1024,FileOptions.Asynchronous);
        long offset=session.Offset;
        if(offset<0 || offset>snapshot.Length)throw new InvalidDataException("잘못된 업로드 재개 위치입니다.");
        int repairs=0;
        while(true)
        {
            await pause.WaitAsync(token);token.ThrowIfCancellationRequested();input.Position=offset;
            var size=(int)Math.Min(8L*1024*1024,snapshot.Length-offset);var bytes=new byte[size];
            await input.ReadExactlyAsync(bytes,token);bool last=offset+size==snapshot.Length;
            object cursor=new{session_id=sessionId,offset};
            object argument=last ? new{cursor,commit=new{path=Full(relative),mode="add",autorename=false,strict_conflict=true,mute=true,client_modified=snapshot.ModifiedUtc.ToString("yyyy-MM-ddTHH:mm:ssZ",CultureInfo.InvariantCulture)}} : new{cursor,close=false};
            JsonElement response;
            try{response=await Content(last ? "files/upload_session/finish" : "files/upload_session/append_v2",argument,bytes,token);}
            catch(CloudApiException ex) when(ex.Status==System.Net.HttpStatusCode.Conflict)
            {
                // An ambiguous finish is reconciled by the unique staging path.
                var completed=await StatAsync(relative,token);if(completed!=null && RemotePath.Content(completed,snapshot))return completed;
                if(ex.CorrectOffset is {} accepted && accepted>=0 && accepted<=snapshot.Length && repairs++<3)
                {offset=accepted;session.Offset=accepted;save();continue;}
                if(ex.SessionExpired && repairs++<3)
                {
                    var restarted=await Content("files/upload_session/start",new{close=false},[],token);
                    sessionId=restarted.String("session_id");if(sessionId.Length==0)throw new IOException("Dropbox 세션 재시작에 실패했습니다.");
                    session.SessionProtected=vault.Protect(sessionId);offset=0;session.Offset=0;save();continue;
                }
                throw new IOException("Dropbox 전송 위치를 확인할 수 없습니다. 기존 백업은 유지됩니다.",ex);
            }
            offset+=size;session.Offset=offset;save();
            if(last)return Parse(response);
        }
    }
    public async Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token)
    {
        RemotePath.Normalize(from);RemotePath.Normalize(to);await CheckRoot(token);
        await EnsureFolderAsync(RemotePath.Parent(to),token);
        var response=await Rpc("files/move_v2",new{from_path=Full(from),to_path=Full(to),autorename=false,allow_shared_folder=false,allow_ownership_transfer=false},token);
        return Parse(response.GetProperty("metadata"));
    }
    public async Task DownloadAsync(string relative,string localPath,CancellationToken token)
    {
        using var response=await http.SendAsync(()=>
        {
            var request=new HttpRequestMessage(HttpMethod.Post,"https://content.dropboxapi.com/2/files/download");
            request.Headers.TryAddWithoutValidation("Dropbox-API-Arg",JsonSerializer.Serialize(new{path=Full(relative)}));return request;
        },token);
        await using var output=new FileStream(localPath,FileMode.CreateNew,FileAccess.Write,FileShare.None,1024*1024,true);
        await response.Content.CopyToAsync(output,token);output.Flush(true);
    }
    public async Task DeleteAsync(string relative,CancellationToken token)
    {
        bool diagnostic=System.Text.RegularExpressions.Regex.IsMatch(relative,"^SafeSync-test-(?:[a-f0-9]{32}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$",System.Text.RegularExpressions.RegexOptions.CultureInvariant|System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if(!diagnostic && !relative.StartsWith(".safesync-trash/",StringComparison.Ordinal) && !relative.StartsWith(".safesync-staging/",StringComparison.Ordinal))throw new InvalidDataException("휴지통/검증용 임시 파일 외의 직접 삭제는 허용하지 않습니다.");
        // Personal Dropbox apps cannot use the Business-only permanently_delete API.
        // This removes it from SafeSync trash; Dropbox's own recovery policy remains.
        await CheckRoot(token);await Rpc("files/delete_v2",new{path=Full(relative)},token);
    }
    private static RemoteItem Parse(JsonElement entry)=>new(entry.String("id"),entry.String("name"),entry.String(".tag")=="folder",entry.Number("size"),entry.Time("client_modified"),entry.Time("server_modified"),entry.String("content_hash"),entry.String("rev"),!entry.TryGetProperty("is_downloadable",out var downloadable)||downloadable.ValueKind!=JsonValueKind.False);
}
