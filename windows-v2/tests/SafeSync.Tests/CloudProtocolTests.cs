using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class CloudProtocolTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var uri in new[]{"http://www.googleapis.com/","https://www.googleapis.com.evil.test/","https://user@www.googleapis.com/","https://www.googleapis.com:444/","https://evil.test/"})
        {bool rejected=false;try{CloudHttp.ValidateUri(new(uri));}catch(InvalidDataException){rejected=true;}check(rejected,"Untrusted cloud endpoint accepted");}
        int attempts=0,refresh=0;using(var client=new HttpClient(new Handler((request,ct)=>
        {
            attempts++;return Task.FromResult(attempts==1 ? new HttpResponseMessage(HttpStatusCode.Unauthorized) : Json(new{ok=true}));
        })))
        {
            var http=new CloudHttp(client,(force,ct)=>{if(force)refresh++;return Task.FromResult("synthetic-access");});
            var body=await http.JsonAsync(HttpMethod.Get,"https://www.googleapis.com/drive/v3/about",null,default);
            check(body.True("ok") && attempts==2 && refresh==1,"401 did not refresh exactly once");
        }
        var pkce=CloudAuthentication.NewPkce();check(pkce.Challenge==CloudAuthentication.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(pkce.Verifier))),"PKCE SHA256 mismatch");
        check(CloudAuthentication.ValidState(pkce.State,pkce.State) && !CloudAuthentication.ValidState(pkce.State,"wrong"),"OAuth state comparison failed");
        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        {
            var uri=CloudAuthentication.AuthorizationUri(provider,new(){ClientId="client",AppKey="key"},pkce.Challenge,pkce.State);
            check(uri.Scheme=="https" && uri.Query.Contains("S256") && uri.Query.Contains("127.0.0.1"),provider+" authorization is not PKCE loopback");
        }
        using(var listener=new TcpListener(IPAddress.Loopback,0))
        using(var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(10)))
        {
            listener.Start();var port=((IPEndPoint)listener.LocalEndpoint).Port;
            var receiving=CloudAuthentication.ReceiveCodeAsync(listener,pkce.State,timeout.Token);
            var bad=await Callback(port,"/?state=wrong&code=bad",timeout.Token);check(bad.Contains("400 Bad Request") && !receiving.IsCompleted,"Invalid OAuth state accepted");
            var good=await Callback(port,"/?state="+pkce.State+"&code=synthetic-code",timeout.Token);
            check(good.Contains("200 OK") && await receiving=="synthetic-code","Valid OAuth callback failed");
        }
        var vault=new TestVault();int exchanges=0;
        using(var client=new HttpClient(new Handler(async(request,ct)=>
        {
            var form=await request.Content!.ReadAsStringAsync(ct);check(form.Contains("grant_type=refresh_token") && form.Contains("refresh_token=synthetic-refresh"),"Refresh form missing token");
            exchanges++;return Json(new{access_token="synthetic-access-"+exchanges,expires_in=3600});
        })))
        {
            var auth=new CloudAuthentication(client,vault);var account=new CloudAccount {ClientId="client",RefreshTokenProtected=vault.Protect("synthetic-refresh")};
            var one=await auth.AccessAsync("GoogleDrive",account,false,default);var two=await auth.AccessAsync("GoogleDrive",account,false,default);
            check(one==two && exchanges==1,"Access token cache missed");
            check(await auth.AccessAsync("GoogleDrive",account,true,default)!=one && exchanges==2,"Forced token refresh failed");
        }
        var file=Path.Combine(root,"protocol-upload.bin");var bytes=new byte[8*1024*1024+123];for(int i=0;i<bytes.Length;i++)bytes[i]=(byte)(i%251);File.WriteAllBytes(file,bytes);
        var modified=DateTime.UtcNow.AddMinutes(-5);
        var snapshot=new UploadSnapshot(file,bytes.Length,modified,modified,await RemotePath.HashAsync("GoogleDrive",file,default));
        var drive=new DriveHandler(bytes,snapshot);using(var client=new HttpClient(drive))
        {
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),vault,"root","account");await remote.InitializeAsync(default);
            check(remote.Root=="root-id","Drive root alias not canonicalized");
            var listed=await remote.ListAsync("",default);check(listed.Count==2 && drive.PageTwoSeen,"Drive pagination failed");
            var session=new UploadSession();bool interrupted=false;
            try{await remote.UploadAsync(snapshot,".safesync-staging/test.part",session,()=>{},new(),default);}catch(HttpRequestException){interrupted=true;}
            check(interrupted && session.SessionProtected.Length>0 && session.Offset==0,"Drive interrupted upload was not persisted");
            var uploaded=await remote.UploadAsync(snapshot,".safesync-staging/test.part",session,()=>{},new(),default);
            check(RemotePath.Content(uploaded,snapshot) && drive.Uploaded.SequenceEqual(bytes) && drive.StatusQueries==1,"Drive resumable Range reconciliation failed");
            check(drive.ChunkStarts.SequenceEqual(new long[]{0,8*1024*1024}),"Drive resent accepted chunk");
        }
        snapshot=snapshot with{Hash=await RemotePath.HashAsync("Dropbox",file,default)};
        foreach(bool expire in new[]{false,true})
        {
            var dropbox=new DropboxHandler(bytes,snapshot,expire);using var client=new HttpClient(dropbox);
            var remote=new DropboxStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),vault,"/","account");await remote.InitializeAsync(default);
            var list=await remote.ListAsync("",default);check(list.Count==2 && dropbox.Continued,"Dropbox pagination failed");
            var session=new UploadSession {SessionProtected=vault.Protect(expire ? "expired" : "existing")};
            var uploaded=await remote.UploadAsync(snapshot,".safesync-staging/한글.part",session,()=>{},new(),default);
            check(RemotePath.Content(uploaded,snapshot) && dropbox.Uploaded.SequenceEqual(bytes),expire ? "Dropbox expired session did not restart" : "Dropbox incorrect_offset did not reconcile");
            check(expire ? dropbox.Starts==1 : dropbox.OffsetRepairs==1,"Dropbox session repair not exercised");
            await remote.DeleteAsync(".safesync-trash/batch/file",default);check(dropbox.Deleted,"Personal Dropbox delete_v2 not used");
        }
        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        {
            bool created=false,validBody=false;
            object Folder(string id,string name)=>provider=="GoogleDrive"
                ? new{id,name,mimeType="application/vnd.google-apps.folder",parents=new[]{"root-id"},trashed=false}
                : new Dictionary<string,object>{{".tag","folder"},{"id",id},{"name",name}};
            using var client=new HttpClient(new Handler(async(request,ct)=>
            {
                var path=request.RequestUri!.AbsolutePath;
                if(path.EndsWith("/about"))return Json(new{user=new{permissionId="account"}});
                if(path.EndsWith("get_current_account"))return Json(new{account_id="account"});
                if(path.EndsWith("/files/root") || path.EndsWith("/files/root-id"))return Json(Folder("root-id","Drive"));
                if(provider=="GoogleDrive" && request.Method==HttpMethod.Get && path.EndsWith("/files"))return Json(new{files=created ? new[]{Folder("created-id","새 폴더")} : Array.Empty<object>()});
                if(provider=="Dropbox" && path.EndsWith("get_metadata"))return created ? Json(Folder("created-id","새 폴더")) : Json(new{error_summary="path/not_found/"},HttpStatusCode.Conflict);
                if(request.Method==HttpMethod.Post && (path.EndsWith("/files") || path.EndsWith("create_folder_v2")))
                {
                    using var body=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));
                    validBody=provider=="GoogleDrive" ? body.RootElement.String("name")=="새 폴더" && body.RootElement.GetProperty("parents")[0].GetString()=="root-id" : body.RootElement.String("path")=="/새 폴더" && !body.RootElement.True("autorename");
                    created=true;return provider=="GoogleDrive" ? Json(Folder("created-id","새 폴더")) : Json(new{metadata=Folder("created-id","새 폴더")});
                }
                throw new Exception("Unexpected mock folder creation call: "+path);
            }));
            var http=new CloudHttp(client,(_,_)=>Task.FromResult("synthetic"));
            IRemoteStore remote=provider=="GoogleDrive" ? new GoogleDriveStore(http,vault,"root","account") : new DropboxStore(http,vault,"/","account");
            await remote.InitializeAsync(default);var path=await CloudFolders.CreateAsync(remote,"","새 폴더",default);
            check(path=="새 폴더" && validBody && created && (await remote.StatAsync(path,default))?.Id=="created-id",provider+" create folder API parent/name mismatch");
        }
        var empty=Path.Combine(root,"protocol-empty.bin");File.WriteAllBytes(empty,[]);
        var zero=new UploadSnapshot(empty,0,modified,modified,await RemotePath.HashAsync("GoogleDrive",empty,default));
        using(var client=new HttpClient(new DriveHandler([],zero,false)))
        {
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),vault,"root","account");await remote.InitializeAsync(default);
            check(RemotePath.Content(await remote.UploadAsync(zero,".safesync-staging/test.part",new(),()=>{},new(),default),zero),"Drive empty upload failed");
        }
        using(var client=new HttpClient(new DriveHandler(bytes,snapshot,false,true)))
        {
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),vault,"root","account");await remote.InitializeAsync(default);bool stopped=false;
            try{await remote.UploadAsync(snapshot,".safesync-staging/test.part",new(),()=>{},new(),default);}catch(IOException){stopped=true;}
            check(stopped,"Drive non-progressing session loop was not bounded");
        }
        bool renamed=false,parentsUnchanged=false,timePreserved=false;
        using(var client=new HttpClient(new Handler(async(request,ct)=>
        {
            object Metadata(string id,string name,bool folder=false)=>new{id,name,mimeType=folder ? "application/vnd.google-apps.folder" : "application/octet-stream",size="10",modifiedTime=modified.ToString("O"),createdTime=modified.ToString("O"),md5Checksum="hash",parents=new[]{"root-id"},version="1",trashed=false};
            var path=request.RequestUri!.AbsolutePath;
            if(path.EndsWith("/about"))return Json(new{user=new{permissionId="account"}});
            if(path.EndsWith("/files/root") || path.EndsWith("/files/root-id"))return Json(Metadata("root-id","Drive",true));
            if(request.Method==HttpMethod.Get && path.EndsWith("/files"))return Json(new{files=new[]{Metadata("file-id",renamed ? "renamed.txt" : "original.txt")}});
            if(request.Method==HttpMethod.Patch && path.EndsWith("/files/file-id"))
            {
                parentsUnchanged=!request.RequestUri.Query.Contains("addParents") && !request.RequestUri.Query.Contains("removeParents");
                using var body=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));timePreserved=body.RootElement.String("modifiedTime")==modified.ToString("O");
                renamed=true;return Json(Metadata("file-id","renamed.txt"));
            }
            throw new Exception("Unexpected mock Drive rename call");
        })))
        {
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),vault,"root","account");await remote.InitializeAsync(default);
            var moved=await remote.MoveAsync("original.txt","renamed.txt",default);
            check(moved.Id=="file-id" && renamed && parentsUnchanged && timePreserved,"Drive same-folder rename changed parents or timestamp");
        }
    }
    private static async Task<string> Callback(int port,string path,CancellationToken ct)
    {
        using var client=new TcpClient();await client.ConnectAsync(IPAddress.Loopback,port,ct);await using var stream=client.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes("GET "+path+" HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"),ct);
        using var reader=new StreamReader(stream);return await reader.ReadToEndAsync(ct);
    }
    public static HttpResponseMessage Json(object value,HttpStatusCode status=HttpStatusCode.OK)=>new(status){Content=new StringContent(JsonSerializer.Serialize(value),Encoding.UTF8,"application/json")};
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> run) : HttpMessageHandler
    {protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)=>run(request,ct);}
    private sealed class DriveHandler(byte[] expected,UploadSnapshot snapshot,bool interrupt=true,bool noProgress=false) : HttpMessageHandler
    {
        public List<byte> Uploaded {get;}=[];public List<long> ChunkStarts {get;}=[];public bool PageTwoSeen;public int StatusQueries;
        private bool interrupted;
        private object File(string id,string name,bool folder=false)=>new{id,name,mimeType=folder ? "application/vnd.google-apps.folder" : "application/octet-stream",size=snapshot.Length.ToString(),modifiedTime=snapshot.ModifiedUtc.ToString("O"),createdTime=snapshot.CreatedUtc.ToString("O"),md5Checksum=snapshot.Hash,parents=new[]{"root-id"},version="1",trashed=false};
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)
        {
            var uri=request.RequestUri!;var path=uri.AbsolutePath;
            if(path.EndsWith("/about"))return Json(new{user=new{permissionId="account"}});
            if(path.EndsWith("/files/root") || path.EndsWith("/files/root-id"))return Json(File("root-id","Drive",true));
            if(path.EndsWith("/files/generateIds"))return Json(new{ids=new[]{"generated"}});
            if(request.Method==HttpMethod.Get && path.EndsWith("/files"))
            {
                var query=Uri.UnescapeDataString(uri.Query);
                if(query.Contains("'staging'"))return Json(new{files=Array.Empty<object>()});
                if(query.Contains("pageToken=second")){PageTwoSeen=true;return Json(new{files=new[]{File("other","other.txt")}});}
                return Json(new{files=new[]{File("staging",".safesync-staging",true)},nextPageToken="second"});
            }
            if(request.Method==HttpMethod.Post && path.Contains("/upload/"))
            {var response=Json(new{});response.Headers.Location=new Uri("https://www.googleapis.com/upload/session?upload_id=synthetic");return response;}
            if(request.Method==HttpMethod.Put && path.EndsWith("/session"))
            {
                var bytes=await request.Content!.ReadAsByteArrayAsync(ct);var range=request.Content.Headers.ContentRange!;
                if(snapshot.Length==0)return Json(File("generated","test.part"));
                if(noProgress)return new HttpResponseMessage((HttpStatusCode)308);
                if(bytes.Length==0 && range.From==null){StatusQueries++;var status=new HttpResponseMessage((HttpStatusCode)308);if(Uploaded.Count>0)status.Headers.TryAddWithoutValidation("Range","bytes=0-"+(Uploaded.Count-1));return status;}
                if(range.From!=Uploaded.Count)throw new Exception("Unexpected Drive range");ChunkStarts.Add(range.From!.Value);Uploaded.AddRange(bytes);
                if(interrupt && !interrupted){interrupted=true;throw new HttpRequestException("Simulated accepted chunk, lost connection");}
                if(Uploaded.Count!=expected.Length)throw new Exception("Drive incomplete final chunk");return Json(File("generated","test.part"));
            }
            throw new Exception("Unexpected mock Drive call: "+request.Method+" "+path);
        }
    }
    private sealed class DropboxHandler(byte[] expected,UploadSnapshot snapshot,bool expire) : HttpMessageHandler
    {
        public List<byte> Uploaded {get;}=expire ? [] : expected[..3].ToList();public bool Continued,Deleted;public int Starts,OffsetRepairs;
        private bool expiredOnce;
        private object File(string name)=>new Dictionary<string,object>{{".tag","file"},{"id","id"},{"name",name},{"size",snapshot.Length},{"client_modified",snapshot.ModifiedUtc.ToString("O")},{"server_modified",snapshot.CreatedUtc.ToString("O")},{"content_hash",snapshot.Hash},{"rev","1"}};
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct)
        {
            var route=request.RequestUri!.AbsolutePath;
            if(route.EndsWith("get_current_account"))return Json(new{account_id="account"});
            if(route.EndsWith("list_folder"))return Json(new{entries=new[]{File("one.txt")},has_more=true,cursor="cursor"});
            if(route.EndsWith("list_folder/continue")){Continued=true;return Json(new{entries=new[]{File("two.txt")},has_more=false});}
            if(route.EndsWith("get_metadata"))
            {
                using var body=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(ct));var path=body.RootElement.String("path");
                if(path=="/.safesync-staging")return Json(new Dictionary<string,object>{{".tag","folder"},{"id","staging"},{"name",".safesync-staging"}});
                return Json(new{error_summary="path/not_found/"},HttpStatusCode.Conflict);
            }
            if(route.EndsWith("upload_session/start")){Starts++;return Json(new{session_id="new"});}
            if(route.EndsWith("append_v2") || route.EndsWith("upload_session/finish"))
            {
                var header=request.Headers.GetValues("Dropbox-API-Arg").Single();if(header.Any(c=>c>127))throw new Exception("Non ASCII Dropbox API header");
                using var argument=JsonDocument.Parse(header);var cursor=argument.RootElement.GetProperty("cursor");
                if(expire && !expiredOnce){expiredOnce=true;return Json(new{error_summary="lookup_failed/not_found/"},HttpStatusCode.Conflict);}
                if(cursor.Number("offset")!=Uploaded.Count){OffsetRepairs++;return Json(new{error_summary="lookup_failed/incorrect_offset/",error=new{lookup_failed=new{incorrect_offset=new{correct_offset=Uploaded.Count}}}},HttpStatusCode.Conflict);}
                Uploaded.AddRange(await request.Content!.ReadAsByteArrayAsync(ct));
                if(route.EndsWith("upload_session/finish"))return Json(File("한글.part"));
                return new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent("")};
            }
            if(route.EndsWith("delete_v2")){Deleted=true;return Json(new{metadata=File("deleted")});}
            throw new Exception("Unexpected mock Dropbox call: "+route);
        }
    }
}
internal sealed class TestVault : ISecretVault
{
    public string Protect(string plain)=>plain.Length==0 ? "" : "test:"+Convert.ToBase64String(Encoding.UTF8.GetBytes(plain));
    public string Unprotect(string encrypted,byte[]? legacyKey=null)=>encrypted.Length==0 ? "" : Encoding.UTF8.GetString(Convert.FromBase64String(encrypted[5..]));
}
