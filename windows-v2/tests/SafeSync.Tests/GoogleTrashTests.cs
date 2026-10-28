using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using SafeSync.Core.Cloud;

internal static class GoogleTrashTests
{
    public static async Task RunAsync(Action<bool,string> check)
    {
        foreach(string outcome in new[]{"okay","forbidden","unconfirmed","wrong-id"})
        {
            using var handler=new Drive(outcome);using var client=new HttpClient(handler);
            var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"root","account");await remote.InitializeAsync(default);
            bool failed=false;try{await remote.DeleteAsync(".safesync-trash/batch",default);}catch(IOException){failed=true;}
            check(failed==(outcome!="okay"),"Archive disposal accepted a rejected/unconfirmed Google trash request: "+outcome);
            check(handler.TrashCalls==1 && handler.Deleted.Count==0,"Archive disposal bypassed Google trash or fell back to permanent deletion.");
            if(outcome=="okay")
            {
                check(handler.Nodes["batch"].Trashed && handler.Nodes.ContainsKey("retained") && !handler.Nodes["current"].Trashed,"Trashing an archive deleted content or affected the current backup.");
                await remote.DeleteAsync(".safesync-trash/batch",default);check(handler.TrashCalls==1,"Repeated disposal was not idempotent.");
            }
            await remote.DeleteAsync(".safesync-staging/temp.part",default);
            await remote.DeleteAsync("SafeSync-test-"+new string('a',32),default);
            check(handler.Deleted.SequenceEqual(new[]{"stage-file","test"}),"Staging/test cleanup no longer uses its explicit deletion route.");
            bool refused=false;try{await remote.DeleteAsync("current.txt",default);}catch(InvalidDataException){refused=true;}
            check(refused && !handler.Nodes["current"].Trashed && !handler.Deleted.Contains("current"),"Current backup bypassed archive path protection.");
        }
    }
    private sealed record Node(string Id,string Parent,string Name,bool Folder,bool Trashed=false);
    private sealed class Drive(string outcome):HttpMessageHandler
    {
        public Dictionary<string,Node> Nodes=new() {
            ["root-id"]=new("root-id","outside","Backup",true),["trash"]=new("trash","root-id",".safesync-trash",true),
            ["batch"]=new("batch","trash","batch",true),["retained"]=new("retained","batch","old.txt",false),
            ["current"]=new("current","root-id","current.txt",false),["staging"]=new("staging","root-id",".safesync-staging",true),
            ["stage-file"]=new("stage-file","staging","temp.part",false),["test"]=new("test","root-id","SafeSync-test-"+new string('a',32),true)
        };
        public List<string> Deleted=[];public int TrashCalls;
        private static object Metadata(Node n)=>new{id=n.Id,name=n.Name,parents=new[]{n.Parent},mimeType=n.Folder ? "application/vnd.google-apps.folder" : "application/octet-stream",size="10",modifiedTime="2026-01-01T00:00:00Z",createdTime="2026-01-01T00:00:00Z",md5Checksum="digest",version="1",trashed=n.Trashed};
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            var uri=request.RequestUri!;var path=uri.AbsolutePath;var id=path.Split('/').Last();if(id=="root")id="root-id";
            if(path.EndsWith("/about"))return CloudProtocolTests.Json(new{user=new{permissionId="account"}});
            if(request.Method==HttpMethod.Get && id=="files")
            {
                var match=Regex.Match(Uri.UnescapeDataString(uri.Query),"'([^']+)' in parents");
                return CloudProtocolTests.Json(new{files=Nodes.Values.Where(n=>n.Parent==match.Groups[1].Value && !n.Trashed).Select(Metadata).ToArray()});
            }
            if(request.Method==HttpMethod.Get)return CloudProtocolTests.Json(Metadata(Nodes[id]));
            if(request.Method==HttpMethod.Patch)
            {
                using var body=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));
                if(id!="batch" || !body.RootElement.True("trashed") || !uri.Query.Contains("supportsAllDrives=true"))throw new Exception("Unsafe archive trash request");
                TrashCalls++;if(outcome=="forbidden")return CloudProtocolTests.Json(new{},HttpStatusCode.Forbidden);
                if(outcome=="okay")Nodes[id]=Nodes[id] with{Trashed=true};
                return CloudProtocolTests.Json(new{id=outcome=="wrong-id" ? "different" : id,trashed=outcome!="unconfirmed"});
            }
            if(request.Method==HttpMethod.Delete){Deleted.Add(id);Nodes.Remove(id);return new(HttpStatusCode.NoContent);}
            throw new Exception("Unexpected Google disposal request");
        }
    }
}
