using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class GracefulStopTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        using(var semaphore=new SemaphoreSlim(0,1))
        {
            var gate=new PauseGate();var waiting=gate.WaitForBoundaryAsync(semaphore,default);gate.RequestStop();
            bool stopped=false;try{await waiting.WaitAsync(TimeSpan.FromSeconds(2));}catch(JobStoppedException){stopped=true;}
            check(stopped,"Stop did not release a job waiting for another cloud job.");
            semaphore.Release();check(semaphore.Wait(0),"Stopped waiter consumed another job's semaphore permit.");
        }
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        foreach(var mode in new[]{"OneWay","TwoWay"})
        {
            var home=Path.Combine(root,"graceful-"+provider+"-"+mode);var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");
            Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            File.WriteAllText(Path.Combine(source,"a.txt"),"first complete file");File.WriteAllText(Path.Combine(source,"b.txt"),"second pending file");
            var store=new ConfigStore(Path.Combine(home,"data"));var remote=provider=="Local" ? null : new MemoryRemote(provider);
            var job=new BackupJob {Source=source,Destination=backup,SyncMode=mode,DestinationType=provider,CloudFolderId=remote?.Root ?? "",CloudAccountId=remote?.AccountId ?? ""};
            var scheduler=new BackupScheduler(store){CloudFactory=remote==null ? null : _=>remote};
            bool requested=false,earlyResume=false;BackupResult? completed=null;
            scheduler.Progress+=p=>
            {
                var fileStage=mode=="TwoWay" ? p.Stage=="원본 → 백업 검증 복사" : provider=="Local" ? p.Stage=="파일 비교 및 백업" : p.Stage=="파일 업로드 및 안전성 확인";
                if(!requested && p.CurrentFile=="a.txt" && fileStage)
                {
                    requested=true;scheduler.SetPaused(job,true);scheduler.StopJob(job);earlyResume=scheduler.ResumeJob(job);
                }
            };
            scheduler.Completed+=(_,result)=>completed=result;scheduler.SetJobs([job]);
            try
            {
                await scheduler.RunAsync(job,true).WaitAsync(TimeSpan.FromSeconds(20));
                check(requested && !earlyResume,"Stop not requested or running file restarted prematurely.");
                check(completed is {Canceled:true,Copied:1} && completed.Errors.Count==0,"Stop interrupted the active file or started the next file.");
                bool FirstComplete()=>remote==null ? File.ReadAllText(Path.Combine(backup,"a.txt"))=="first complete file" : System.Text.Encoding.UTF8.GetString(remote.Bytes("a.txt"))=="first complete file";
                bool SecondExists()=>remote==null ? File.Exists(Path.Combine(backup,"b.txt")) : remote.Files.ContainsKey("b.txt");
                check(FirstComplete() && !SecondExists(),"Active file was incomplete or pending file was copied after stop.");
                check(job.Stopped && !job.Paused && store.LoadState(job).PendingPaths.Contains("b.txt"),"Stop did not retain pending work in a non-paused waiting state.");
                await scheduler.RunAsync(job);check(!SecondExists(),"Stopped job restarted without explicit resume.");
                store.Save(new AppConfig {Jobs=[job]});var saved=new ConfigStore(store.Root).Load().Jobs.Single();check(saved.Stopped && !saved.Paused,"Non-paused waiting state was lost on restart/export.");
                job.Paused=true;store.Save(new AppConfig {Jobs=[job]});
                var upgraded=new ConfigStore(store.Root).Load().Jobs.Single();
                check(upgraded.Stopped && !upgraded.Paused,"preview.3 compatibility pause did not migrate to independent waiting state.");
                job.Paused=false;
            }
            finally{await scheduler.DisposeAsync();}
            var savedJob=new ConfigStore(store.Root).Load().Jobs.Single();int starts=0;
            await using var restart=new BackupScheduler(store){CloudFactory=remote==null ? null : _=>remote};
            restart.Started+=_=>Interlocked.Increment(ref starts);restart.SetJobs([savedJob]);restart.Start();
            await Task.Delay(2300);check(starts==0,"Stopped job auto-started after application restart.");
            check(restart.ResumeJob(savedJob),"Explicit resume failed after stopped run exited.");
            await restart.RunAsync(savedJob).WaitAsync(TimeSpan.FromSeconds(20));
            check(remote==null ? File.Exists(Path.Combine(backup,"b.txt")) : remote.Files.ContainsKey("b.txt"),"Pending work did not resume after stop.");
            check(!savedJob.Stopped && restart.RunningCount==0,"Resumed job did not return to normal scheduling.");
        }
        var scanHome=Path.Combine(root,"stop-scan");Directory.CreateDirectory(scanHome);var scanSource=Path.Combine(scanHome,"source");var scanBackup=Path.Combine(scanHome,"backup");
        Directory.CreateDirectory(scanSource);Directory.CreateDirectory(scanBackup);File.WriteAllText(Path.Combine(scanSource,"untouched.txt"),"do not copy");
        var scanGate=new PauseGate();var scanJob=new BackupJob {Source=scanSource,Destination=scanBackup};
        var scanResult=await new BackupEngine(new ConfigStore(Path.Combine(scanHome,"data"))).RunAsync(scanJob,true,null,scanGate,new Reporter(p=>{if(p.Stage=="원본 폴더 비교")scanGate.RequestStop();}),default);
        check(scanResult.Canceled && !Directory.EnumerateFileSystemEntries(scanBackup).Any(),"Stop during initial comparison changed backup files.");
    }
    private sealed class Reporter(Action<BackupProgress> report):IProgress<BackupProgress>{public void Report(BackupProgress value)=>report(value);}
}
