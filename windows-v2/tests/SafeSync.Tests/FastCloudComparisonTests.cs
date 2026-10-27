using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class FastCloudComparisonTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        {
            var home=Path.Combine(root,"fast-cloud",provider);var source=Path.Combine(home,"source");Directory.CreateDirectory(source);
            var file=Path.Combine(source,"file.txt");File.WriteAllText(file,"initial content");
            var remote=new MemoryRemote(provider);var store=new ConfigStore(Path.Combine(home,"state"));
            var job=new BackupJob{Source=source,Destination=provider,DestinationType=provider,CloudAccountId=remote.AccountId,CloudFolderId=remote.Root,MirrorDeletes=true};
            var stages=new List<string>();
            async Task<BackupResult> Run(bool full=false,string[]? changes=null)
            {
                stages.Clear();
                var engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=_=>remote};
                return await engine.RunAsync(job,full,changes,new(),new Reporter(p=>stages.Add(p.Stage)),default,reconcileOffline:true);
            }
            check((await Run(true)).Copied==1,provider+" fast baseline upload");
            check(store.LoadState(job).Files.Single().VerifiedRemote!=null,provider+" durable verified fingerprint");
            var repeat=await Run();
            check(repeat.Skipped==1 && repeat.Copied==0 && stages.Contains("저장된 검증 기록으로 빠른 비교") && !stages.Contains("클라우드 파일 내용 동일 여부 검증"),provider+" restart reuses verified content without hashing");
            if(provider=="GoogleDrive")
            {
                var verified=remote.Files["file.txt"];
                remote.Files["file.txt"]=verified with{Revision="metadata-only"};
                check((await Run()).Skipped==1 && stages.Contains("저장된 검증 기록으로 빠른 비교"),"Drive metadata-only revision triggered content hashing.");
                check(!RemotePath.VerifiedSame(verified,verified with{Hash="different"}),"Different content hash reused verification.");
                check(!RemotePath.VerifiedSame(verified,verified with{Name="renamed.txt"}),"A renamed item reused old path verification.");
            }
            await Run(true);
            check(stages.Contains("클라우드 파일 내용 동일 여부 검증") && !stages.Contains("저장된 검증 기록으로 빠른 비교"),provider+" explicit full inspection still hashes");
            await Run(changes:["file.txt"]);
            check(stages.Contains("클라우드 파일 내용 동일 여부 검증"),provider+" watcher event must hash even unchanged metadata");
            var saved=store.LoadState(job);saved.Files.Single().VerifiedRemote=null;store.SaveState(saved);
            await Run();check(stages.Contains("클라우드 파일 내용 동일 여부 검증"),provider+" legacy success is not unchecked cache authority");
            saved=store.LoadState(job);saved.PendingPaths.Add("file.txt");store.SaveState(saved);
            await Run();check(stages.Contains("클라우드 파일 내용 동일 여부 검증"),provider+" unfinished checkpoint is reverified");
            var originalTime=File.GetLastWriteTimeUtc(file);
            File.WriteAllText(file,"changed content");File.SetLastWriteTimeUtc(file,originalTime);
            check((await Run()).Skipped==1 && stages.Contains("저장된 검증 기록으로 빠른 비교"),provider+" documented metadata-only offline limitation");
            check((await Run(true)).Conflicts.Count==1,provider+" deep inspection detects same-size same-time offline edits");
            File.WriteAllText(file,"initial content");File.SetLastWriteTimeUtc(file,originalTime);await Run(true);
            await remote.SeedAsync("file.txt","different bytes",DateTime.UtcNow.AddMinutes(5));
            var changed=await Run();check(changed.Conflicts.Count==1 && !stages.Contains("저장된 검증 기록으로 빠른 비교"),provider+" remote replacement invalidates cache");
        }
    }
    private sealed class Reporter(Action<BackupProgress> report):IProgress<BackupProgress>{public void Report(BackupProgress value)=>report(value);}
}
