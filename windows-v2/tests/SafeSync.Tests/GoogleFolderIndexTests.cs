using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class GoogleFolderIndexTests
{
    public static async Task RunAsync(Action<bool,string> check)
    {
        using var handler=new Drive();using var client=new HttpClient(handler);
        var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"root","account");await remote.InitializeAsync(default);
        check((await remote.StatAsync("a/b/c/d/file.txt",default))?.Id=="file","Uncached deep path failed.");
        int before=handler.Requests;await remote.StatAsync("a/b/c/d/file.txt",default);int baseline=handler.Requests-before;
        void Seed()=>remote.SeedFolders(handler.Index(),[]);
        Seed();before=handler.Requests;
        check((await remote.StatAsync("a/b/c/d/file.txt",default))?.Id=="file","Cached path lost its file.");
        check(handler.Requests-before==2 && baseline>=6,"Four-level cached lookup did not use one ancestry batch plus one fresh leaf listing.");
        handler.Delay=true;before=handler.Requests;
        var concurrent=await Task.WhenAll(Enumerable.Range(0,8).Select(_=>remote.StatAsync("a/b/c/d/file.txt",default)));
        check(concurrent.All(i=>i?.Id=="file") && handler.Requests-before==2,"Concurrent folder/leaf reads were not coalesced.");handler.Delay=false;
        handler.Nodes["file"]=handler.Nodes["file"] with{Hash="changed"};
        check((await remote.StatAsync("a/b/c/d/file.txt",default))?.Hash=="changed","Leaf metadata was cached across operations.");
        handler.FailBatch=true;bool denied=false;
        try{await remote.StatAsync("a/b/c/d/file.txt",default);}catch(CloudApiException ex){denied=ex.Status==HttpStatusCode.Forbidden;}
        check(denied,"403 became a cached missing folder.");handler.FailBatch=false;
        check((await remote.StatAsync("a/b/c/d/file.txt",default))?.Id=="file","Failed batch poisoned a later read.");
        handler.OmitPart=true;bool incomplete=false;
        try{await remote.StatAsync("a/b/c/d/file.txt",default);}catch(IOException){incomplete=true;}
        check(incomplete,"Incomplete batch authorized a cached path.");handler.OmitPart=false;
        handler.Nodes["d"]=handler.Nodes["d"] with{Parent="outside"};handler.OutsideReads=0;
        check(await remote.StatAsync("a/b/c/d/file.txt",default)==null && handler.OutsideReads==0,"Moved cached folder was read outside the job root.");
        handler.Nodes["d"]=handler.Nodes["d"] with{Parent="c"};Seed();
        handler.Nodes["duplicate"]=new("duplicate","b","C",true);
        bool duplicate=false;try{await remote.EnsureFolderAsync("a/b/c/d",default);}catch(CloudDuplicateNameException){duplicate=true;}
        check(duplicate && handler.Creates==0,"A newly duplicated ancestor was trusted for mutation.");handler.Nodes.Remove("duplicate");Seed();
        handler.Paginate=true;handler.Nodes["late-duplicate"]=new("late-duplicate","b","C",true);
        duplicate=false;try{await remote.EnsureFolderAsync("a/b/c/d",default);}catch(CloudDuplicateNameException){duplicate=true;}
        check(duplicate && handler.SecondPageReads>0,"A duplicate on a later folder page escaped validation.");handler.Paginate=false;handler.Nodes.Remove("late-duplicate");Seed();
        handler.Nodes["d"]=handler.Nodes["d"] with{Name="renamed"};
        check(await remote.StatAsync("a/b/c/d/file.txt",default)==null,"Renamed cached folder retained its old path.");
        handler.Nodes["d"]=handler.Nodes["d"] with{Name="d"};Seed();
        handler.Delay=true;using(var cancellation=new CancellationTokenSource(5))
        {try{await remote.StatAsync("a/b/c/d/file.txt",cancellation.Token);}catch(OperationCanceledException){}}
        await Task.Delay(60);handler.Delay=false;
        check((await remote.StatAsync("a/b/c/d/file.txt",default))?.Id=="file","Canceled shared read poisoned a later lookup.");
        remote.SeedFolders(handler.Index(),["a/b"]);before=handler.Batches;
        check((await remote.StatAsync("a/b/c/d/file.txt",default))?.Id=="file" && handler.Batches==before,"An ambiguous catalog path seeded the fast folder route.");
        handler.Delay=true;await Task.WhenAll(remote.EnsureFolderAsync("new/x",default),remote.EnsureFolderAsync("new/y",default));handler.Delay=false;
        check(handler.Nodes.Values.Count(n=>n.Parent=="root-id" && n.Name=="new")==1 && handler.Creates==3,"Concurrent sibling paths created duplicate shared ancestors.");
    }
    private sealed record Node(string Id,string Parent,string Name,bool Folder,string Hash="hash");
    private sealed class Drive:HttpMessageHandler
    {
        public Dictionary<string,Node> Nodes {get;}=new();public int Requests,Batches,Creates,OutsideReads,SecondPageReads;
        public bool Delay,FailBatch,OmitPart,Paginate;
        public Drive()
        {
            Nodes["root-id"]=new("root-id","","Backup",true);
            string parent="root-id";foreach(var name in new[]{"a","b","c","d"}){Nodes[name]=new(name,parent,name,true);parent=name;}
            Nodes["file"]=new("file","d","file.txt",false);
        }
        public Dictionary<string,RemoteItem> Index()
        {
            var result=new Dictionary<string,RemoteItem>();string path="";
            foreach(var name in new[]{"a","b","c","d"}){path=path.Length==0 ? name : path+"/"+name;result[path]=new(name,name,true,0,DateTime.MinValue,DateTime.MinValue,"","");}return result;
        }
        private static object Metadata(Node n)=>new{id=n.Id,name=n.Name,mimeType=n.Folder ? "application/vnd.google-apps.folder" : "application/octet-stream",parents=n.Parent.Length==0 ? Array.Empty<string>() : new[]{n.Parent},trashed=false,size="4",md5Checksum=n.Hash};
        private (int Code,object Body) Read(Uri uri,bool batch)
        {
            lock(Nodes)return ReadCore(uri);
        }
        private (int Code,object Body) ReadCore(Uri uri)
        {
            var path=uri.AbsolutePath;
            if(path.EndsWith("/about"))return(200,new{user=new{permissionId="account"}});
            if(path.EndsWith("/files/root"))return(200,Metadata(Nodes["root-id"]));
            if(path.EndsWith("/files"))
            {
                var query=uri.Query.TrimStart('?').Split('&').Select(p=>p.Split('=',2)).ToDictionary(p=>p[0],p=>Uri.UnescapeDataString(p[1]));
                var parent=query["q"].Split('\'')[1];if(parent=="d" && Nodes["d"].Parent=="outside")OutsideReads++;
                var matches=Nodes.Values.Where(n=>n.Parent==parent).ToArray();
                if(Paginate && parent=="b")
                {
                    if(query.ContainsKey("pageToken")){SecondPageReads++;return(200,new{files=matches.Where(n=>n.Id=="late-duplicate").Select(Metadata).ToArray()});}
                    return(200,new{files=matches.Where(n=>n.Id!="late-duplicate").Select(Metadata).ToArray(),nextPageToken="second"});
                }
                return(200,new{files=matches.Select(Metadata).ToArray()});
            }
            var id=path.Split('/').Last();return Nodes.TryGetValue(id,out var node) ? (200,Metadata(node)) : (404,new{});
        }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            Interlocked.Increment(ref Requests);if(Delay)await Task.Delay(35,token);
            if(request.RequestUri!.AbsolutePath=="/batch/drive/v3")
            {
                Batches++;var body=await request.Content!.ReadAsStringAsync(token);var matches=Regex.Matches(body,@"GET ([^\r\n]+) HTTP/1.1");var output=new StringBuilder();
                for(int i=0;i<matches.Count;i++)
                {
                    if(OmitPart && i==matches.Count-1)continue;
                    var (code,json)=Read(new Uri("https://www.googleapis.com"+matches[i].Groups[1].Value),true);
                    if(FailBatch && i==1)code=403;
                    output.Append($"--reply\r\nContent-Type: application/http\r\nContent-ID: <response-{i}>\r\n\r\nHTTP/1.1 {code} response\r\nContent-Type: application/json\r\n\r\n{JsonSerializer.Serialize(json)}\r\n");
                }
                output.Append("--reply--\r\n");return new(HttpStatusCode.OK){Content=new StringContent(output.ToString(),Encoding.UTF8,"multipart/mixed"){Headers={ContentType=new("multipart/mixed"){Parameters={new("boundary","reply")}}}}};
            }
            if(request.Method==HttpMethod.Post)
            {
                using var json=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));var value=json.RootElement;Node node;
                lock(Nodes){Creates++;node=new("created-"+Creates,value.GetProperty("parents")[0].GetString()!,value.String("name"),true);Nodes[node.Id]=node;}
                return CloudProtocolTests.Json(Metadata(node));
            }
            var result=Read(request.RequestUri,false);return CloudProtocolTests.Json(result.Body,(HttpStatusCode)result.Code);
        }
    }
}
