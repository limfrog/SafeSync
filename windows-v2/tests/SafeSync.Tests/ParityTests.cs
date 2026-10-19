using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class ParityTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var home=Path.Combine(root,"parity");Directory.CreateDirectory(home);
        var atomic=Path.Combine(home,"atomic.json");JsonFile.Save(atomic,new{Value=1});
        var held=new FileStream(atomic,FileMode.Open,FileAccess.Read,FileShare.Read);
        var writing=Task.Run(()=>JsonFile.Save(atomic,new{Value=2}));await Task.Delay(80);held.Dispose();await writing;
        check(JsonFile.Read<Dictionary<string,int>>(atomic)["Value"]==2,"Transient lock defeated safe atomic metadata replacement");
        foreach(var name in new[]{"20261019-123456-deleted","20261019-123456789-replaced-id"})check(TrashDates.TryParse(name,out var date) && date.Year==2026,"Legacy trash date rejected");
        foreach(var name in new[]{"20261399-123456-deleted","20261019-1234567890-id","not-trash"})check(!TrashDates.TryParse(name,out _),"Invalid trash timestamp accepted");
        var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
        var job=new BackupJob {Source=source,Destination=backup};var store=new ConfigStore(Path.Combine(home,"data"));var engine=new BackupEngine(store);
        File.WriteAllText(Path.Combine(source,"old.txt"),"old");await engine.RunAsync(job,true,null,new(),null,default);
        var state=store.LoadState(job);state.LastFullScanUtc=DateTime.UtcNow.AddYears(-1).ToString("O");store.SaveState(state);
        File.WriteAllText(Path.Combine(source,"new.txt"),"new");var stages=new List<string>();
        var incremental=await engine.RunAsync(job,false,new[]{"new.txt"},new(),new Reporter(p=>stages.Add(p.Stage)),default);
        check(incremental.Copied==1 && !stages.Contains("원본 폴더 비교"),"Age triggered a full local scan");
        var manual=await engine.RunAsync(job,true,null,new(),new Reporter(p=>stages.Add(p.Stage)),default);check(stages.Contains("원본 폴더 비교") && manual.Errors.Count==0,"Manual full comparison lost");
        state=store.LoadState(job);state.PendingPaths=["old.txt","new.txt"];store.SaveState(state);
        var entries=state.Files.ToDictionary(e=>e.RelativePath,StringComparer.OrdinalIgnoreCase);entries["old.txt"].Status="BackedUp";entries["new.txt"].Status="Locked";
        store.SaveCheckpoint(state,entries,new HashSet<string>{"new.txt"},new[]{"old.txt","new.txt"});
        var resumed=new ConfigStore(store.Root).LoadState(job);check(resumed.PendingPaths.SequenceEqual(new[]{"new.txt"}) && resumed.Files.Single(e=>e.RelativePath=="new.txt").Status=="Locked","Delta replay lost pending/locked state");
        var obsolete=new StateDeltas.Delta {Generation="obsolete",Entries=[new(){RelativePath="wrong.txt"}]};JsonFile.Save(Path.Combine(store.StatePath(job.Id)+".native-deltas","obsolete.json"),obsolete);
        check(!store.LoadState(job).Files.Any(e=>e.RelativePath=="wrong.txt"),"Obsolete state generation replayed");
        var large=ConfigStore.NewState(new BackupJob {Source=source,Destination=backup});large.Files=Enumerable.Range(0,2000).Select(i=>new FileEntry {RelativePath="track-"+i+".wav"}).ToList();large.PendingPaths=large.Files.Select(e=>e.RelativePath).ToList();store.SaveState(large);
        var map=large.Files.ToDictionary(e=>e.RelativePath);store.SaveCheckpoint(large,map,large.PendingPaths.ToHashSet(),new[]{"track-1.wav"});
        long baseline=new FileInfo(store.StatePath(large.JobId)).Length,deltaBytes=new FileInfo(Directory.GetFiles(store.StatePath(large.JobId)+".native-deltas").Single()).Length;
        check(deltaBytes*50<baseline,"Single-file checkpoint still writes the full snapshot");
        var ledger=new NoticeLedger(store.Root);var error=new BackupResult();error.Errors.Add(new(job.Id,job.Name,"old.txt","first error",0,0,"",""));
        check(ledger.Apply(job.Id,error)==1,"First notice missing");check(new NoticeLedger(store.Root).Apply(job.Id,error)==0,"Notice dedup lost after restart");
        var changedError=new BackupResult();changedError.Errors.Add(error.Errors[0] with{Reason="another text"});check(ledger.Apply(job.Id,changedError)==0,"Same unresolved file alerted twice");
        var success=new BackupResult();success.ResolvedPaths.Add("old.txt");ledger.Apply(job.Id,success);check(ledger.Entries.Count==0,"Resolved notice remains");
        check(ledger.Apply(job.Id,error)==1,"New recurrence after success was suppressed");var canceled=new BackupResult {Canceled=true};ledger.Apply(job.Id,canceled);check(ledger.Entries.Count==1,"Cancellation discarded unresolved notice");
        var lockedEntry=new FileEntry {RelativePath="old.txt",Status="Locked",LastAttemptUtc=DateTime.UtcNow.ToString("O")};
        var lockedIssue=LockTracking.Update(lockedEntry,null,error.Errors[0]);var second=new FileEntry {RelativePath="old.txt",Status="Locked",LastAttemptUtc=DateTime.UtcNow.ToString("O")};var again=LockTracking.Update(second,lockedEntry,lockedIssue);
        check(again.RetryCount==2 && again.WaitingSinceUtc==lockedIssue.WaitingSinceUtc,"Lock retry history lost");
        var log=new ActivityLog(store.Root);log.Append("synthetic-only-log");check(File.ReadAllText(Directory.GetFiles(Path.Combine(store.Root,"logs")).Single()).Contains("synthetic-only-log"),"Persistent log missing");
        var cache=new TrashListCache<TrashItem>(store,job);cache.Save(new[]{new TrashItem("fake","file",DateTime.Now,"fake","file",4)});check(cache.Read().Single().Length==4,"Trash cache roundtrip failed");
        var cursor=new UsnCheckpoint(source,12,34,56);check(OfflineJournal.Valid(cursor,source,12,34,1,100),"Valid USN cursor rejected");check(!OfflineJournal.Valid(cursor,source,13,34,1,100),"Replaced root trusted");check(!OfflineJournal.Valid(cursor,source,12,35,1,100),"Reset journal trusted");check(!OfflineJournal.Valid(cursor,source,12,34,57,100),"Journal gap trusted");
        var unsupported=OfflineJournal.Read(@"\\synthetic.invalid\share",null);check(unsupported.RequiresScan && unsupported.Checkpoint==null,"Unsupported volume silently skipped offline reconciliation");
        var aliasRows=new[]{new FileEntry {RelativePath="one.txt",SourceFileId=42,BackupFileId=7},new FileEntry {RelativePath="two.txt",SourceFileId=42,BackupFileId=7}};
        var aliases=OfflineJournal.TrackedIds(aliasRows);check(aliases[42].Length==2 && OfflineJournal.TrackedIds(aliasRows,true)[7].Length==2,"USN source/backup hard-link aliases collapsed to a single path");
        var payload=Path.Combine(home,"hash.txt");await File.WriteAllTextAsync(payload,"content");var pair=await RemotePath.GoogleHashesAsync(payload,default);check(pair.Md5==Convert.ToHexStringLower(MD5.HashData(File.ReadAllBytes(payload))) && pair.Sha256==Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(payload))),"Combined hashes differ");
        var snap=new UploadSnapshot(payload,7,DateTime.UtcNow,DateTime.UtcNow,pair.Md5,pair.Sha256);var remoteItem=new RemoteItem("id","file",false,7,DateTime.UtcNow,DateTime.UtcNow,pair.Md5,"1",true,pair.Sha256);
        check(RemotePath.Content(remoteItem,snap) && !RemotePath.Content(remoteItem with{Sha256="bad"},snap),"SHA256 verification was ignored");check(RemotePath.Content(remoteItem with{Sha256=""},snap),"MD5 fallback lost");
        await CatalogAsync(home,check);await ProtocolAsync(check);await ReconnectAsync(home,check);
    }
    private static async Task CatalogAsync(string home,Action<bool,string> check)
    {
        var remote=new FeedRemote();var store=new ConfigStore(Path.Combine(home,"catalog-data"));await remote.Inner.SeedAsync("a.txt","a",DateTime.UtcNow);
        var catalog=new RemoteCatalog(store,remote);await catalog.RefreshAsync(false,new(),default);check(catalog.State.Items.ContainsKey("a.txt") && catalog.State.Pending.Contains("a.txt"),"Initial remote catalog missing");catalog.Acknowledge();int listed=remote.ListCalls;
        await catalog.RefreshAsync(false,new(),default);check(remote.ListCalls==listed && catalog.State.Pending.Count==0,"Unchanged catalog was rescanned");
        await remote.Inner.SeedAsync("a.txt","changed",DateTime.UtcNow);remote.Changed=["a.txt"];
        await catalog.RefreshAsync(false,new(),default);var reloaded=new RemoteCatalog(store,remote);check(reloaded.State.Pending.Contains("a.txt") && reloaded.State.Cursor==catalog.State.Cursor,"Cursor advanced without durable pending paths");
        catalog.Acknowledge();remote.Expired=true;await catalog.RefreshAsync(false,new(),default);check(remote.ListCalls>listed,"Expired cursor did not rebuild metadata index");
        string old=".safesync-trash/20000101-123456-deleted/old.txt",recent=".safesync-trash/"+DateTime.Now.ToString("yyyyMMdd-HHmmssfff")+"-replaced-id/recent.txt";
        await remote.Inner.SeedAsync(old,"old",DateTime.UtcNow);await remote.Inner.SeedAsync(recent,"recent",DateTime.UtcNow);
        var job=new BackupJob {Source=Path.Combine(home,"cloud-source"),DestinationType="GoogleDrive",Destination="Cloud",CloudFolderId=remote.Root,CloudAccountId=remote.AccountId};Directory.CreateDirectory(job.Source);
        var trash=new CloudTrash(remote,new(store,job,remote),store);var rows=new List<CloudTrashItem>();await foreach(var item in trash.ListAsync(default))rows.Add(item);check(rows.Any(r=>r.StoragePath==old) && rows.Any(r=>r.StoragePath==recent),"Legacy cloud trash hidden");
        var engine=new BackupEngine(store){CloudFactory=_=>remote};await engine.RunAsync(job,true,null,new(),null,default);
        check(!remote.Inner.Files.ContainsKey(old) && remote.Inner.Files.ContainsKey(recent),"Retention skipped legacy trash or removed recent trash");
        var state=store.LoadState(job);state.LastFullScanUtc=DateTime.UtcNow.AddYears(-1).ToString("O");store.SaveState(state);var stages=new List<string>();remote.Changed=[];
        await engine.RunAsync(job,false,null,new(),new Reporter(p=>stages.Add(p.Stage)),default);check(!stages.Contains("원본 폴더 비교"),"Age triggered a full cloud source scan");
        int sourceOnlyLists=remote.NonInternalListCalls;
        File.WriteAllText(Path.Combine(job.Source,"offline-new.txt"),"offline change");
        await remote.Inner.SeedAsync("external-only.txt","external change",DateTime.UtcNow);remote.Changed=["external-only.txt"];
        state=store.LoadState(job);state.FullScanRequired=true;store.SaveState(state);stages.Clear();
        var sourceReconciled=await engine.RunAsync(job,false,null,new(),new Reporter(p=>stages.Add(p.Stage)),default,reconcileOffline:true);
        check(stages.Contains("원본 폴더 비교") && sourceReconciled.Copied==1 && sourceReconciled.Errors.Count==0 && remote.NonInternalListCalls==sourceOnlyLists,"Source reconciliation rebuilt a valid remote catalog or lost an offline source change");
        check(new RemoteCatalog(store,remote).State.Items.ContainsKey("external-only.txt"),"Source rescan skipped remote change feed");
        await engine.RunAsync(job,true,null,new(),null,default);check(remote.NonInternalListCalls>sourceOnlyLists,"Manual full comparison stopped rebuilding remote catalog");
        sourceOnlyLists=remote.NonInternalListCalls;remote.Expired=true;
        await engine.RunAsync(job,false,null,new(),null,default);check(remote.NonInternalListCalls>sourceOnlyLists,"Expired remote cursor did not rebuild independently of source scan");
        // Keep the two upload candidates adjacent; an unchanged earlier source
        // would share the first two-item group and hide concurrent uploads.
        File.Delete(Path.Combine(job.Source,"offline-new.txt"));
        File.WriteAllText(Path.Combine(job.Source,"parallel-a.txt"),"small a");File.WriteAllText(Path.Combine(job.Source,"parallel-b.txt"),"small b");
        var parallel=await engine.RunAsync(job,true,null,new(),null,default);
        check(parallel.Copied==2 && parallel.Errors.Count==0 && remote.MaximumUploads==2,"Small-file pipeline not bounded at two concurrent uploads");
        File.WriteAllText(Path.Combine(job.Source,"cancel-a.txt"),"cancel a");File.WriteAllText(Path.Combine(job.Source,"cancel-b.txt"),"cancel b");
        using(var cancel=new CancellationTokenSource(60))
        {
            var canceled=await engine.RunAsync(job,false,new[]{"cancel-a.txt","cancel-b.txt"},new(),null,cancel.Token);
            check(canceled.Canceled && store.LoadState(job).PendingPaths.Contains("cancel-a.txt"),"Canceled pipeline lost pending work");
        }
        var recovered=await engine.RunAsync(job,false,null,new(),null,default);
        check(recovered.Errors.Count==0 && remote.Inner.Files.ContainsKey("cancel-a.txt") && remote.Inner.Files.ContainsKey("cancel-b.txt"),"Canceled pipeline did not recover safely");
        Directory.CreateDirectory(Path.Combine(job.Source,"nested"));File.WriteAllText(Path.Combine(job.Source,"nested","file.txt"),"nested");
        await engine.RunAsync(job,false,new[]{"nested"},new(),null,default);remote.Changed=["nested"];
        await engine.RunAsync(job,false,null,new(),null,default);
        check(new RemoteCatalog(store,remote).State.Items.TryGetValue("nested",out var folder) && folder.Folder,"Directory work item removed a live folder from the remote index");
    }
    private static async Task ReconnectAsync(string home,Action<bool,string> check)
    {
        var source=Path.Combine(home,"reconnect-source");var backup=Path.Combine(home,"reconnect-backup");Directory.CreateDirectory(backup);
        var job=new BackupJob {Source=source,Destination=backup};var scheduler=new BackupScheduler(new ConfigStore(Path.Combine(home,"reconnect-data")));scheduler.SetJobs(new[]{job});scheduler.Start();
        try
        {
            await Task.Delay(2400);Directory.CreateDirectory(source);File.WriteAllText(Path.Combine(source,"one.txt"),"one");
            async Task<bool> Wait(string name){for(int i=0;i<70;i++){if(File.Exists(Path.Combine(backup,name)))return true;await Task.Delay(200);}return false;}
            check(await Wait("one.txt"),"Reconnected source did not resume automatically");
            File.WriteAllText(Path.Combine(source,"two.txt"),"two");check(await Wait("two.txt"),"Reconnected source watcher not attached");
        }
        finally{await scheduler.DisposeAsync();}
        check(scheduler.RunningCount==0,"Reconnect scheduler did not exit");
        var scheduled=new BackupJob {Source=source,Destination=backup,TriggerType="Scheduled",LastScheduledRun=DateTime.Now.ToString("yyyy-MM-dd")};
        File.WriteAllText(Path.Combine(source,"unlock-after-restart.txt"),"unlocked");
        var retryStore=new ConfigStore(Path.Combine(home,"restart-retry-data"));var state=ConfigStore.NewState(scheduled);
        state.Files=[new(){RelativePath="unlock-after-restart.txt",Status="Locked"}];state.PendingPaths=["unlock-after-restart.txt"];retryStore.SaveState(state);
        var retryScheduler=new BackupScheduler(retryStore){LockedRetryDelay=TimeSpan.FromMilliseconds(100)};retryScheduler.SetJobs(new[]{scheduled});retryScheduler.Start();
        try
        {
            for(int i=0;i<70 && !File.Exists(Path.Combine(backup,"unlock-after-restart.txt"));i++)await Task.Delay(200);
            check(File.Exists(Path.Combine(backup,"unlock-after-restart.txt")),"Restarted scheduled job did not retry a previously locked file");
        }
        finally{await retryScheduler.DisposeAsync();}
        check(retryScheduler.RunningCount==0,"Restarted lock retry scheduler did not exit");
    }
    private static async Task ProtocolAsync(Action<bool,string> check)
    {
        int batchCalls=0,largestBatch=0;var now=DateTime.UtcNow;
        object Metadata(string id,string name,bool folder=false)=>new{id,name,mimeType=folder ? "application/vnd.google-apps.folder" : "application/octet-stream",parents=id=="root-id" ? Array.Empty<string>() : new[]{"root-id"},size=1,modifiedTime=now.ToString("O"),createdTime=now.ToString("O"),md5Checksum="hash",version="1",trashed=false};
        using var client=new HttpClient(new Handler(async(request,token)=>
        {
            var uri=request.RequestUri!;var path=uri.AbsolutePath;
            if(path.EndsWith("/about"))return Json(new{user=new{permissionId="account"}});
            if(path.EndsWith("/files/root-id"))return Json(Metadata("root-id","Backup",true));
            if(path.EndsWith("/changes/startPageToken"))return Json(new{startPageToken="captured"});
            if(path.EndsWith("/changes"))return Json(new{newStartPageToken="advanced",changes=new object[]{new{fileId="removed-id",removed=true},new{fileId="new-id",removed=false,file=Metadata("new-id","new.txt")}}});
            if(path=="/batch/drive/v3")
            {
                var body=await request.Content!.ReadAsStringAsync(token);var ids=Regex.Matches(body,@"Content-ID: <(\d+)>");batchCalls++;largestBatch=Math.Max(largestBatch,ids.Count);
                var text=new StringBuilder();foreach(Match match in ids)
                {
                    int index=int.Parse(match.Groups[1].Value);var idMatch=Regex.Match(body[match.Index..],@"/files/(id-\d+)\?");var id=idMatch.Groups[1].Value;
                    text.Append("--response\r\nContent-Type: application/http\r\nContent-ID: <response-"+index+">\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"+JsonSerializer.Serialize(Metadata(id,id+".txt"))+"\r\n");
                }
                text.Append("--response--\r\n");return new(HttpStatusCode.OK){Content=new StringContent(text.ToString(),Encoding.UTF8,"multipart/mixed"){Headers={ContentType=new("multipart/mixed"){Parameters={new("boundary","response")}}}}};
            }
            throw new Exception("Unexpected synthetic Drive request: "+uri);
        }));
        var remote=new GoogleDriveStore(new(client,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"root-id","account");await remote.InitializeAsync(default);
        check(await remote.CaptureCursorAsync(default)=="captured","Drive capture cursor missing");
        var known=new Dictionary<string,RemoteItem>{{"old.txt",new("removed-id","old.txt",false,1,now,now,"hash","1")}};var changes=await remote.ChangesAsync("old",known,default);
        check(changes.Cursor=="advanced" && changes.Paths.Contains("old.txt") && changes.Paths.Contains("new.txt"),"Drive change paths lost");
        known=Enumerable.Range(0,103).ToDictionary(i=>"id-"+i+".txt",i=>new RemoteItem("id-"+i,"id-"+i+".txt",false,1,now,now,"hash","1"));
        var result=await remote.StatManyAsync(known,known.Keys,default);check(result.Count==103 && batchCalls==2 && largestBatch==100,"Drive metadata did not batch at most 100 files");
        int continuations=0;using var dbClient=new HttpClient(new Handler(async(request,token)=>
        {
            var path=request.RequestUri!.AbsolutePath;if(path.EndsWith("get_current_account"))return Json(new{account_id="account"});
            if(path.EndsWith("get_latest_cursor")){using var input=JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));check(input.RootElement.GetProperty("recursive").GetBoolean(),"Dropbox cursor is not recursive");return Json(new{cursor="initial"});}
            if(path.EndsWith("/continue")){continuations++;return Json(new{cursor=continuations==1 ? "page2" : "end",has_more=continuations==1,entries=new[]{new Dictionary<string,object>{{".tag","deleted"},{"path_display","/file-"+continuations+".txt"}}}});}
            throw new Exception("Unexpected Dropbox request");
        }));
        var db=new DropboxStore(new(dbClient,(_,_)=>Task.FromResult("synthetic")),new TestVault(),"/","account");await db.InitializeAsync(default);check(await db.CaptureCursorAsync(default)=="initial","Dropbox capture cursor missing");var dbChanges=await db.ChangesAsync("initial",new Dictionary<string,RemoteItem>(),default);check(dbChanges.Cursor=="end" && dbChanges.Paths.Count==2,"Dropbox change pagination lost paths");
    }
    private static HttpResponseMessage Json(object body)=>new(HttpStatusCode.OK){Content=CloudJson.Body(body)};
    private sealed class Handler(Func<HttpRequestMessage,CancellationToken,Task<HttpResponseMessage>> run):HttpMessageHandler{protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)=>run(request,token);}
    private sealed class Reporter(Action<BackupProgress> report):IProgress<BackupProgress>{public void Report(BackupProgress value)=>report(value);}
    private sealed class FeedRemote:IRemoteStore,IRemoteChanges,IRemoteParallel
    {
        public MemoryRemote Inner {get;}=new("GoogleDrive");public string Provider=>Inner.Provider;public string Root=>Inner.Root;public string AccountId=>Inner.AccountId;
        public int ListCalls,NonInternalListCalls;public bool Expired;public string[] Changed=[];private int cursor;
        private readonly object gate=new();private int active;public int MaximumUploads;
        public Task<string> CaptureCursorAsync(CancellationToken token)=>Task.FromResult((++cursor).ToString());
        public Task<RemoteChanges> ChangesAsync(string previous,IReadOnlyDictionary<string,RemoteItem> known,CancellationToken token){if(Expired){Expired=false;throw new CloudApiException(HttpStatusCode.Gone,"Expired synthetic cursor");}var paths=Changed;Changed=[];return Task.FromResult(new RemoteChanges((++cursor).ToString(),paths));}
        public Task InitializeAsync(CancellationToken token)=>Inner.InitializeAsync(token);public Task<RemoteItem?> StatAsync(string relative,CancellationToken token){lock(gate)return Inner.StatAsync(relative,token);}
        public Task<IReadOnlyList<RemoteItem>> ListAsync(string relative,CancellationToken token){lock(gate){ListCalls++;if(!relative.StartsWith(".safesync-",StringComparison.Ordinal))NonInternalListCalls++;return Inner.ListAsync(relative,token);}}
        public Task EnsureFolderAsync(string relative,CancellationToken token){lock(gate)return Inner.EnsureFolderAsync(relative,token);}
        public async Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string relative,UploadSession session,Action save,PauseGate pause,CancellationToken token)
        {
            await pause.WaitAsync(token);lock(gate){active++;MaximumUploads=Math.Max(MaximumUploads,active);}
            try{await Task.Delay(200,token);lock(gate)return Inner.UploadAsync(snapshot,relative,session,save,new(),token).GetAwaiter().GetResult();}
            finally{lock(gate)active--;}
        }
        public Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token){lock(gate)return Inner.MoveAsync(from,to,token);}
        public Task DownloadAsync(string relative,string local,CancellationToken token)=>Inner.DownloadAsync(relative,local,token);
        public Task DeleteAsync(string relative,CancellationToken token){lock(gate)return Inner.DeleteAsync(relative,token);}
    }
}
