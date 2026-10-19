using System.Net;
using System.Text;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class DropboxScopeTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var calls=new List<(string Route,string Body)>();string rootId="id:selected";
        using var client=new HttpClient(new Handler(async(request,ct)=>
        {
            var route=request.RequestUri!.AbsolutePath;string body=request.Content==null ? "" : await request.Content.ReadAsStringAsync(ct);
            if(request.Headers.TryGetValues("Dropbox-API-Arg",out var args))body=args.Single();
            calls.Add((route,body));
            if(route.EndsWith("get_current_account"))return Json(new{account_id="account"});
            if(route.EndsWith("get_metadata"))return Json(new Dictionary<string,object>{{".tag","folder"},{"id",rootId},{"name","Selected"}});
            if(route.EndsWith("list_folder"))return Json(new{entries=Array.Empty<object>(),has_more=false,cursor="c1"});
            if(route.EndsWith("get_latest_cursor"))return Json(new{cursor="c1"});
            if(route.EndsWith("/continue"))return Json(new{cursor="c2",has_more=false,entries=new[]{new{path_display="/Selected/child.txt"},new{path_display="/Selected-other/secret.txt"},new{path_display="/Outside/private.txt"}}});
            if(route.EndsWith("/download"))return new(HttpStatusCode.OK){Content=new ByteArrayContent([1,2,3])};
            if(route.EndsWith("delete_v2"))return Json(new{metadata=new{}});
            throw new InvalidOperationException("Unexpected test request "+route);
        }));
        var remote=new DropboxStore(new(client,(_,_)=>Task.FromResult("synthetic-token")),new Vault(),"/Selected","account",rootId);
        await remote.InitializeAsync(default);await remote.ListAsync("nested",default);await remote.CaptureCursorAsync(default);
        var changes=await remote.ChangesAsync("c1",new Dictionary<string,RemoteItem>(),default);
        check(changes.Paths.SequenceEqual(new[]{"child.txt"}),"Dropbox change feed escaped selected folder prefix");
        await remote.DownloadAsync("한글/file.txt",Path.Combine(root,"dropbox-scope-download"),default);
        await remote.DeleteAsync(".safesync-trash/batch/file.txt",default);
        foreach(var call in calls.Where(x=>x.Body.StartsWith('{')))
        {
            using var json=JsonDocument.Parse(call.Body);
            foreach(var property in json.RootElement.EnumerateObject().Where(x=>x.Name is "path" or "from_path" or "to_path"))
            {
                string path=property.Value.GetString()!;
                check(path.Equals("/selected",StringComparison.OrdinalIgnoreCase)||path.StartsWith("/selected/",StringComparison.OrdinalIgnoreCase),"Dropbox request left selected root");
            }
        }
        foreach(var path in new[]{"../Outside/file","/Outside/file","nested/../../Outside","C:\\escape","a//b","name:stream"})
        {
            int before=calls.Count;bool rejected=false;
            try{await remote.StatAsync(path,default);}catch(InvalidDataException){rejected=true;}
            check(rejected && calls.Count==before,"Dropbox traversal reached HTTP transport: "+path);
        }
        bool blocked=false;try{await remote.DeleteAsync("ordinary-file.txt",default);}catch(InvalidDataException){blocked=true;}
        check(blocked,"Dropbox direct active-file deletion was permitted");
        rootId="id:replacement";blocked=false;
        try{await remote.DeleteAsync(".safesync-trash/batch/file.txt",default);}catch(IOException){blocked=true;}
        check(blocked,"Dropbox root replacement did not block writes");
        blocked=false;try{await new DropboxStore(new(client,(_,_)=>Task.FromResult("synthetic-token")),new Vault(),"/Selected","account","id:selected").InitializeAsync(default);}catch(IOException){blocked=true;}
        check(blocked,"Dropbox persisted folder identity not checked on restart");
        var account=new CloudAccount {AppKey="public-app-key"};var pkce=CloudAuthentication.NewPkce();
        var uri=CloudAuthentication.AuthorizationUri("Dropbox",account,pkce.Challenge,pkce.State);
        var query=uri.Query.TrimStart('?').Split('&').Select(x=>x.Split('=',2)).ToDictionary(x=>Uri.UnescapeDataString(x[0]),x=>Uri.UnescapeDataString(x[1]));
        check(query["scope"].Split(' ').Order().SequenceEqual(CloudAuthentication.DropboxScopes.Split(' ').Order()),"Dropbox public OAuth did not request exact minimal file scopes");
        check(query["token_access_type"]=="offline" && query["response_type"]=="code" && query["code_challenge_method"]=="S256","Dropbox public desktop OAuth not offline PKCE");
        check(query["redirect_uri"]=="http://127.0.0.1:53682/" && !query.ContainsKey("client_secret"),"Dropbox desktop OAuth leaked secret or wrong callback");
    }
    private static HttpResponseMessage Json(object data)=>new(HttpStatusCode.OK){Content=new StringContent(JsonSerializer.Serialize(data),Encoding.UTF8,"application/json")};
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> send):HttpMessageHandler
    {protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)=>send(request,token);}
    private sealed class Vault:ISecretVault{public string Protect(string value)=>value;public string Unprotect(string value,byte[]? key=null)=>value;}
}
