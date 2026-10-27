using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class GoogleDuplicateProtocolTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        using var server=new DriveHandler();using var client=new HttpClient(server);
        var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"root","account");
        await remote.InitializeAsync(default);
        var candidates=await remote.CandidatesAsync("Project/song.wav",default);
        check(candidates.Count==2 && candidates.Select(c=>c.Id).Order().SequenceEqual(new[]{"song-a","song-b"}),"Drive duplicate folders were not traversed by physical ID.");
        var children=await remote.ListAsync("Project",default);
        check(children.Count==2,"Drive merged duplicate folder listing lost a child.");
        var file=Path.Combine(root,"duplicate-protocol-source");await File.WriteAllTextAsync(file,"same bytes");
        check(await RemoteDuplicates.IdenticalAsync(remote,file,"Project/song.wav",default)!=null,"Drive matching content in duplicate folders did not skip.");
        server.Nodes["song-b"]=server.Nodes["song-b"] with{Hash="different"};
        check(await RemoteDuplicates.IdenticalAsync(remote,file,"Project/song.wav",default)==null,"Drive ignored a different duplicate checksum.");
        var plan=await remote.InspectDuplicatesAsync("Project/song.wav",default);
        check(plan.Selected?.Id=="song-a" && plan.Groups.Single().Relative=="Project","Drive canonical comparison did not expose duplicate parent.");
        server.Add("unique-b","folder-b","unique.txt",false,"first");
        var catalogStore=new ConfigStore(Path.Combine(root,"duplicate-catalog-cache"));var catalog=new RemoteCatalog(catalogStore,remote);
        await catalog.RefreshAsync(true,new(),default);catalog.Acknowledge();
        check(catalog.State.Items.ContainsKey("Project/unique.txt") && catalog.IsAmbiguous("Project/unique.txt"),"Merged duplicate subtree lost unique files or ambiguity guard.");
        int childRequests=server.ChildrenRequests.Count(p=>p=="folder-a" || p=="folder-b");
        catalog=new RemoteCatalog(catalogStore,remote);await catalog.RefreshAsync(false,new(),default);
        check(server.ChildrenRequests.Count(p=>p=="folder-a" || p=="folder-b")==childRequests && catalog.State.Items.ContainsKey("Project/unique.txt"),"Unchanged duplicate folder rescanned its subtree on restart.");
        server.Add("stable-a","root","stable.txt",false,"same bytes");server.Add("stable-b","root","STABLE.TXT",false,"same bytes");
        await catalog.RefreshAsync(true,new(),default);
        var stableCandidates=await remote.CandidatesAsync("stable.txt",default);catalog.TrustAmbiguous("stable.txt",stableCandidates);catalog.Acknowledge();
        catalog=new RemoteCatalog(catalogStore,remote);await catalog.RefreshAsync(false,new(),default);
        check(catalog.IsStableAmbiguous("stable.txt") && !catalog.State.Pending.Contains("stable.txt",StringComparer.OrdinalIgnoreCase),"Verified unchanged duplicate files were queued again after restart.");
        server.Nodes["stable-b"]=server.Nodes["stable-b"] with{Hash="changed",Version="2"};server.ChangedIds.Add("stable-b");
        await catalog.RefreshAsync(false,new(),default);
        check(!catalog.IsStableAmbiguous("stable.txt") && catalog.State.Pending.Contains("stable.txt",StringComparer.OrdinalIgnoreCase),"A changed duplicate file reused stale verification.");
        var beforeChangedChild=server.ChildrenRequests.Count(p=>p=="folder-a" || p=="folder-b");
        server.Nodes["unique-b"]=server.Nodes["unique-b"] with{Hash="changed",Version="2"};server.ChangedIds.Add("unique-b");
        await catalog.RefreshAsync(false,new(),default);
        check(catalog.State.Items["Project/unique.txt"].Hash=="changed" && server.ChildrenRequests.Count(p=>p=="folder-a" || p=="folder-b")==beforeChangedChild,"Change feed did not update the duplicate subtree directly by ID.");
        var forged=plan with{Groups=[plan.Groups[0] with{ParentId="outside"}]};
        bool rejected=false;try{await remote.PreserveDuplicatesAsync(forged,default);}catch(CloudConflictException){rejected=true;}
        check(rejected && server.Renamed.Count==0,"Forged duplicate parent escaped the job root.");
        server.Nodes["folder-b"]=server.Nodes["folder-b"] with{Version="2"};
        rejected=false;try{await remote.PreserveDuplicatesAsync(plan,default);}catch(CloudConflictException){rejected=true;}
        check(rejected && server.Renamed.Count==0,"Changed Drive duplicate folder was renamed without new confirmation.");
        plan=await remote.InspectDuplicatesAsync("Project/song.wav",default);await remote.PreserveDuplicatesAsync(plan,default);
        check(server.Renamed.SequenceEqual(new[]{"folder-b"}) && server.Nodes["folder-b"].Name.StartsWith("Project.SafeSync-conflict-"),"Drive preservation did not rename only the additional folder ID.");
        check(server.Nodes["song-b"].Parent=="folder-b" && server.Nodes["song-b"].Hash=="different" && (await remote.StatAsync("Project/song.wav",default))?.Id=="song-a","Drive duplicate folder preservation moved or lost its contents.");
        check(server.Nodes["secret"].Name=="secret.txt" && server.DeleteCalls==0,"Duplicate resolution deleted files or touched unrelated roots.");
        server.Add("file-a","root","duplicate.txt",false,"first");server.Add("file-b","root","DUPLICATE.txt",false,"second");
        var filePlan=await remote.InspectDuplicatesAsync("duplicate.txt",default);
        check(filePlan.Groups.Single().Items.Length==2 && filePlan.Selected?.Id=="file-a","Drive case-insensitive file collision was hidden.");
        server.LoseRenameResponse=true;
        try{await remote.PreserveDuplicatesAsync(filePlan,default);}catch(IOException){}
        check(server.Nodes["file-b"].Name.StartsWith("DUPLICATE.txt.SafeSync-conflict-") && server.Nodes["file-a"].Name=="duplicate.txt","Lost rename response lost a copy.");
        check((await remote.InspectDuplicatesAsync("duplicate.txt",default)).Groups.Length==0,"A preserved rename cannot be reconciled after restart.");
        server.Add("mixed-a","root","mixed",true,"");server.Add("mixed-b","root","mixed",false,"data");
        rejected=false;try{await remote.InspectDuplicatesAsync("mixed",default);}catch(CloudConflictException){rejected=true;}
        check(rejected,"Mixed file/folder collision received overwrite authority.");
    }
    private sealed record Node(string Id,string Parent,string Name,bool Folder,string Hash,long Length,string Version="1");
    private sealed class DriveHandler:HttpMessageHandler
    {
        public Dictionary<string,Node> Nodes {get;}=new();public List<string> Renamed {get;}=[];public List<string> ChildrenRequests {get;}=[];public List<string> ChangedIds {get;}=[];public int DeleteCalls;public bool LoseRenameResponse;
        public DriveHandler()
        {
            Add("root","","Root",true,"");Add("folder-a","root","Project",true,"");Add("folder-b","root","Project",true,"");
            Add("song-a","folder-a","song.wav",false,"same bytes");Add("song-b","folder-b","song.wav",false,"same bytes");
            Add("outside","","Unrelated",true,"");Add("secret","outside","secret.txt",false,"private");
        }
        public void Add(string id,string parent,string name,bool folder,string content){var bytes=Encoding.UTF8.GetBytes(content);Nodes[id]=new(id,parent,name,folder,folder ? "" : Convert.ToHexStringLower(MD5.HashData(bytes)),bytes.Length);}
        private static object Metadata(Node node)=>new{id=node.Id,name=node.Name,mimeType=node.Folder ? "application/vnd.google-apps.folder" : "application/octet-stream",size=node.Length.ToString(),md5Checksum=node.Hash,version=node.Version,createdTime="2026-10-01T00:00:00Z",modifiedTime="2026-10-02T00:00:00Z",parents=node.Parent.Length==0 ? Array.Empty<string>() : new[]{node.Parent},trashed=false};
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            var uri=request.RequestUri!;var path=uri.AbsolutePath;
            HttpResponseMessage Json(object data)=>new(HttpStatusCode.OK){Content=CloudJson.Body(data)};
            if(path=="/batch/drive/v3")
            {
                var body=await request.Content!.ReadAsStringAsync(token);var matches=Regex.Matches(body,@"GET ([^\r\n]+) HTTP/1.1");var output=new StringBuilder();
                for(int i=0;i<matches.Count;i++)
                {
                    using var part=new HttpRequestMessage(HttpMethod.Get,"https://www.googleapis.com"+matches[i].Groups[1].Value);
                    using var response=await SendAsync(part,token);
                    output.Append($"--reply\r\nContent-Type: application/http\r\nContent-ID: <response-{i}>\r\n\r\nHTTP/1.1 {(int)response.StatusCode} response\r\nContent-Type: application/json\r\n\r\n{await response.Content.ReadAsStringAsync(token)}\r\n");
                }
                output.Append("--reply--\r\n");return new(HttpStatusCode.OK){Content=new StringContent(output.ToString(),Encoding.UTF8,"multipart/mixed"){Headers={ContentType=new("multipart/mixed"){Parameters={new("boundary","reply")}}}}};
            }
            if(path.EndsWith("/about"))return Json(new{user=new{permissionId="account"}});
            if(path.EndsWith("/changes/startPageToken"))return Json(new{startPageToken="cursor"});
            if(path.EndsWith("/changes")){var changes=ChangedIds.Select(id=>new{fileId=id,removed=false,file=Metadata(Nodes[id])}).ToArray();ChangedIds.Clear();return Json(new{newStartPageToken="cursor",changes});}
            if(path.EndsWith("/files"))
            {
                var query=uri.Query.TrimStart('?').Split('&').Select(p=>p.Split('=',2)).ToDictionary(p=>p[0],p=>Uri.UnescapeDataString(p[1]));var q=query["q"];var parent=q.Split('\'')[1];
                ChildrenRequests.Add(parent);return Json(new{files=Nodes.Values.Where(n=>n.Parent==parent).Select(Metadata).ToArray()});
            }
            string id=path.Split('/').Last();if(!Nodes.TryGetValue(id,out var item))return new(HttpStatusCode.NotFound);
            if(request.Method==HttpMethod.Patch)
            {
                using var document=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));
                item=item with{Name=document.RootElement.GetProperty("name").GetString()!,Version=(int.Parse(item.Version)+1).ToString()};Nodes[id]=item;Renamed.Add(id);
                if(LoseRenameResponse){LoseRenameResponse=false;throw new IOException("Simulated lost response after rename");}
            }
            if(request.Method==HttpMethod.Delete)DeleteCalls++;
            return Json(Metadata(item));
        }
    }
}
