using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class GoogleInventoryTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        using var drive=new Drive();using var client=new HttpClient(drive);
        var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("test")),new TestVault(),"managed","account");await remote.InitializeAsync(default);
        var store=new ConfigStore(Path.Combine(root,"id-inventory-data"));var catalog=new RemoteCatalog(store,remote);
        int before=drive.Requests;
        await catalog.RefreshAsync(false,new(),default);
        check(catalog.State.Items.Count==1200,"Initial ID inventory lost files/folders.");
        check(drive.Requests-before==5,"Initial ID inventory still walks every ancestor by HTTP.");
        check(catalog.State.Nodes?.Count==1201,"Physical graph not persisted.");catalog.Acknowledge();
        var id="file-1-0";var node=drive.Nodes[id];drive.Nodes[id]=node with{Size=99,Version="2"};drive.Changes=[id];before=drive.Requests;
        await catalog.RefreshAsync(false,new(),default);
        check(drive.Requests-before==2 && catalog.State.Items["folder-1/item-0.txt"].Length==99,"Single change was re-looked-up by path.");
        check(catalog.State.Pending.SequenceEqual(new[]{"folder-1/item-0.txt"}),"Single change queued unchanged files.");catalog.Acknowledge();
        drive.Nodes["folder-1"]=drive.Nodes["folder-1"] with{Name="renamed"};drive.Changes=["folder-1"];before=drive.Requests;
        await catalog.RefreshAsync(false,new(),default);
        check(drive.Requests-before==2 && catalog.State.Items.ContainsKey("renamed/item-0.txt") && !catalog.State.Items.ContainsKey("folder-1/item-0.txt"),"Moved folder ancestry or children not updated from IDs.");catalog.Acknowledge();
        drive.Nodes["incoming"]=new("incoming","managed","incoming",true);drive.Nodes["incoming-file"]=new("incoming-file","incoming","not-in-feed.txt",false);
        drive.Changes=["incoming"];await catalog.RefreshAsync(false,new(),default);
        check(catalog.State.Items.ContainsKey("incoming/not-in-feed.txt"),"Moved-in subtree skipped children absent from change feed.");catalog.Acknowledge();
        drive.Nodes["duplicate"]=new("duplicate","folder-2","item-0.txt",false);drive.Changes=["duplicate"];await catalog.RefreshAsync(false,new(),default);
        check(catalog.IsAmbiguous("folder-2/item-0.txt") && !catalog.State.Items.ContainsKey("folder-2/item-0.txt"),"Duplicate name silently selected a file.");
        var preserved=catalog.State;drive.Forbidden=true;bool rejected=false;
        try{await catalog.RefreshAsync(true,new(),default);}catch(CloudApiException){rejected=true;}
        check(rejected && ReferenceEquals(catalog.State,preserved),"403 committed a partial/empty inventory.");drive.Forbidden=false;
        drive.OmitPart=true;rejected=false;
        try{await catalog.RefreshAsync(true,new(),default);}catch(IOException){rejected=true;}
        check(rejected && ReferenceEquals(catalog.State,preserved),"Incomplete batch committed an inventory.");drive.OmitPart=false;
        drive.Expire=true;await catalog.RefreshAsync(false,new(),default);
        check(catalog.State.Items.ContainsKey("incoming/not-in-feed.txt"),"Expired cursor failed safe rebuild.");
        using var canceled=new CancellationTokenSource();canceled.Cancel();rejected=false;
        try{await catalog.RefreshAsync(false,new(),canceled.Token);}catch(OperationCanceledException){rejected=true;}
        check(rejected,"Inventory ignored cancellation.");
        var reloaded=new RemoteCatalog(store,remote);drive.Changes=[];before=drive.Requests;
        await reloaded.RefreshAsync(false,new(),default);
        check(drive.Requests-before==2 && reloaded.State.Nodes?.Count>0,"Restart discarded the persisted ID graph.");
        drive.Nodes["folder-3"]=drive.Nodes["folder-3"] with{Parent="external"};drive.Changes=["folder-3"];
        await reloaded.RefreshAsync(false,new(),default);
        check(!reloaded.State.Items.Keys.Any(p=>p.StartsWith("folder-3/")),"Moved-out descendants remained in the selected root.");
        drive.Nodes["folder-3"]=drive.Nodes["folder-3"] with{Parent="managed"};drive.Changes=["folder-3"];
        await reloaded.RefreshAsync(false,new(),default);
        check(reloaded.State.Items.ContainsKey("folder-3/item-4.txt"),"Moved-back subtree was not rediscovered.");
        drive.Nodes.Remove("folder-4");drive.Changes=["folder-4"];await reloaded.RefreshAsync(false,new(),default);
        check(!reloaded.State.Items.Keys.Any(p=>p.StartsWith("folder-4/")),"Removed folder retained stale descendants.");
        drive.Pagination=true;await reloaded.RefreshAsync(true,new(),default);
        check(drive.SecondPages>0 && reloaded.State.Items.ContainsKey("folder-199/item-4.txt"),"Later list pages were skipped.");
        var safe=reloaded.State;drive.Nodes["cycle"]=new("cycle","cycle","cycle",true);drive.Changes=["cycle"];rejected=false;
        try{await reloaded.RefreshAsync(false,new(),default);}catch(IOException){rejected=true;}
        check(rejected && ReferenceEquals(reloaded.State,safe),"A cyclic ancestry committed partial state.");
    }
    private sealed record Node(string Id,string Parent,string Name,bool Folder,long Size=10,string Version="1");
    private sealed class Drive:HttpMessageHandler
    {
        public Dictionary<string,Node> Nodes=new(StringComparer.Ordinal){{"managed",new("managed","outside-authorized-scope","backup",true)}};
        public string[] Changes=[];public int Requests,SecondPages;public bool Forbidden,OmitPart,Expire,Pagination;
        public Drive(){for(int i=0;i<200;i++){Nodes[$"folder-{i}"]=new($"folder-{i}","managed",$"folder-{i}",true);for(int j=0;j<5;j++)Nodes[$"file-{i}-{j}"]=new($"file-{i}-{j}",$"folder-{i}",$"item-{j}.txt",false);}}
        private static object Metadata(Node n)=>new{id=n.Id,name=n.Name,parents=n.Parent.Length==0 ? Array.Empty<string>() : new[]{n.Parent},mimeType=n.Folder ? "application/vnd.google-apps.folder" : "application/octet-stream",size=n.Size.ToString(),version=n.Version,modifiedTime="2026-01-01T00:00:00Z",createdTime="2026-01-01T00:00:00Z",md5Checksum=n.Folder ? "" : n.Size.ToString(),trashed=false};
        private (int,object) Read(Uri uri)
        {
            if(uri.AbsolutePath=="/drive/v3/about")return(200,new{user=new{permissionId="account"}});
            if(uri.AbsolutePath=="/drive/v3/changes/startPageToken")return(200,new{startPageToken="cursor"});
            if(uri.AbsolutePath=="/drive/v3/changes")
            {if(Expire){Expire=false;return(410,new{});}return(200,new{newStartPageToken="next",changes=Changes.Select(id=>Nodes.TryGetValue(id,out var n) ? new{fileId=id,removed=false,file=Metadata(n)} : new{fileId=id,removed=true,file=(object)new{}}).ToArray()});}
            if(uri.AbsolutePath=="/drive/v3/files")
            {
                if(Forbidden)return(403,new{});
                var query=uri.Query.TrimStart('?').Split('&').Select(p=>p.Split('=',2)).ToDictionary(p=>Uri.UnescapeDataString(p[0]),p=>p.Length>1 ? Uri.UnescapeDataString(p[1]) : "");
                var parent=Regex.Match(query["q"],"'([^']+)' in parents").Groups[1].Value;
                var files=Nodes.Values.Where(n=>n.Parent==parent).Select(Metadata).ToArray();
                bool paged=Pagination && parent=="managed",second=query.GetValueOrDefault("pageToken")=="page2";
                if(second)SecondPages++;
                return(200,new{nextPageToken=paged && !second ? "page2" : "",files=paged ? (second ? files.Skip(100) : files.Take(100)).ToArray() : files});
            }
            return Nodes.TryGetValue(uri.AbsolutePath.Split('/').Last(),out var node) ? (200,Metadata(node)) : (404,new{});
        }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            token.ThrowIfCancellationRequested();Requests++;
            if(request.RequestUri!.AbsolutePath=="/batch/drive/v3")
            {
                var body=await request.Content!.ReadAsStringAsync(token);var matches=Regex.Matches(body,@"GET ([^\r\n]+) HTTP/1.1");var output=new StringBuilder();
                for(int i=0;i<matches.Count;i++)
                {
                    if(OmitPart && i==matches.Count-1)continue;
                    var (status,json)=Read(new Uri("https://www.googleapis.com"+matches[i].Groups[1].Value));
                    output.Append($"--reply\r\nContent-Type: application/http\r\nContent-ID: <response-{i}>\r\n\r\nHTTP/1.1 {status} response\r\nContent-Type: application/json\r\n\r\n{JsonSerializer.Serialize(json)}\r\n");
                }
                output.Append("--reply--\r\n");return new(HttpStatusCode.OK){Content=new StringContent(output.ToString(),Encoding.UTF8,"multipart/mixed"){Headers={ContentType=new("multipart/mixed"){Parameters={new("boundary","reply")}}}}};
            }
            var reply=Read(request.RequestUri);return CloudProtocolTests.Json(reply.Item2,(HttpStatusCode)reply.Item1);
        }
    }
}
