using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class OneWaySafetyTests
{
    private sealed class Reporter(Action<BackupProgress> action):IProgress<BackupProgress>
    {public void Report(BackupProgress value)=>action(value);}
    private sealed class Fixture
    {
        public BackupJob Job {get;}
        public ConfigStore Store {get;}
        public MemoryRemote? Remote {get;}
        public string FilePath=>Path.Combine(Job.Source,"test.txt");
        public Fixture(string home,string provider)
        {
            var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");
            Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            if(provider!="Local")Remote=new(provider);
            Job=new(){Source=source,Destination=backup,DestinationType=provider,CloudFolderId=Remote?.Root ?? "",CloudAccountId=Remote?.AccountId ?? "",MirrorDeletes=true};
            Store=new(Path.Combine(home,"data"));
        }
        // A fresh engine and store exercise persisted baselines, not in-memory state.
        public Task<BackupResult> Run(bool full=false,IProgress<BackupProgress>? progress=null,IReadOnlyDictionary<string,ConflictAction>? actions=null,string[]? paths=null)
        {
            var engine=new BackupEngine(new ConfigStore(Store.Root));if(Remote!=null)engine.CloudFactory=_=>Remote;
            return engine.RunAsync(Job,full,paths ?? ["test.txt"],new(),progress,default,actions);
        }
        public bool Exists=>Remote==null ? File.Exists(Path.Combine(Job.Destination,"test.txt")) : Remote.Files.ContainsKey("test.txt");
        public string BackupText=>Remote==null ? File.ReadAllText(Path.Combine(Job.Destination,"test.txt")) : Encoding.UTF8.GetString(Remote.Bytes("test.txt"));
        public int Trashed=>Remote==null ? new TrashService().List(Job.Destination,default).Count() : Remote.Files.Count(p=>p.Key.StartsWith(".safesync-trash/")&&!p.Value.Folder);
        public async Task Seed()
        {
            File.WriteAllText(FilePath,"AAAA");File.SetLastWriteTimeUtc(FilePath,new DateTime(2026,1,1,0,0,0,DateTimeKind.Utc));
            var result=await Run(true);if(result.Copied!=1 || result.Errors.Count!=0)throw new Exception("Safety fixture initial copy failed.");
        }
    }
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            string Home(string name)=>Path.Combine(root,"one-way-safety",provider,name);
            foreach(int seconds in new[]{0,1,2})
            {
                var f=new Fixture(Home("same-size-"+seconds),provider);await f.Seed();
                var stamp=File.GetLastWriteTimeUtc(f.FilePath);File.WriteAllText(f.FilePath,"BBBB");File.SetLastWriteTimeUtc(f.FilePath,stamp.AddSeconds(seconds));
                var result=await f.Run();var state=f.Store.LoadState(f.Job);
                check(result.Skipped==0 && result.Conflicts.Count==1 && f.BackupText=="AAAA",provider+" silently accepted changed same-size content.");
                check(state.Files.Single().Status=="Conflict" && state.PendingPaths.Contains("test.txt"),provider+" falsely committed changed content.");
                result=await f.Run(true);
                check(result.Conflicts.Count==1 && result.Skipped==0,provider+" full comparison lost content conflict.");
                result=await f.Run(actions:new Dictionary<string,ConflictAction>{{"test.txt",ConflictAction.Overwrite}});
                check(result.Copied==1 && f.BackupText=="BBBB" && f.Store.LoadState(f.Job).PendingPaths.Count==0,provider+" explicit content conflict resolution failed.");
                result=await f.Run(true);
                check(result.Skipped==1 && result.Conflicts.Count==0,provider+" verified equal content not skipped.");
            }
            foreach(bool replace in new[]{false,true})
            {
                var f=new Fixture(Home(replace ? "replaced-root" : "disconnected-root"),provider);await f.Seed();
                var original=f.Store.LoadState(f.Job);bool interrupted=false;
                void Interrupt()
                {
                    if(interrupted)return;interrupted=true;Directory.Move(f.Job.Source,f.Job.Source+"-offline");
                    if(replace)Directory.CreateDirectory(f.Job.Source);
                }
                if(replace)Interrupt();
                var progress=new Reporter(p=>{if(p.CurrentFile=="test.txt" && p.Stage is "파일 비교 및 백업" or "변경 파일의 클라우드 정보 확인")Interrupt();});
                bool blocked=false;
                try{var result=await f.Run(progress:progress);blocked=result.Errors.Count+result.Conflicts.Count>0;}
                catch(IOException){blocked=true;}
                check(interrupted && blocked && f.Exists && f.Trashed==0,provider+" unavailable/replaced root propagated deletion.");
                var after=f.Store.LoadState(f.Job);
                check(after.OneWaySourceIdentity==original.OneWaySourceIdentity && after.Files.Single().Length==4,provider+" root failure advanced/lost baseline.");
                if(!replace)check(after.PendingPaths.Contains("test.txt"),provider+" disconnected file lost retry intent.");
                if(replace)Directory.Move(f.Job.Source,f.Job.Source+"-replacement");
                Directory.Move(f.Job.Source+"-offline",f.Job.Source);
                var resumed=await f.Run();check(resumed.Skipped==1 && resumed.Errors.Count==0,provider+" reconnect did not resume safely.");
                File.Delete(f.FilePath);var deleted=await f.Run();
                check(deleted.Trashed==1 && !f.Exists,provider+" genuine deletion no longer works.");
                var unknown=await f.Run(paths:["never-backed-up.txt"]);
                check(unknown.Errors.Count+unknown.Conflicts.Count==0,provider+" untracked missing watcher event created a conflict.");
            }
            var legacy=new Fixture(Home("legacy-baseline"),provider);await legacy.Seed();
            var old=legacy.Store.LoadState(legacy.Job);old.OneWaySourceIdentity="";old.OneWayBackupIdentity="";
            foreach(var entry in old.Files)entry.DeletionSourceVerified=false;
            legacy.Store.SaveState(old);File.Delete(legacy.FilePath);
            var upgrade=await legacy.Run();
            check(upgrade.Conflicts.Count==1 && legacy.Exists && legacy.Trashed==0,provider+" migration authorized deletion with no source identity.");
            check(legacy.Store.LoadState(legacy.Job).PendingPaths.Contains("test.txt"),provider+" legacy review lost pending path.");
            upgrade=await legacy.Run();check(upgrade.Conflicts.Count==1 && legacy.Exists,provider+" retry silently authorized legacy deletion.");
            // Observing the source again establishes a safe baseline, without
            // replacing any equal backup bytes or discarding the old snapshot.
            File.WriteAllText(legacy.FilePath,"AAAA");await legacy.Run();File.Delete(legacy.FilePath);
            check((await legacy.Run()).Trashed==1,provider+" legacy source revalidation failed.");

            if(provider!="Local")await InterruptedDeletion(Home("delete-journal"),provider,check);
        }
    }
    private static async Task InterruptedDeletion(string home,string provider,Action<bool,string> check)
    {
        var f=new Fixture(home,provider);await f.Seed();File.Delete(f.FilePath);bool interrupted=false;
        // Disconnect after the engine's checks but during the publisher's
        // awaited metadata read. The final pre-mutation guard must still run.
        f.Remote!.BeforeStat=path=>
        {
            if(interrupted || !path.StartsWith(".safesync-trash/"))return;
            interrupted=true;Directory.Move(f.Job.Source,f.Job.Source+"-offline");
        };
        var result=await f.Run();
        check(interrupted && result.Errors.Count>0 && f.Exists && f.Trashed==0,provider+" deletion crossed root failure during remote metadata request.");
        var journalRoot=Path.Combine(f.Store.Root,"cloud-transactions-v2");
        check(Directory.GetFiles(journalRoot,"*.json").Length==1,provider+" interrupted deletion journal was lost.");
        f.Remote.BeforeStat=null;Directory.Move(f.Job.Source+"-offline",f.Job.Source);
        File.WriteAllText(f.FilePath,"returned source");
        result=await f.Run();
        check(result.Conflicts.Count>0 && f.Exists && f.Trashed==0,provider+" recovery deleted backup after source reappeared.");
        File.Delete(f.FilePath);result=await f.Run();
        check(result.Errors.Count+result.Conflicts.Count==0 && !f.Exists && f.Trashed==1,provider+" verified deletion recovery failed.");
    }
}
