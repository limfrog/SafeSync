using System.Diagnostics;
using System.Security.Cryptography;
using SafeSync.Core;

internal static class StressTests
{
    public static async Task CopyWorkerAsync(string home)
    {
        if(!File.Exists(Path.Combine(home,"CRASH-TEST-ONLY")))throw new IOException("Not a crash fixture.");
        await new VerifiedFiles().CopyAsync(Path.Combine(home,"source.bin"),Path.Combine(home,"backup"),"target.bin",default,
            new Reporter(p=>{if(p.Done>=1024*1024){File.WriteAllText(Path.Combine(home,"ready"),"copying");Thread.Sleep(Timeout.Infinite);}}));
    }
    private sealed class Reporter(Action<(long Done,long Total)> report) : IProgress<(long Done,long Total)>
    {public void Report((long Done,long Total) value)=>report(value);}

    public static async Task RunAsync(string root,Action<bool,string> check,TimeSpan duration)
    {
        if(duration<TimeSpan.FromSeconds(10)||duration>TimeSpan.FromMinutes(10))throw new ArgumentOutOfRangeException(nameof(duration));
        var crash=Path.Combine(root,"crash-fixture");Directory.CreateDirectory(Path.Combine(crash,"backup"));File.WriteAllText(Path.Combine(crash,"CRASH-TEST-ONLY"),"test");
        File.WriteAllBytes(Path.Combine(crash,"source.bin"),RandomNumberGenerator.GetBytes(16*1024*1024));
        var target=Path.Combine(crash,"backup","target.bin");File.WriteAllText(target,"previous valid backup");
        var runtime=Directory.GetParent(typeof(object).Assembly.Location)!.Parent!.Parent!.Parent!.FullName;
        var start=new ProcessStartInfo(Path.Combine(runtime,"dotnet.exe")){UseShellExecute=false,CreateNoWindow=true};
        start.ArgumentList.Add(typeof(StressTests).Assembly.Location);start.ArgumentList.Add("--copy-worker");start.ArgumentList.Add(crash);
        using(var child=Process.Start(start)!)
        {
            var limit=Stopwatch.StartNew();while(!File.Exists(Path.Combine(crash,"ready"))&&!child.HasExited&&limit.Elapsed<TimeSpan.FromSeconds(15))await Task.Delay(20);
            if(!File.Exists(Path.Combine(crash,"ready"))){if(!child.HasExited)child.Kill(true);throw new Exception("Copy crash worker did not reach transfer.");}
            child.Kill(true);await child.WaitForExitAsync();check(child.HasExited,"Crash worker remains running");
        }
        await new VerifiedFiles().RecoverAsync(Path.Combine(crash,"backup"),default);
        check(File.ReadAllText(target)=="previous valid backup","Killed transfer damaged previous backup");
        await new VerifiedFiles().CopyAsync(Path.Combine(crash,"source.bin"),Path.Combine(crash,"backup"),"target.bin",default);
        check(await VerifiedFiles.HashAsync(target,default)==await VerifiedFiles.HashAsync(Path.Combine(crash,"source.bin"),default),"Killed copy could not restart safely");

        var source=Path.Combine(root,"stress-source");var backup=Path.Combine(root,"stress-backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
        var job=new BackupJob {Source=source,Destination=backup,MirrorDeletes=true};var data=Path.Combine(root,"stress-state");
        for(int i=0;i<500;i++)File.WriteAllText(Path.Combine(source,$"한글-{i:D4}.txt"),"initial-"+i);
        var store=new ConfigStore(data);var engine=new BackupEngine(store);var initial=await engine.RunAsync(job,true,null,new(),null,default);
        check(initial.Copied==500 && initial.Errors.Count==0,"Stress baseline incomplete");
        int iteration=0;long firstMemory=Process.GetCurrentProcess().WorkingSet64,peakMemory=firstMemory;
        var watch=Stopwatch.StartNew();
        while(watch.Elapsed<duration)
        {
            string relative=$"한글-{iteration%500:D4}.txt",path=Path.Combine(source,relative),expected="revision-"+iteration;
            File.WriteAllText(path,expected);File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddMinutes(2));
            if(iteration%7==0){store=new ConfigStore(data);engine=new BackupEngine(store);}
            var pause=new PauseGate();
            if(iteration%11==0)
            {
                pause.Pause();var pending=engine.RunAsync(job,false,[relative],pause,null,default);await Task.Delay(25);
                check(!pending.IsCompleted,"Stress pause did not suspend current job");pause.Resume();await pending;
            }
            else await engine.RunAsync(job,false,[relative],pause,null,default);
            check(File.ReadAllText(Path.Combine(backup,relative))==expected,"Stress restart/pause lost changed file");
            check(new ConfigStore(data).LoadState(job).PendingPaths.Count==0,"Stress successful file stayed pending");
            if(iteration%13==0)
            {
                string transient="temporary.txt";File.WriteAllText(Path.Combine(source,transient),expected);
                await engine.RunAsync(job,false,[transient],new(),null,default);File.Delete(Path.Combine(source,transient));
                var deleted=await engine.RunAsync(job,false,[transient],new(),null,default);check(deleted.Trashed==1,"Stress deletion bypassed trash");
            }
            peakMemory=Math.Max(peakMemory,Process.GetCurrentProcess().WorkingSet64);iteration++;await Task.Delay(60);
        }
        int hashes=0;foreach(var file in Directory.EnumerateFiles(source))
        {
            check(await VerifiedFiles.HashAsync(file,default)==await VerifiedFiles.HashAsync(Path.Combine(backup,Path.GetFileName(file)),default),"Stress final content mismatch");hashes++;
        }
        JsonFile.Save(Path.Combine(root,"stress-result.json"),new{Status="OK",Seconds=watch.Elapsed.TotalSeconds,Iterations=iteration,VerifiedFiles=hashes,FirstWorkingSetBytes=firstMemory,PeakWorkingSetBytes=peakMemory,FinalWorkingSetBytes=Process.GetCurrentProcess().WorkingSet64,RealCopyProcessKilled=true,MultiDaySoak=false});
        Console.WriteLine($"Stress: {iteration} cycles, {hashes} final hashes, {watch.Elapsed.TotalSeconds:N1}s; fixtures preserved: {root}");
    }
}
