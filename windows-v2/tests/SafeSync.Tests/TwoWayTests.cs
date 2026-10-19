using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class TwoWayTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            var home=Path.Combine(root,"two-way-"+provider);var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");
            Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            var store=new ConfigStore(Path.Combine(home,"data"));var remote=provider=="Local" ? null : new MemoryRemote(provider);
            var job=new BackupJob {Name="양방향 검증",Source=source,Destination=backup,SyncMode="TwoWay",DestinationType=provider,CloudAccountId=remote?.AccountId ?? "",CloudFolderId=remote?.Root ?? ""};
            var engine=new BackupEngine(store){CloudFactory=_=>remote!};
            Task<BackupResult> Run(string[]? paths=null,Dictionary<string,ConflictAction>? choices=null,bool full=false,CancellationToken ct=default,PauseGate? pause=null,IProgress<BackupProgress>? progress=null)
                =>engine.RunAsync(job,full,paths,pause ?? new(),progress,ct,choices);
            void Write(string name,string text){var path=PathPolicy.Combine(source,name);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,text,Encoding.UTF8);}
            async Task Put(string name,string text)
            {
                if(remote!=null)await remote.SeedAsync(name,"\uFEFF"+text,DateTime.UtcNow);
                else {var path=PathPolicy.Combine(backup,name);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,text,Encoding.UTF8);}
            }
            string Read(string name)=>File.ReadAllText(PathPolicy.Combine(source,name));
            string ReadBackup(string name)=>remote==null ? File.ReadAllText(PathPolicy.Combine(backup,name)) : Encoding.UTF8.GetString(remote.Bytes(name)).TrimStart('\uFEFF');
            bool ExistsBackup(string name)=>remote==null ? File.Exists(PathPolicy.Combine(backup,name)) : remote.Files.ContainsKey(name);
            async Task DeleteBackup(string name){if(remote==null)File.Delete(PathPolicy.Combine(backup,name));else await remote.DeleteAsync(name,default);}
            void Healthy(BackupResult r,string label)=>check(!r.Canceled && r.Errors.Count==0 && r.Locked.Count==0 && r.Conflicts.Count==0,provider+": "+label+" "+string.Join(";",r.Errors.Concat(r.Conflicts).Select(x=>x.Reason)));

            Write("원본전용.txt","left");await Put("backup-only.txt","right");
            Write("both.txt","same");await Put("both.txt","same");
            Write("conflict.txt","source version");await Put("conflict.txt","backup version");
            var first=await Run(full:true);
            check(first.Copied==2 && first.Conflicts.Count==1 && first.Errors.Count==0,provider+" initial union was destructive or missed conflict");
            check(Read("backup-only.txt")=="right" && ReadBackup("원본전용.txt")=="left",provider+" initial union bytes wrong");
            check(Read("conflict.txt")=="source version" && ReadBackup("conflict.txt")=="backup version",provider+" initial conflict overwritten");
            check(store.LoadState(job).Files.Single(x=>x.RelativePath=="conflict.txt").SyncSource==null,provider+" conflict became baseline");
            var resolved=await Run(choices:new(){{"conflict.txt",ConflictAction.UseBackup}});Healthy(resolved,"reverse conflict resolution");
            check(Read("conflict.txt")=="backup version",provider+" reverse conflict choice ignored");
            Healthy(await Run(),"unchanged");check((await Run()).Copied==0,provider+" unchanged recopied");
            if(provider=="Local")
            {
                var scanStages=new List<string>();var noChange=await Run(progress:new Reporter(p=>scanStages.Add(p.Stage)));
                check(noChange.Copied==0 && !scanStages.Contains("원본 폴더 비교") && !scanStages.Contains("백업 폴더 비교"),"Two-way unchanged realtime run rescanned complete local trees");
            }

            // Same length, same timestamps: dirty paths MUST rehash, not skip.
            var stamp=File.GetLastWriteTimeUtc(PathPolicy.Combine(source,"both.txt"));Write("both.txt","edit");File.SetLastWriteTimeUtc(PathPolicy.Combine(source,"both.txt"),stamp);
            Healthy(await Run(["both.txt"]),"same metadata source edit");check(ReadBackup("both.txt")=="edit",provider+" same-size fast edit missed");
            await Put("both.txt","back");Healthy(await Run(["both.txt"]),"backup edit");check(Read("both.txt")=="back",provider+" backup edit not downloaded");

            // Destination deletion really deletes source, but retains a copy.
            await DeleteBackup("원본전용.txt");Healthy(await Run(["원본전용.txt"]),"destination delete");
            check(!File.Exists(PathPolicy.Combine(source,"원본전용.txt")),provider+" destination delete did not propagate");
            check(new TrashService().List(source,default).Any(x=>x.RelativePath=="원본전용.txt"),provider+" source deleted without trash");
            File.Delete(PathPolicy.Combine(source,"backup-only.txt"));Healthy(await Run(["backup-only.txt"]),"source delete");check(!ExistsBackup("backup-only.txt"),provider+" source delete did not propagate");
            check(remote==null ? new TrashService().List(backup,default).Any(x=>x.RelativePath=="backup-only.txt") : remote.Files.Any(x=>x.Key.StartsWith(".safesync-trash/") && x.Key.EndsWith("backup-only.txt")),provider+" backup deletion lost trash");

            // Modified vs deleted is a conflict. The modified survivor is safe.
            Write("both.txt","important edit");await DeleteBackup("both.txt");
            var deleteEdit=await Run(["both.txt"]);check(deleteEdit.Conflicts.Count==1 && Read("both.txt")=="important edit",provider+" delete/edit conflict destroyed data");
            Healthy(await Run(choices:new(){{"both.txt",ConflictAction.Overwrite}}),"recreate by explicit source choice");
            Write("both.txt","left change");await Put("both.txt","right change");Write("unrelated.txt","still copy");
            var simultaneous=await Run(["both.txt","unrelated.txt"]);check(simultaneous.Conflicts.Count==1 && ReadBackup("unrelated.txt")=="still copy",provider+" conflict blocked other files");
            var before=store.LoadState(job).Files.Single(x=>x.RelativePath=="both.txt").SyncSource!.Hash;
            await Run(choices:new(){{"both.txt",ConflictAction.Ignore}});
            check(store.LoadState(job).Files.Single(x=>x.RelativePath=="both.txt").SyncSource!.Hash==before,provider+" ignore advanced baseline");
            Healthy(await Run(choices:new(){{"both.txt",ConflictAction.KeepBoth}}),"keep both");
            check(ReadBackup("both.txt")=="left change",provider+" keep both did not publish");
            check(remote==null ? Directory.EnumerateFiles(backup,"both.txt.SafeSync-conflict-*").Any() : remote.Files.Keys.Any(x=>x.StartsWith("both.txt.SafeSync-conflict-")),provider+" keep both discarded old version");
            Healthy(await Run(full:true),"discover preserved sibling");
            check(Directory.EnumerateFiles(source,"both.txt.SafeSync-conflict-*").Any(),provider+" preserved sibling not synchronized");

            Write("locked.txt","one");Healthy(await Run(["locked.txt"]),"lock baseline");Write("locked.txt","two");
            var lockedBaseline=store.LoadState(job).Files.Single(x=>x.RelativePath=="locked.txt").SyncSource!.Hash;
            using(var locked=new FileStream(PathPolicy.Combine(source,"locked.txt"),FileMode.Open,FileAccess.ReadWrite,FileShare.None))
            {
                var waiting=await Run(["locked.txt"]);check(waiting.Locked.Count==1 && waiting.Errors.Count==0,provider+" lock became ordinary error");
                check(store.LoadState(job).Files.Single(x=>x.RelativePath=="locked.txt").SyncSource!.Hash==lockedBaseline,provider+" lock advanced baseline");
            }
            Healthy(await Run(),"retry locked");check(ReadBackup("locked.txt")=="two",provider+" unlock retry lost");
            if(remote!=null)
            {
                var baseline=store.LoadState(job).Files.Single(x=>x.RelativePath=="locked.txt").SyncSource!.Hash;
                await Put("locked.txt","verified remote replacement");remote.CorruptDownload=true;
                var damaged=await Run(["locked.txt"]);
                check(damaged.Errors.Count==1 && Read("locked.txt")=="two",provider+" corrupt download damaged source");
                check(store.LoadState(job).Files.Single(x=>x.RelativePath=="locked.txt").SyncSource!.Hash==baseline,provider+" failed download advanced baseline");
                Healthy(await Run(),"retry corrupt download");check(Read("locked.txt")=="verified remote replacement",provider+" failed download not retried");
            }

            var pauseGate=new PauseGate();pauseGate.Pause();var paused=Run(["locked.txt"],pause:pauseGate);
            await Task.Delay(100);check(!paused.IsCompleted,provider+" pause did not wait");pauseGate.Resume();Healthy(await paused,"resume");
            using(var cancel=new CancellationTokenSource())
            {
                Write("cancel.txt","pending");var pg=new PauseGate();
                var progress=new Reporter(p=>{if(p.Stage=="양쪽 파일 변경 비교" && p.CurrentFile=="cancel.txt")cancel.Cancel();});
                var canceled=await Run(["cancel.txt"],ct:cancel.Token,pause:pg,progress:progress);
                check(canceled.Canceled,provider+" cancellation not recorded");
            }
            Healthy(await Run(),"resume canceled");check(ReadBackup("cancel.txt")=="pending",provider+" canceled pending file lost");

            // Restart keeps common baseline; only successful paths commit.
            await DeleteBackup("locked.txt");engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=_=>remote!};
            Healthy(await Run(),"restart delete");check(!File.Exists(PathPolicy.Combine(source,"locked.txt")),provider+" restart lost deletion baseline");
            var serialized=System.Text.Json.JsonSerializer.Serialize(job,JsonFile.Options);
            check(System.Text.Json.JsonSerializer.Deserialize<BackupJob>(serialized,JsonFile.Options)!.SyncMode=="TwoWay",provider+" mode did not round trip");
            job.SyncMode="OneWay";check(store.LoadState(job).Files.Count==0,provider+" one-way reused two-way deletion baseline");job.SyncMode="TwoWay";

            Directory.CreateDirectory(PathPolicy.Combine(source,"empty/nested"));
            Healthy(await Run(full:true),"empty folder union");
            check(remote==null ? Directory.Exists(PathPolicy.Combine(backup,"empty/nested")) : remote.Files.GetValueOrDefault("empty/nested")?.Folder==true,provider+" empty nested folder not mirrored");
            if(remote==null){Directory.Delete(PathPolicy.Combine(backup,"empty/nested"));Directory.Delete(PathPolicy.Combine(backup,"empty"));}
            else {await remote.DeleteAsync("empty/nested",default);await remote.DeleteAsync("empty",default);}
            Healthy(await Run(full:true),"empty folder deletion");
            check(!Directory.Exists(PathPolicy.Combine(source,"empty")),provider+" empty folder deletion not mirrored");

            // Unavailable root MUST fail closed, not remove opposite files.
            var offline=source+"-offline";Directory.Move(source,offline);bool failed=false;
            try{await Run();}catch(DirectoryNotFoundException){failed=true;}
            finally{Directory.Move(offline,source);}
            check(failed && ExistsBackup("cancel.txt"),provider+" disconnected root caused deletion");
            if(remote==null)
            {
                Directory.Move(backup,backup+"-prior");Directory.CreateDirectory(backup);failed=false;
                try{await Run();}catch(IOException){failed=true;}
                check(failed && File.Exists(PathPolicy.Combine(source,"cancel.txt")),"Replaced destination root caused mass deletion");
            }
        }
        check(new BackupJob().SyncMode=="OneWay","Old config no longer defaults to one-way");
    }
    public static async Task NasAsync(string root,string nasRoot,Action<bool,string> check)
    {
        nasRoot=Path.GetFullPath(nasRoot);
        if(!nasRoot.StartsWith(@"\\",StringComparison.Ordinal) || !Directory.Exists(nasRoot))throw new IOException("NAS test root unavailable.");
        var home=Path.Combine(nasRoot,"SafeSync-twoway-validation-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(home);
        var stages=new List<object>();int start=0;
        foreach(bool sourceOnNas in new[]{false,true})
        {
            var local=Path.Combine(root,"two-way-nas-"+sourceOnNas);var network=Path.Combine(home,sourceOnNas ? "source" : "backup");Directory.CreateDirectory(local);Directory.CreateDirectory(network);
            string source=sourceOnNas ? network : local,backup=sourceOnNas ? local : network;
            var job=new BackupJob {Name="NAS two-way validation",SyncMode="TwoWay",Source=source,Destination=backup};
            var store=new ConfigStore(Path.Combine(root,"two-way-nas-state-"+sourceOnNas));var engine=new BackupEngine(store);
            async Task<BackupResult> Run(string stage,string[]? paths=null,bool full=false,Dictionary<string,ConflictAction>? choices=null)
            {
                var watch=System.Diagnostics.Stopwatch.StartNew();var result=await engine.RunAsync(job,full,paths,new(),null,default,choices);
                check(result.Errors.Count==0 && !result.Canceled,"NAS two-way "+stage+" failed: "+string.Join(";",result.Errors.Select(x=>x.Reason)));start++;
                stages.Add(new{SourceOnNas=sourceOnNas,Stage=stage,Milliseconds=watch.ElapsedMilliseconds,result.Copied,result.Trashed,Conflicts=result.Conflicts.Count});return result;
            }
            File.WriteAllText(Path.Combine(source,"local.txt"),"source");File.WriteAllText(Path.Combine(backup,"nas.txt"),"backup");
            check((await Run("initial-union",full:true)).Copied==2,"NAS initial union failed");
            check(File.ReadAllText(Path.Combine(source,"nas.txt"))=="backup" && File.ReadAllText(Path.Combine(backup,"local.txt"))=="source","NAS union bytes mismatch");
            File.WriteAllText(Path.Combine(backup,"nas.txt"),"edited from backup");
            check((await Run("backup-update",["nas.txt"])).Copied==1,"NAS reverse atomic copy failed");
            check(File.ReadAllText(Path.Combine(source,"nas.txt"))=="edited from backup","NAS reverse content differs");
            File.Delete(Path.Combine(backup,"local.txt"));check((await Run("backup-delete",["local.txt"])).Trashed==1,"NAS destination deletion not mirrored");
            check(new TrashService().List(source,default).Any(x=>x.RelativePath=="local.txt"),"NAS source trash missing");
            File.Delete(Path.Combine(source,"nas.txt"));check((await Run("source-delete",["nas.txt"])).Trashed==1,"NAS source deletion not mirrored");
            check(new TrashService().List(backup,default).Any(x=>x.RelativePath=="nas.txt"),"NAS backup trash missing");
            File.WriteAllText(Path.Combine(source,"conflict.txt"),"original");await Run("baseline",["conflict.txt"]);
            File.WriteAllText(Path.Combine(source,"conflict.txt"),"source edit");File.WriteAllText(Path.Combine(backup,"conflict.txt"),"backup edit");
            check((await Run("conflict",["conflict.txt"])).Conflicts.Count==1,"NAS simultaneous edits not protected");
            check((await Run("resolve",choices:new(){{"conflict.txt",ConflictAction.UseBackup}})).Copied==1,"NAS reverse conflict resolution failed");
            using(var locked=new FileStream(Path.Combine(source,"conflict.txt"),FileMode.Open,FileAccess.ReadWrite,FileShare.None))
                check((await Run("lock",["conflict.txt"])).Locked.Count==1,"NAS locked file not queued");
            await Run("unlock");engine=new BackupEngine(new ConfigStore(store.Root));
            check((await Run("restart")).Copied==0,"NAS restart lost baseline");
            Directory.CreateDirectory(Path.Combine(source,"empty","nested"));await Run("empty-folders",full:true);
            check(Directory.Exists(Path.Combine(backup,"empty","nested")),"NAS empty folder missing");
        }
        JsonFile.Save(Path.Combine(root,"nas-two-way-result.json"),new{Status="OK",AssertionsAtLeast=start,NasFixture=home,Stages=stages,ExistingBackupsTouched=false,TestFilesPreserved=true});
        Console.WriteLine("PASS: NAS two-way tests. Fixtures: "+home);
    }
    private sealed class Reporter(Action<BackupProgress> report):IProgress<BackupProgress>{public void Report(BackupProgress value)=>report(value);}
}
