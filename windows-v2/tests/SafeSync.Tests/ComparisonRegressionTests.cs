using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class ComparisonRegressionTests
{
    public static async Task NasAsync(string localRoot,string nasRoot)
    {
        if(!Directory.Exists(nasRoot))throw new DirectoryNotFoundException(nasRoot);
        var source=Path.Combine(localRoot,"nas-compare-source");Directory.CreateDirectory(source);
        var backup=Path.Combine(Path.GetFullPath(nasRoot),"SafeSync-comparison-validation-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(backup);
        var a=Path.Combine(source,"same.txt");var b=Path.Combine(backup,"same.txt");File.WriteAllText(a,"NAS content equality");
        File.SetCreationTimeUtc(a,DateTime.UtcNow.AddYears(-3));File.SetLastWriteTimeUtc(a,DateTime.UtcNow.AddDays(-2));
        File.Copy(a,b);File.SetLastWriteTimeUtc(b,File.GetLastWriteTimeUtc(a));
        var createdDelta=(File.GetCreationTimeUtc(a)-File.GetCreationTimeUtc(b)).TotalSeconds;
        var store=new ConfigStore(Path.Combine(localRoot,"nas-compare-data"));var job=new BackupJob {Source=source,Destination=backup};var engine=new BackupEngine(store);
        var before=await VerifiedFiles.HashAsync(b,default);var same=await engine.RunAsync(job,true,null,new(),null,default);
        if(same.Skipped!=1 || same.Copied!=0 || same.Conflicts.Count!=0 || same.Errors.Count!=0)throw new Exception("NAS timestamp metadata still creates conflicts.");
        File.SetLastWriteTimeUtc(b,DateTime.UtcNow);var time=File.GetLastWriteTimeUtc(b);
        var checksum=await engine.RunAsync(job,true,null,new(),null,default);
        if(checksum.Skipped!=1 || checksum.Copied!=0 || checksum.Conflicts.Count!=0 || checksum.Errors.Count!=0 || File.GetLastWriteTimeUtc(b)!=time || await VerifiedFiles.HashAsync(b,default)!=before)throw new Exception("NAS checksum equality did not preserve the existing file.");
        JsonFile.Save(Path.Combine(localRoot,"nas-comparison-result.json"),new{Status="OK",Backup=backup,CreationDeltaSeconds=createdDelta,MetadataSkip=true,ChecksumSkip=true,ExistingBackupsTouched=false});
        Console.WriteLine("PASS: NAS metadata and checksum equality. "+localRoot);
    }
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        var home=Path.Combine(root,"comparison-regression");var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");
        Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
        var store=new ConfigStore(Path.Combine(home,"data"));var job=new BackupJob {Source=source,Destination=backup};var engine=new BackupEngine(store);
        string left=Path.Combine(source,"same.txt"),right=Path.Combine(backup,"same.txt");
        File.WriteAllText(left,"same bytes");File.WriteAllText(right,"same bytes");
        var modified=DateTime.UtcNow.AddDays(-2);File.SetLastWriteTimeUtc(left,modified);File.SetLastWriteTimeUtc(right,modified.AddMilliseconds(200));
        File.SetCreationTimeUtc(left,modified);File.SetCreationTimeUtc(right,modified.AddYears(-3));var originalId=OfflineJournal.FileIdentity(right);
        var ledger=new NoticeLedger(store.Root);ledger.Apply(job.Id,new BackupResult {Conflicts={new(job.Id,job.Name,"same.txt","old creation time conflict",10,10,"","")}});
        var same=await engine.RunAsync(job,true,null,new(),null,default);
        check(same.Skipped==1 && same.Copied==0 && same.Conflicts.Count==0,"NAS creation time difference generated a conflict.");
        check(OfflineJournal.FileIdentity(right)==originalId && File.GetCreationTimeUtc(right)==modified.AddYears(-3),"Identical file was rewritten to normalize creation time.");
        ledger.Apply(job.Id,same);check(ledger.Entries.Count==0,"Resolved timestamp conflict remained in notification list.");
        check(store.LoadState(job).Files.Single().Status=="BackedUp" && store.LoadState(job).PendingPaths.Count==0,"Identical file stayed pending/conflicted.");
        File.SetLastWriteTimeUtc(right,modified.AddHours(4));var backupTime=File.GetLastWriteTimeUtc(right);
        var sameBytes=await engine.RunAsync(job,true,null,new(),null,default);
        check(sameBytes.Skipped==1 && sameBytes.Conflicts.Count==0 && sameBytes.Copied==0,"Equal bytes with newer target timestamp became a conflict.");
        check(File.GetLastWriteTimeUtc(right)==backupTime && OfflineJournal.FileIdentity(right)==originalId,"Checksum-equal target was modified.");
        File.WriteAllText(right,"other data");File.SetLastWriteTimeUtc(right,backupTime);
        File.WriteAllText(Path.Combine(source,"unrelated.txt"),"must copy");
        var different=await engine.RunAsync(job,true,null,new(),null,default);
        check(different.Conflicts.Count==1 && different.Copied==1 && File.ReadAllText(right)=="other data","Same-size different content was overwritten or stopped unrelated backup.");
        using(var locked=new FileStream(right,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
        {
            var waiting=await engine.RunAsync(job,false,["same.txt"],new(),null,default);
            check(waiting.Locked.Count==1 && waiting.Errors.Count==0 && waiting.Conflicts.Count==0,"Locked checksum comparison became an error or conflict.");
        }
        foreach(var provider in new[]{"GoogleDrive","Dropbox"})
        {
            var remote=new MemoryRemote(provider);var cloudSource=Path.Combine(home,provider);Directory.CreateDirectory(cloudSource);
            var path=Path.Combine(cloudSource,"equal.txt");File.WriteAllText(path,"identical");File.SetLastWriteTimeUtc(path,modified);
            await remote.SeedAsync("equal.txt","identical",modified.AddHours(6));var remoteId=remote.Files["equal.txt"].Id;
            var cloudJob=new BackupJob {Source=cloudSource,DestinationType=provider,Destination=provider,CloudFolderId=remote.Root,CloudAccountId=remote.AccountId};
            var cloudStore=new ConfigStore(Path.Combine(home,provider+"-data"));var cloudEngine=new BackupEngine(cloudStore){CloudFactory=_=>remote};
            var equal=await cloudEngine.RunAsync(cloudJob,true,null,new(),null,default);
            check(equal.Skipped==1 && equal.Copied==0 && equal.Conflicts.Count==0,provider+" equal bytes with newer timestamp became a conflict.");
            check(remote.Files["equal.txt"].Id==remoteId && !remote.Files.Keys.Any(k=>k.StartsWith(".safesync-")),provider+" equal bytes were staged or replaced.");
            await remote.SeedAsync("equal.txt","different",modified.AddHours(6));
            var conflict=await cloudEngine.RunAsync(cloudJob,true,null,new(),null,default);
            check(conflict.Conflicts.Count==1 && conflict.Copied==0,provider+" same-size different bytes did not remain a conflict.");
        }
    }
}
