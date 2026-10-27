using System.Security.Cryptography;
using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class RecoveryProtectionTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var mode in new[]{"OneWay","TwoWay"})
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            var home=Path.Combine(root,"recovery",mode+provider);var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            var store=new ConfigStore(Path.Combine(home,"state"));var remote=new MemoryRemote(provider);
            var job=new BackupJob{Name="보호 검사",Source=source,Destination=backup,DestinationType=provider,SyncMode=mode,CloudAccountId=remote.AccountId,CloudFolderId=remote.Root,MirrorDeletes=true,MassChangeMinimum=4,MassChangePercent=30};
            var engine=new BackupEngine(store){CloudFactory=_=>remote};
            async Task<BackupResult> Run()=>await engine.RunAsync(job,true,[],new(),null,default);
            for(int i=0;i<12;i++){File.WriteAllText(Path.Combine(source,$"item-{i}.txt"),"old "+i);File.SetLastWriteTimeUtc(Path.Combine(source,$"item-{i}.txt"),DateTime.UtcNow.AddHours(-2));}
            check((await Run()).Copied==12,"First backup was mass-blocked: "+mode+provider);
            for(int i=0;i<5;i++){File.WriteAllText(Path.Combine(source,$"item-{i}.txt"),"new "+i);File.SetLastWriteTimeUtc(Path.Combine(source,$"item-{i}.txt"),DateTime.UtcNow.AddMinutes(5));}
            bool blocked=false;try{await Run();}catch(MassChangeException){blocked=true;}
            check(blocked,"Mass changes did not block: "+mode+provider);
            for(int i=0;i<5;i++)check(provider=="Local" ? File.ReadAllText(Path.Combine(backup,$"item-{i}.txt"))=="old "+i : Encoding.UTF8.GetString(remote.Bytes($"item-{i}.txt"))=="old "+i,"Mass guard already mutated a destination.");
            var proposal=MassChanges.Pending(new ConfigStore(store.Root),job)!;check(proposal.Changes.Length==5,"Restart lost exact proposal.");
            MassChanges.Approve(store,job,proposal.Fingerprint);File.SetLastWriteTimeUtc(Path.Combine(source,"item-0.txt"),DateTime.UtcNow.AddMinutes(10));
            blocked=false;try{await Run();}catch(MassChangeException){blocked=true;}
            check(blocked,"Stale mass approval was reused.");
            proposal=MassChanges.Pending(store,job)!;MassChanges.Approve(store,job,proposal.Fingerprint);
            var result=await Run();check(result.Errors.Count==0 && result.Conflicts.Count==0 && result.Copied==5,"Approved mass run failed: "+mode+provider);
            check(MassChanges.Pending(store,job)==null,"Approval was not consumed.");
            var verified=new List<RestoreCheckRow>();await foreach(var row in new RestoreChecks(store).CheckAsync(job,provider=="Local" ? null : remote,default))verified.Add(row);
            check(verified.Count==12 && verified.All(r=>r.Status=="정상"),"Successful backups failed isolated restore verification: "+mode+provider+" / "+string.Join(";",verified.Where(r=>r.Status!="정상").Select(r=>r.Path+":"+r.Detail)));
            if(provider=="Local")
            {
                var trash=new TrashService();var items=trash.List(backup,default).ToArray();
                check(items.Length==5 && items.Select(i=>i.BatchId).Distinct().Count()==1,"Archives were not grouped by execution.");
                foreach(var item in items)check(await ArchiveIntegrity.VerifyLocalAsync(backup,item,default),"Archived checksum missing.");
                var corrupt=items[0];var bytes=File.ReadAllBytes(corrupt.StoragePath);bytes[0]^=1;File.WriteAllBytes(corrupt.StoragePath,bytes);var targetBefore=File.ReadAllBytes(corrupt.OriginalPath);
                bool rejected=false;try{await trash.RestoreAsync(backup,corrupt,default);}catch(IOException){rejected=true;}
                check(rejected && targetBefore.SequenceEqual(File.ReadAllBytes(corrupt.OriginalPath)) && File.Exists(corrupt.StoragePath),"Corrupt archive overwrote live data.");
                var good=items[1];await trash.RestoreAsync(backup,good,default);check(File.ReadAllText(good.OriginalPath).StartsWith("old ") && !File.Exists(good.StoragePath),"Verified restore failed.");
                var legacy=TrashService.NewPath(backup,"legacy.txt","legacy");Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);File.WriteAllText(legacy,"legacy");
                var row=trash.List(backup,default).Single(i=>i.RelativePath=="legacy.txt");check(!await ArchiveIntegrity.VerifyLocalAsync(backup,row,default),"Legacy archive claimed original checksum proof.");
                await trash.RestoreAsync(backup,row,default);check(File.ReadAllText(row.OriginalPath)=="legacy","Legacy verified-copy restore was removed.");
            }
            else
            {
                var trash=new CloudTrash(remote,new(store,job,remote),store);var items=new List<CloudTrashItem>();await foreach(var item in trash.ListAsync(default))items.Add(item);
                check(items.Count==5 && items.Select(i=>i.BatchId).Distinct().Count()==1,"Cloud archives were not grouped.");
                check(await ArchiveIntegrity.VerifyRemoteAsync(store,remote,items[0],default),"Cloud archive proof missing.");
                var old=remote.Files[items[0].StoragePath];remote.Files[items[0].StoragePath]=old with{Hash="changed"};
                bool rejected=false;try{await trash.OperateAsync(items[0],true,default);}catch(IOException){rejected=true;}
                check(rejected && Encoding.UTF8.GetString(remote.Bytes(items[0].RelativePath)).StartsWith("new "),"Corrupt cloud archive restored.");
            }
        }
        await CurrentVerificationAsync(root,check);await DeletionAsync(root,check);await VssAsync(root,check);
    }
    private static async Task CurrentVerificationAsync(string root,Action<bool,string> check)
    {
        var home=Path.Combine(root,"current-verification");var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
        File.WriteAllText(Path.Combine(source,"a.txt"),"good data");var store=new ConfigStore(Path.Combine(home,"state"));var job=new BackupJob{Name="복원 검증",Source=source,Destination=backup};var engine=new BackupEngine(store);
        await engine.RunAsync(job,true,[],new(),null,default);File.WriteAllText(Path.Combine(backup,"a.txt"),"bad! data");Directory.Delete(source,true);
        var results=new List<RestoreCheckRow>();await foreach(var row in new RestoreChecks(store).CheckAsync(job,null,default))results.Add(row);
        check(results.Count==1 && results[0].Status=="실패" && File.ReadAllText(Path.Combine(backup,"a.txt"))=="bad! data","Restore verification failed to detect corruption without its source.");
        using var cancel=new CancellationTokenSource();cancel.Cancel();bool cancelled=false;try{await foreach(var row in new RestoreChecks(store).CheckAsync(job,null,cancel.Token)){} }catch(OperationCanceledException){cancelled=true;}
        check(cancelled,"Restore verification ignored cancellation.");
    }
    private static async Task DeletionAsync(string root,Action<bool,string> check)
    {
        var source=Path.Combine(root,"mass-delete-source");var backup=Path.Combine(root,"mass-delete-backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);var store=new ConfigStore(Path.Combine(root,"mass-delete-state"));
        var job=new BackupJob{Name="삭제 보호",Source=source,Destination=backup,MirrorDeletes=true,MassChangeMinimum=3,MassChangePercent=30};var engine=new BackupEngine(store);
        for(int i=0;i<8;i++)File.WriteAllText(Path.Combine(source,$"{i}.txt"),"keep "+i);
        await engine.RunAsync(job,true,[],new(),null,default);for(int i=0;i<4;i++)File.Delete(Path.Combine(source,$"{i}.txt"));
        bool blocked=false;try{await engine.RunAsync(job,true,[],new(),null,default);}catch(MassChangeException){blocked=true;}
        check(blocked && Directory.GetFiles(backup,"*.txt").Length==8,"Mass deletion was already applied.");
        var proposal=MassChanges.Pending(store,job)!;MassChanges.Approve(store,job,proposal.Fingerprint);var result=await engine.RunAsync(job,true,[],new(),null,default);
        check(result.Trashed==4,"Approved deletion did not archive all tracked files.");
        check(new TrashService().List(backup,default).Select(i=>i.BatchId).Distinct().Count()==1,"Deleted files lost run grouping.");
    }
    private sealed class Snapshot(string source,string shadow):ISourceSnapshot
    {
        public bool Disposed;
        public string ReadPath(string original)=>Path.Combine(shadow,Path.GetRelativePath(source,original));
        public ValueTask DisposeAsync(){Disposed=true;return ValueTask.CompletedTask;}
    }
    private static async Task VssAsync(string root,Action<bool,string> check)
    {
        var source=Path.Combine(root,"vss-source");var backup=Path.Combine(root,"vss-backup");var shadow=Path.Combine(root,"vss-shadow");foreach(var p in new[]{source,backup,shadow})Directory.CreateDirectory(p);
        var file=Path.Combine(source,"locked.txt");File.WriteAllText(file,"snapshot bytes");File.Copy(file,Path.Combine(shadow,"locked.txt"));var snapshot=new Snapshot(source,shadow);int created=0;
        var store=new ConfigStore(Path.Combine(root,"vss-state"));var job=new BackupJob{Name="VSS 검사",Source=source,Destination=backup,UseVss=true};
        var engine=new BackupEngine(store){VssFactory=(_,_)=>{created++;return Task.FromResult<ISourceSnapshot>(snapshot);}};
        using(var locked=new FileStream(file,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
        {
            var result=await engine.RunAsync(job,true,[],new(),null,default);
            check(result.Copied==1 && result.Errors.Count==0 && result.Locked.Count==0 && File.ReadAllText(Path.Combine(backup,"locked.txt"))=="snapshot bytes","VSS fallback did not copy the locked file.");
            check(created==1 && snapshot.Disposed,"VSS snapshot leaked after run.");
            job.UseVss=false;result=await engine.RunAsync(job,true,[],new(),null,default);check(result.Locked.Count==1 && result.Errors.Count==0,"Disabled VSS no longer queues locked files quietly.");
            job.UseVss=true;engine.VssFactory=(_,_)=>throw new UnauthorizedAccessException("administrator required");result=await engine.RunAsync(job,true,[],new(),null,default);
            check(result.Locked.Count==1 && result.Errors.Count==0,"VSS unavailability became a file error popup.");
        }
    }
    public static async Task RealVssAsync(string root,string helper,Action<bool,string> check)
    {
        Directory.CreateDirectory(root);var file=Path.Combine(root,"vss-exclusive.txt");File.WriteAllText(file,"isolated VSS data");
        var job=new BackupJob{Name="실제 VSS 격리 검사",Source=root,Destination=Path.Combine(root,"not-used"),UseVss=true};string mapped;
        using(var locked=new FileStream(file,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
        {
            var snapshot=await VssSnapshot.CreateAsync(job,helper,default);mapped=snapshot.ReadPath(file);
            try{check(File.ReadAllText(mapped)=="isolated VSS data","Native VSS did not read an exclusive-locked file.");}
            finally{await snapshot.DisposeAsync();}
        }
        for(int i=0;i<30 && File.Exists(mapped);i++)await Task.Delay(100);
        check(!File.Exists(mapped) && File.ReadAllText(file)=="isolated VSS data","Native VSS leaked its snapshot or altered source.");
    }
}
