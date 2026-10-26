using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class GoogleUploadPerformanceTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var file=Path.Combine(root,"small-drive-upload");await File.WriteAllTextAsync(file,"한글 small upload");
        var bytes=await File.ReadAllBytesAsync(file);var info=new FileInfo(file);
        var snapshot=new UploadSnapshot(file,bytes.Length,info.LastWriteTimeUtc,info.CreationTimeUtc,Convert.ToHexStringLower(MD5.HashData(bytes)),Convert.ToHexStringLower(SHA256.HashData(bytes)));
        using var handler=new Drive(snapshot,bytes);using var client=new HttpClient(handler);
        var remote=new GoogleDriveStore(new CloudHttp(client,(_,_)=>Task.FromResult("test")),new TestVault(),"root","account");await remote.InitializeAsync(default);
        for(int i=0;i<33;i++)
        {
            var session=new UploadSession();int saves=0;
            var uploaded=await remote.UploadAsync(snapshot,".safesync-staging/"+i+".part",session,()=>saves++,new(),default);
            check(RemotePath.Content(uploaded,snapshot) && session.FileId==uploaded.Id && session.Offset==snapshot.Length && saves>=2,"Small Drive upload lost checksum/ID/checkpoint.");
        }
        check(handler.Generations==2 && handler.Uploads==33 && handler.Resumable==0,"Small Drive files did not share ID batches or used resumable startup.");
        check(handler.PayloadsValid && handler.UniqueIDs.Count==33,"Multipart metadata/media mismatch or ID reused.");
        check(handler.FullAncestorLists==0 && handler.LightAncestorLists>0,"Folder traversal fetched full file metadata.");
        var lost=new UploadSession();handler.LoseResponse=true;
        bool interrupted=false;
        try{await remote.UploadAsync(snapshot,".safesync-staging/lost.part",lost,()=>{},new(),default);}catch(IOException){interrupted=true;}
        check(interrupted && lost.FileId.Length>0,"Lost small-upload response did not preserve file ID.");
        handler.HideChildren=true;int uploads=handler.Uploads;
        var recovered=await remote.UploadAsync(snapshot,".safesync-staging/lost.part",lost,()=>{},new(),default);
        check(recovered.Id==lost.FileId && RemotePath.Content(recovered,snapshot) && handler.Uploads==uploads,"Accepted multipart upload was sent again after lost response/list lag.");
        handler.WrongParent=true;bool rejected=false;
        try{await remote.UploadAsync(snapshot,".safesync-staging/lost.part",lost,()=>{},new(),default);}catch(IOException){rejected=true;}
        check(rejected && handler.Uploads==uploads,"Recovery accepted an upload ID moved outside staging.");
        var source=Path.Combine(root,"lazy-cloud-source");Directory.CreateDirectory(source);
        foreach(var name in new[]{"a.txt","b.txt","c.txt"})await File.WriteAllTextAsync(Path.Combine(source,name),"source");
        var batch=new BatchRemote();var store=new ConfigStore(Path.Combine(root,"lazy-cloud-data"));
        var job=new BackupJob{Source=source,Destination="test",DestinationType="GoogleDrive",CloudFolderId=batch.Root,CloudAccountId=batch.AccountId};
        var result=await new BackupEngine(store){CloudFactory=_=>batch}.RunAsync(job,true,null,new(),null,default);
        check(batch.UnknownBatched==0 && result.Copied==2 && result.Conflicts.Count==1,"New backup eagerly queried missing paths or missed a late destination conflict.");
        check(Encoding.UTF8.GetString(batch.Inner.Bytes("a.txt"))=="external edit","Lazy metadata check overwrote a newly appeared file.");
        check(batch.PriorLookups==0,"New-file publishing queried nonexistent old-copy paths.");
    }
    private sealed class BatchRemote:IRemoteStore,IRemoteBatch
    {
        public MemoryRemote Inner {get;}=new("GoogleDrive");public int UnknownBatched,PriorLookups;
        public string Provider=>Inner.Provider;public string Root=>Inner.Root;public string AccountId=>Inner.AccountId;
        public Task InitializeAsync(CancellationToken ct)=>Inner.InitializeAsync(ct);
        public Task<RemoteItem?> StatAsync(string path,CancellationToken ct){if(path.StartsWith(".safesync-trash/"))PriorLookups++;return Inner.StatAsync(path,ct);}
        public Task<IReadOnlyList<RemoteItem>> ListAsync(string path,CancellationToken ct)=>Inner.ListAsync(path,ct);
        public Task EnsureFolderAsync(string path,CancellationToken ct)=>Inner.EnsureFolderAsync(path,ct);
        public Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string path,UploadSession session,Action save,PauseGate pause,CancellationToken ct)=>Inner.UploadAsync(snapshot,path,session,save,pause,ct);
        public Task<RemoteItem> MoveAsync(string from,string to,CancellationToken ct)=>Inner.MoveAsync(from,to,ct);
        public Task DeleteAsync(string path,CancellationToken ct)=>Inner.DeleteAsync(path,ct);
        public Task DownloadAsync(string path,string local,CancellationToken ct)=>Inner.DownloadAsync(path,local,ct);
        public async Task<IReadOnlyDictionary<string,RemoteItem?>> StatManyAsync(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> paths,CancellationToken ct)
        {
            var list=paths.ToArray();UnknownBatched+=list.Count(p=>!known.ContainsKey(p));
            // Appears after inventory and before file processing: must not be
            // mistaken for absence just because it has no batch result.
            await Inner.SeedAsync("a.txt","external edit",DateTime.UtcNow.AddMinutes(5));
            var result=new Dictionary<string,RemoteItem?>();foreach(var p in list)result[p]=await StatAsync(p,ct);return result;
        }
    }
    private sealed class Drive(UploadSnapshot snapshot,byte[] expected):HttpMessageHandler
    {
        public int Generations,Uploads,Resumable,LightAncestorLists,FullAncestorLists;
        public bool PayloadsValid=true,LoseResponse,HideChildren,WrongParent;
        public HashSet<string> UniqueIDs {get;}=[];
        private readonly Dictionary<string,(string Name,string Parent)> files=new();
        private object Folder(string id,string name)=>new{id,name,mimeType="application/vnd.google-apps.folder",parents=new[]{"root-id"},trashed=false};
        private object Metadata(string id,(string Name,string Parent) item)=>new{id,name=item.Name,mimeType="application/octet-stream",size=snapshot.Length.ToString(),modifiedTime=snapshot.ModifiedUtc.ToString("O"),createdTime=snapshot.CreatedUtc.ToString("O"),md5Checksum=snapshot.Hash,sha256Checksum=snapshot.Sha256,parents=new[]{WrongParent ? "outside" : item.Parent},trashed=false};
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            var uri=request.RequestUri!;var path=uri.AbsolutePath;
            HttpResponseMessage Json(object value)=>CloudProtocolTests.Json(value);
            if(path.EndsWith("/about"))return Json(new{user=new{permissionId="account"}});
            if(path.EndsWith("/files/root") || path.EndsWith("/files/root-id"))return Json(Folder("root-id","Drive"));
            if(path.EndsWith("/files/generateIds"))
            {
                Generations++;return Json(new{ids=Enumerable.Range(0,32).Select(i=>"id-"+Generations+"-"+i).ToArray()});
            }
            if(request.Method==HttpMethod.Get && path.EndsWith("/files"))
            {
                var q=Uri.UnescapeDataString(uri.Query);
                if(q.Contains("'root-id'"))
                {
                    if(q.Contains("files(id,name,mimeType)"))LightAncestorLists++;else FullAncestorLists++;
                    return Json(new{files=new[]{Folder("stage",".safesync-staging")}});
                }
                return Json(new{files=HideChildren ? Array.Empty<object>() : files.Select(f=>Metadata(f.Key,f.Value)).ToArray()});
            }
            if(request.Method==HttpMethod.Get)
            {
                var id=path.Split('/').Last();return files.TryGetValue(id,out var existing) ? Json(Metadata(id,existing)) : new(HttpStatusCode.NotFound);
            }
            if(path.Contains("/upload/"))
            {
                if(!uri.Query.Contains("uploadType=multipart")){Resumable++;throw new Exception("Unexpected resumable request for small file.");}
                var parts=((MultipartContent)request.Content!).ToArray();
                using var metadata=JsonDocument.Parse(await parts[0].ReadAsStringAsync(token));var body=metadata.RootElement;
                string id=body.String("id"),name=body.String("name"),parent=body.GetProperty("parents")[0].GetString()!;
                PayloadsValid &= (await parts[1].ReadAsByteArrayAsync(token)).SequenceEqual(expected) && parent=="stage" && body.String("createdTime")==snapshot.CreatedUtc.ToString("O");
                if(files.ContainsKey(id))return new(HttpStatusCode.Conflict);
                Uploads++;UniqueIDs.Add(id);files[id]=(name,parent);
                if(LoseResponse){LoseResponse=false;throw new IOException("Accepted upload, response lost.");}
                return Json(Metadata(id,files[id]));
            }
            throw new Exception("Unexpected small-upload request: "+request.Method+" "+path);
        }
    }
}
