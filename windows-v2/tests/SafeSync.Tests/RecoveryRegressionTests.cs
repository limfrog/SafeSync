using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class RecoveryRegressionTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var ledger=new NoticeLedger(Path.Combine(root,"dismiss-messages"));
        var error=new BackupResult();error.Errors.Add(new("job","name","a.txt","persistent error",0,0,"",""));
        ledger.Apply("job",error);var viewed=ledger.Entries.ToArray();ledger.Add("other","arrived after viewing");ledger.Dismiss(viewed);
        check(ledger.Entries.Count==1 && ledger.Entries.Single().JobId=="other","Clearing viewed messages removed a newly arrived notice.");
        ledger=new NoticeLedger(Path.Combine(root,"dismiss-messages"));
        check(ledger.Apply("job",error)==0 && ledger.Entries.Count==1,"Dismissed unresolved error reappeared after retry/restart.");
        var fixedResult=new BackupResult();fixedResult.ResolvedPaths.Add("a.txt");ledger.Apply("job",fixedResult);
        check(ledger.Apply("job",error)==1,"A new error recurrence after resolution stayed suppressed.");
        ledger.Add("job","job failure");ledger.Dismiss(ledger.Entries.ToArray());
        check(!ledger.Add("job","job failure") && ledger.Entries.Count==0,"Dismissed job-level failure reappeared.");
        check(ledger.Add("job","different job failure"),"A distinct new failure was hidden.");

        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        {
            var home=Path.Combine(root,"binding-"+provider);var source=Path.Combine(home,"source");Directory.CreateDirectory(source);
            await File.WriteAllTextAsync(Path.Combine(source,"retained.txt"),"source stays");
            var store=new ConfigStore(Path.Combine(home,"data"));var remote=new MemoryRemote(provider);
            var job=new BackupJob {Source=source,Destination=provider+" / old",DestinationType=provider,CloudFolderId="old-root",CloudAccountId="old-account",SyncMode="TwoWay",MirrorDeletes=true};
            var oldState=ConfigStore.NewState(job);oldState.Files.Add(new(){RelativePath="retained.txt",Status="BackedUp"});store.SaveState(oldState);
            var config=new AppConfig {Jobs=[job]};var accounts=new CloudAccounts();var account=accounts.For(provider);account.AccountId=remote.AccountId;account.RefreshTokenProtected="synthetic-not-a-token";account.AccessMode=GoogleFileAccess.Mode;accounts.Write(config);
            check(CloudJobBinding.NeedsReview(config,job),provider+" changed account did not require confirmation.");
            using(var service=new CloudServices(()=>config))
            {
                bool rejected=false;try{service.ForJob(job);}catch(CloudBindingException){rejected=true;}check(rejected,provider+" silently switched accounts before user confirmation.");
            }
            var rebound=CloudJobBinding.Rebind(config,job,remote.Root,provider+" / new",remote.AccountId,"new-folder-id");
            check(rebound.Id!=job.Id && rebound.Stopped && !rebound.Paused && !rebound.CloudBindingReviewRequired,provider+" rebind reused old run identity or started automatically.");
            check(job.CloudAccountId=="old-account" && store.LoadState(job).Files.Count==1 && store.LoadState(rebound).Files.Count==0,provider+" rebind lost old state or reused old deletion baseline.");
            check(!CloudJobBinding.NeedsReview(config,rebound) && rebound.Source==job.Source && rebound.SyncMode==(provider=="GoogleDrive" ? "OneWay" : job.SyncMode) && rebound.MirrorDeletes,provider+" confirmed folder did not retain supported job options.");
            bool changedAgain=false;try{CloudJobBinding.Rebind(config,job,remote.Root,"new","unexpected-account","");}catch(CloudBindingException){changedAgain=true;}
            check(changedAgain,provider+" account change during folder selection was accepted.");
            await remote.SeedAsync("remote-only.txt","remote stays",DateTime.UtcNow);
            var engine=new BackupEngine(store){CloudFactory=_=>remote};rebound.Stopped=false;
            var result=await engine.RunAsync(rebound,true,null,new(),null,default);
            check(result.Errors.Count==0 && result.Conflicts.Count==0 && File.Exists(Path.Combine(source,"retained.txt")) && File.Exists(Path.Combine(source,"remote-only.txt"))==(provider=="Dropbox") && remote.Files.ContainsKey("retained.txt") && remote.Files.ContainsKey("remote-only.txt"),provider+" confirmed rebind propagated stale deletion or downloaded outside one-way policy.");
            rebound.CloudBindingReviewRequired=true;
            check(CloudJobBinding.NeedsReview(config,rebound),provider+" imported binding flag was ignored.");
        }
        foreach(var mode in new[]{"OneWay","TwoWay"})await DuplicatesAsync(root,mode,check);
    }
    private static async Task DuplicatesAsync(string root,string mode,Action<bool,string> check)
    {
        var home=Path.Combine(root,"duplicate-"+mode);var source=Path.Combine(home,"source");Directory.CreateDirectory(Path.Combine(source,"folder"));
        await File.WriteAllTextAsync(Path.Combine(source,"dup.txt"),"keep remote");await File.WriteAllTextAsync(Path.Combine(source,"folder","child.txt"),"keep child");
        var remote=new DuplicateRemote();var job=new BackupJob {Source=source,Destination="cloud",DestinationType="GoogleDrive",CloudFolderId=remote.Root,CloudAccountId=remote.AccountId,SyncMode=mode,MirrorDeletes=true};
        var store=new ConfigStore(Path.Combine(home,"data"));var engine=new BackupEngine(store){CloudFactory=_=>remote};
        async Task<BackupResult> Run(bool full=false)=>await engine.RunAsync(job,full,new[]{"dup.txt","folder/child.txt","good.txt"},new(),null,default);
        var baseline=await Run(true);check(baseline.Errors.Count+baseline.Conflicts.Count==0,mode+" duplicate fixture baseline failed.");
        var originalId=remote.Inner.Files["dup.txt"].Id;File.Delete(Path.Combine(source,"dup.txt"));
        remote.DuplicatePaths.UnionWith(new[]{"dup.txt","folder"});
        await File.WriteAllTextAsync(Path.Combine(source,"good.txt"),"continue other files");
        var result=await Run(true);
        check(result.Errors.Count==0 && result.Conflicts.Any(i=>i.File=="dup.txt") && result.Conflicts.Any(i=>i.File=="folder/child.txt"),mode+" duplicate names failed whole run or omitted conflict paths.");
        check(remote.Inner.Files["dup.txt"].Id==originalId && File.ReadAllText(Path.Combine(source,"folder","child.txt"))=="keep child" && remote.Inner.Files.ContainsKey("folder/child.txt"),mode+" ambiguous path propagated a deletion.");
        check(remote.Inner.Files.ContainsKey("good.txt") && result.Copied>=1,mode+" duplicate name stopped unrelated backup.");
        var reloaded=new RemoteCatalog(store,remote);check(reloaded.IsAmbiguous("folder/child.txt") && reloaded.IsAmbiguous("folder") && !reloaded.IsAmbiguous("good.txt"),mode+" ambiguous subtree was not durably protected.");
        int listed=remote.ListCalls;var repeated=await Run();
        check(repeated.Errors.Count==0 && repeated.Conflicts.Count>0 && remote.ListCalls==listed,mode+" repeated ambiguity forced a full cloud scan or failed.");
        remote.DuplicatePaths.Clear();var resolved=await Run();
        check(resolved.Errors.Count==0 && resolved.Conflicts.Count==0 && !new RemoteCatalog(store,remote).IsAmbiguous("folder/child.txt"),mode+" resolving duplicate names did not unblock the paths.");
    }
    private sealed class DuplicateRemote:IRemoteStore,IRemoteChanges,IRemoteBatch
    {
        public MemoryRemote Inner {get;}=new("GoogleDrive");
        public HashSet<string> DuplicatePaths {get;}=new(StringComparer.OrdinalIgnoreCase);
        public int ListCalls;
        public string Provider=>Inner.Provider;public string Root=>Inner.Root;public string AccountId=>Inner.AccountId;
        public Task InitializeAsync(CancellationToken token)=>Inner.InitializeAsync(token);
        public Task<RemoteItem?> StatAsync(string path,CancellationToken token)
        {
            var duplicate=DuplicatePaths.FirstOrDefault(p=>path.Equals(p,StringComparison.OrdinalIgnoreCase)||path.StartsWith(p+"/",StringComparison.OrdinalIgnoreCase));
            if(duplicate!=null)throw new CloudDuplicateNameException(duplicate);return Inner.StatAsync(path,token);
        }
        public async Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken token)
        {
            ListCalls++;var items=(await Inner.ListAsync(directory,token)).ToList();
            foreach(var item in items.ToArray())if(DuplicatePaths.Contains(directory.Length==0 ? item.Name : directory+"/"+item.Name))items.Add(item with{Id="duplicate-"+item.Id});return items;
        }
        public async Task<IReadOnlyDictionary<string,RemoteItem?>> StatManyAsync(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> paths,CancellationToken token)
        {var result=new Dictionary<string,RemoteItem?>();foreach(var path in paths)result[path]=await StatAsync(path,token);return result;}
        public Task<string> CaptureCursorAsync(CancellationToken token)=>Task.FromResult("cursor");
        public Task<RemoteChanges> ChangesAsync(string cursor,IReadOnlyDictionary<string,RemoteItem> known,CancellationToken token)=>Task.FromResult(new RemoteChanges("cursor",[]));
        public Task EnsureFolderAsync(string path,CancellationToken token)=>Inner.EnsureFolderAsync(path,token);
        public Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string path,UploadSession session,Action save,PauseGate pause,CancellationToken token)=>Inner.UploadAsync(snapshot,path,session,save,pause,token);
        public Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token)=>Inner.MoveAsync(from,to,token);
        public Task DownloadAsync(string path,string local,CancellationToken token)=>Inner.DownloadAsync(path,local,token);
        public Task DeleteAsync(string path,CancellationToken token)=>Inner.DeleteAsync(path,token);
    }
}
