using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class DeferredResolutionTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        foreach(var mode in new[]{"OneWay","TwoWay"})
            await Scenario(provider,mode,"apply");
        foreach(var scenario in new[]{"cancel","stop","stale","binding","failure","update","pause"})
            await Scenario("Local","OneWay",scenario);

        async Task Scenario(string provider,string mode,string scenario)
        {
            var label=$"{provider}/{mode}/{scenario}";
            var home=Path.Combine(root,"deferred-"+provider+"-"+mode+"-"+scenario);
            var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            File.WriteAllText(Path.Combine(source,"a-conflict.txt"),"left original");File.SetLastWriteTimeUtc(Path.Combine(source,"a-conflict.txt"),DateTime.UtcNow.AddDays(-2));
            File.WriteAllText(Path.Combine(source,"z-finish.txt"),"last normal file");
            var remote=provider=="Local" ? null : new MemoryRemote(provider);
            if(remote!=null)await remote.SeedAsync("a-conflict.txt","right preserved",DateTime.UtcNow.AddDays(-1));
            else{File.WriteAllText(Path.Combine(backup,"a-conflict.txt"),"right preserved");File.SetLastWriteTimeUtc(Path.Combine(backup,"a-conflict.txt"),DateTime.UtcNow.AddDays(-1));}
            var job=new BackupJob{Source=source,Destination=backup,SyncMode=mode,DestinationType=provider,CloudFolderId=remote?.Root ?? "",CloudAccountId=remote?.AccountId ?? ""};
            string Right()=>remote==null ? File.ReadAllText(Path.Combine(backup,"a-conflict.txt")) : System.Text.Encoding.UTF8.GetString(remote.Bytes("a-conflict.txt"));
            bool LastExists()=>remote==null ? File.Exists(Path.Combine(backup,"z-finish.txt")) : remote.Files.ContainsKey("z-finish.txt");
            var choices=new ComparedResolutions();choices.Choose(await FileComparisons.ReadAsync(job,"a-conflict.txt",remote,default),ConflictAction.KeepBoth);
            await using var scheduler=new BackupScheduler(new ConfigStore(Path.Combine(home,"data"))){CloudFactory=remote==null ? null : _=>remote};
            using var release=new ManualResetEventSlim();var reached=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            int started=0,finished=0,canceled=0;bool block=false,ordered=true;BackupResult? last=null;
            scheduler.Started+=_=>{if(Interlocked.Increment(ref started)>1 && !LastExists())ordered=false;};
            scheduler.Completed+=(_,result)=>{last=result;Interlocked.Increment(ref finished);};
            scheduler.ResolutionsCanceled+=(_,_)=>Interlocked.Increment(ref canceled);
            scheduler.Progress+=p=>
            {
                if(!block && p.CurrentFile=="z-finish.txt")
                {block=true;reached.TrySetResult();if(!release.Wait(TimeSpan.FromSeconds(25)))throw new TimeoutException("Fixture was not released");if(scenario=="failure")throw new IOException("Injected outer failure");}
            };
            var task=scheduler.RunAsync(job,true);
            try
            {
                await reached.Task.WaitAsync(TimeSpan.FromSeconds(20));
                check(scheduler.TryQueueResolutions(job,choices),label+" did not accept choices while running");
                check(scheduler.QueuedResolutionCount(job.Id)==1 && Right()=="right preserved",label+" applied before current run completed");
                // The scheduler owns a copy, not the editable UI dictionary.
                choices["a-conflict.txt"]=ConflictAction.UseBackup;choices.Comparisons.Clear();
                if(scenario=="cancel")scheduler.CancelQueuedResolutions(job);
                if(scenario=="stop")scheduler.StopJob(job);
                if(scenario=="binding")job.SyncMode="TwoWay";
                if(scenario=="stale"){File.WriteAllText(Path.Combine(source,"a-conflict.txt"),"changed while waiting");File.SetLastWriteTimeUtc(Path.Combine(source,"a-conflict.txt"),DateTime.UtcNow.AddDays(-3));}
                Task<IDisposable>? holding=null;
                if(scenario=="update")holding=scheduler.HoldForUpdateAsync(default);
                if(scenario=="pause")
                {scheduler.SetPaused(job,true);await Task.Delay(50);check(started==1 && scheduler.QueuedResolutionCount(job.Id)==1,label+" pause discarded or executed the queue");scheduler.SetPaused(job,false);}
                release.Set();await task.WaitAsync(TimeSpan.FromSeconds(25));
                if(holding!=null)(await holding).Dispose();
                check(scheduler.RunningCount==0 && scheduler.QueuedResolutionCount(job.Id)==0,label+" left running ownership or queue behind");
                if(scenario is "apply" or "pause")
                {
                    check(started==2 && finished==2 && ordered,label+" follow-up overtook normal work or overlapped it");
                    check(Right()=="left original" && File.ReadAllText(Path.Combine(source,"a-conflict.txt"))=="left original",label+" did not use the accepted immutable choice");
                    check(remote==null ? Directory.EnumerateFiles(backup,"*.SafeSync-conflict-*").Any(p=>File.ReadAllText(p)=="right preserved") : remote.Files.Keys.Any(p=>p.Contains(".SafeSync-conflict-") && System.Text.Encoding.UTF8.GetString(remote.Bytes(p))=="right preserved"),label+" keep-both lost the original backup");
                    check(!scheduler.TryQueueResolutions(job,new ComparedResolutions()),label+" accepted an empty or idle request");
                }
                else if(scenario=="stale")
                {check(started==2 && last!.Conflicts.Any(i=>i.File=="a-conflict.txt"),label+" stale file did not remain a conflict");check(Right()=="right preserved",label+" overwrote a file changed during the wait");}
                else
                {check(started==1 && canceled==1,label+" canceled intent ran or was silently discarded");check(Right()=="right preserved",label+" canceled intent changed backup");}
            }
            finally{release.Set();await task.WaitAsync(TimeSpan.FromSeconds(25));}
        }
    }
}
