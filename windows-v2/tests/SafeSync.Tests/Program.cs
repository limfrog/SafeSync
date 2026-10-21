using System.Security.Cryptography;
using System.Text;
using SafeSync.Core;

if(args.Length==2 && args[0]=="--copy-worker"){await StressTests.CopyWorkerAsync(args[1]);return;}
var testRoot=Path.GetFullPath(Path.Combine(args.Length>0 ? args[0] : Path.GetTempPath(),"safesync-v2-"+Guid.NewGuid().ToString("N")));
Directory.CreateDirectory(testRoot);
int passed=0;
void Check(bool condition,string message) {if(!condition)throw new Exception(message);passed++;}
void Reject(Action action,string message)
{
    try {action();}catch(Exception ex) when(ex is InvalidDataException or ArgumentException or IOException){passed++;return;}
    throw new Exception(message);
}
string Folder(string name) {var path=Path.Combine(testRoot,name);Directory.CreateDirectory(path);return path;}
string source=Folder("source"),destination=Folder("backup");
var store=new ConfigStore(Folder("data"));
var job=new BackupJob {Name="검증 작업",Source=source,Destination=destination,MirrorDeletes=true};
var engine=new BackupEngine(store);var publisher=new VerifiedFiles();var trash=new TrashService();
var token=CancellationToken.None;
async Task<BackupResult> Run(bool full=true, IEnumerable<string>? paths=null,IReadOnlyDictionary<string,ConflictAction>? actions=null,PauseGate? gate=null,CancellationToken ct=default)
    => await engine.RunAsync(job,full,paths,gate??new(),null,ct,actions);
string Write(string root,string relative,string text,int age=0)
{
    var path=Path.Combine(root,relative);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,text,Encoding.UTF8);
    if(age>0)File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddMinutes(-age));return path;
}
try
{
    if(args.Contains("--updates"))
    {
        await AppUpdateTests.RunAsync(testRoot,Check);
        JsonFile.Save(Path.Combine(testRoot,"result.json"),new {Status="OK",Assertions=passed,TestRoot=testRoot});
        Console.WriteLine($"PASS: {passed} update assertions. {testRoot}");return;
    }
    var identityIndex=Array.IndexOf(args,"--root-identity");
    if(identityIndex>=0)
    {
        for(int sample=0;sample<3;sample++)Console.WriteLine(OfflineJournal.RootIdentity(args[identityIndex+1]));return;
    }
    var googleProbeIndex=Array.IndexOf(args,"--google-probe");
    var duplicateInspectionIndex=Array.IndexOf(args,"--inspect-google-duplicates");
    if(duplicateInspectionIndex>=0){await LiveGoogleTests.InspectDuplicatesAsync(testRoot,args[duplicateInspectionIndex+1],args[duplicateInspectionIndex+2]);return;}
    var connectDropboxIndex=Array.IndexOf(args,"--connect-dropbox");
    if(connectDropboxIndex>=0){await LiveDropboxTests.ConnectAsync(args[connectDropboxIndex+1]);return;}
    var liveDropboxIndex=Array.IndexOf(args,"--live-dropbox");
    if(liveDropboxIndex>=0){await LiveDropboxTests.RunAsync(testRoot,args[liveDropboxIndex+1]);return;}
    var brandingIndex=Array.IndexOf(args,"--dropbox-branding");
    if(brandingIndex>=0){await LiveDropboxTests.BrandingAsync(testRoot,args[brandingIndex+1],args[brandingIndex+2]);return;}
    var twoWayGoogleIndex=Array.IndexOf(args,"--two-way-google");
    if(twoWayGoogleIndex>=0){await LiveGoogleTests.TwoWayAsync(testRoot,args[twoWayGoogleIndex+1]);return;}
    var twoWayNasIndex=Array.IndexOf(args,"--two-way-nas");
    var compareNasIndex=Array.IndexOf(args,"--comparison-nas");
    if(compareNasIndex>=0){await ComparisonRegressionTests.NasAsync(testRoot,args[compareNasIndex+1]);return;}
    if(twoWayNasIndex>=0){await TwoWayTests.NasAsync(testRoot,args[twoWayNasIndex+1],Check);return;}
    if(googleProbeIndex>=0){await LiveGoogleTests.ProbeAsync(testRoot,args[googleProbeIndex+1]);return;}
    var liveGoogleIndex=Array.IndexOf(args,"--live-google");
    if(liveGoogleIndex>=0){await LiveGoogleTests.RunAsync(testRoot,args[liveGoogleIndex+1]);return;}
    var recheckGoogleIndex=Array.IndexOf(args,"--google-recheck");
    if(recheckGoogleIndex>=0){await LiveGoogleTests.RecheckAsync(testRoot,args[recheckGoogleIndex+1],args[recheckGoogleIndex+2]);return;}
    var stressIndex=Array.IndexOf(args,"--stress");
    if(stressIndex>=0)
    {
        await StressTests.RunAsync(testRoot,Check,TimeSpan.FromSeconds(int.Parse(args[stressIndex+1])));
        JsonFile.Save(Path.Combine(testRoot,"result.json"),new{Status="OK",Assertions=passed,TestRoot=testRoot});
        Console.WriteLine($"PASS: {passed} stress assertions. {testRoot}");return;
    }
    foreach(var relative in new[]{"../outside.txt","folder/../../outside.txt","/absolute.txt","C:\\outside.txt","file.txt:stream","a//b","a/./b","a./b","a /b","..\\outside.txt"})
        Reject(()=>PathPolicy.Combine(destination,relative),"Unsafe path accepted: "+relative);
    foreach(var id in new[]{"..","../job","job/a","a:b",""})Reject(()=>store.StatePath(id),"Unsafe ID accepted.");
    Reject(()=>PathPolicy.ValidateRoots(source,source),"Equal endpoints accepted.");
    Reject(()=>PathPolicy.ValidateRoots(source,Path.Combine(source,"nested")),"Nested destination accepted.");
    Check(PathPolicy.Relative("한글\\폴더/파일.txt")=="한글/폴더/파일.txt","Unicode/relative normalization failed.");
    var config=new AppConfig {Jobs=[job],ThemeMode="Dark",Extra=new() { ["CloudAccounts"]=System.Text.Json.JsonSerializer.SerializeToElement(new{GoogleDrive=new{RefreshTokenProtected="dpapi:test-only-not-a-real-token"}})}};
    store.Save(config);Check(store.Load().Jobs.Count==1,"Config roundtrip lost jobs.");
    Check(store.Load().Extra!["CloudAccounts"].GetRawText().Contains("dpapi:test-only"),"Unknown protected account fields were lost.");
    var legacy=Folder("legacy");JsonFile.Save(Path.Combine(legacy,"config.json"),new AppConfig {Jobs=[job],AutoStart=true});
    var before=SHA256.HashData(File.ReadAllBytes(Path.Combine(legacy,"config.json")));
    var migrated=new ConfigStore(Folder("migrated")).ImportLegacy(Path.Combine(legacy,"config.json"));
    Check(migrated.Jobs[0].Paused && !migrated.AutoStart,"Migrated jobs run without review.");
    Check(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(Path.Combine(legacy,"config.json")))),"Import modified legacy config.");
    var a=Write(source,"한글/파일.txt","original",5);
    Write(source,"other.txt","second",5);
    var first=await Run();Check(first.Copied==2 && first.Errors.Count==0,"Initial backup failed.");
    Check(await VerifiedFiles.HashAsync(a,token)==await VerifiedFiles.HashAsync(Path.Combine(destination,"한글/파일.txt"),token),"Backup differs from source.");
    Check(File.GetLastWriteTimeUtc(a)==File.GetLastWriteTimeUtc(Path.Combine(destination,"한글/파일.txt")),"Modified timestamp lost.");
    var second=await Run();Check(second.Skipped==2 && second.Copied==0,"Unchanged files copied again.");
    var state=store.LoadState(job);Check(state.Files.Count==2 && state.PendingPaths.Count==0,"Successful snapshot is incomplete.");
    Check(!state.FullScanRequired && !state.CheckpointActive,"Completed checkpoint remains active.");
    Write(source,"other.txt","newer content");
    var changed=await Run(false,["other.txt"]);Check(changed.Copied==1 && changed.Skipped==0,"Incremental backup scanned unrelated files.");
    Check(trash.List(destination,token).Any(t=>t.RelativePath=="other.txt"),"Replaced backup did not enter trash.");
    var backup=Path.Combine(destination,"한글/파일.txt");
    File.WriteAllText(backup,"different sized content");File.SetLastWriteTimeUtc(backup,File.GetLastWriteTimeUtc(a));File.SetCreationTimeUtc(backup,File.GetCreationTimeUtc(a));
    Write(source,"new.txt","must still copy");
    var conflict=await Run();Check(conflict.Conflicts.Count==1 && File.ReadAllText(Path.Combine(destination,"new.txt"))=="must still copy","Conflict stopped unrelated backup.");
    Check(File.ReadAllText(backup)=="different sized content","Conflict overwritten without consent.");
    Check(store.LoadState(job).Files.Any(f=>f.RelativePath=="한글/파일.txt" && f.Status=="Conflict"),"Conflict not persisted.");
    var keep=await Run(false,actions:new Dictionary<string,ConflictAction>{{"한글/파일.txt",ConflictAction.KeepBoth}});
    Check(keep.Copied==1 && File.ReadAllText(backup)=="original","Keep-both resolution failed.");
    Check(Directory.EnumerateFiles(Path.GetDirectoryName(backup)!,"*.SafeSync-conflict-*").Any(),"Keep-both lost original backup.");
    File.Delete(Path.Combine(source,"other.txt"));
    var deleted=await Run(false,["other.txt"]);Check(deleted.Trashed==1 && !File.Exists(Path.Combine(destination,"other.txt")),"Mirrored deletion bypassed trash.");
    var restore=trash.List(destination,token).First(t=>t.RelativePath=="other.txt" && File.ReadAllText(t.StoragePath)=="newer content");
    await trash.RestoreAsync(destination,restore,token);
    Check(File.ReadAllText(Path.Combine(destination,"other.txt"))=="newer content" && !File.Exists(restore.StoragePath),"Restore failed.");
    var forged=restore with{StoragePath=a};Reject(()=>trash.Delete(destination,forged),"Trash deleted a file outside trash.");
    var deleteItem=trash.List(destination,token).First();trash.Delete(destination,deleteItem);Check(!File.Exists(deleteItem.StoragePath),"Permanent deletion did not remove selected file.");
    Write(source,"locked.txt","locked source",5);
    using(var writer=new FileStream(Path.Combine(source,"locked.txt"),FileMode.Open,FileAccess.ReadWrite,FileShare.None))
    {
        var locked=await Run(false,["locked.txt"]);Check(locked.Locked.Count==1 && locked.Errors.Count==0,"Sharing violation became a general error.");
        Check(store.LoadState(job).PendingPaths.Contains("locked.txt"),"Locked file not marked for retry.");
    }
    var retry=await Run(false);Check(retry.Copied==1 && File.Exists(Path.Combine(destination,"locked.txt")),"Unlocked file was not retried.");
    var beforeCancel=File.ReadAllText(backup);
    using(var canceled=new CancellationTokenSource())
    {
        canceled.Cancel();bool didCancel=false;
        try{await publisher.CopyAsync(a,destination,"한글/파일.txt",canceled.Token);}catch(OperationCanceledException){didCancel=true;}
        Check(didCancel && File.ReadAllText(backup)==beforeCancel,"Canceled copy damaged previous backup.");
    }
    Check(!Directory.EnumerateFiles(destination,"*.safesync-part-*",SearchOption.AllDirectories).Any(),"Canceled pre-publication copy leaked temporary files.");
    var oldTarget=Write(destination,"recover.txt","previous");var staged=Write(destination,"recover.txt.safesync-part-test","replacement");
    var journal=Path.Combine(destination,".safesync-txn-v2-test.json");
    JsonFile.Save(journal,new VerifiedFiles.Transaction {Destination="recover.txt",Staged=Path.GetFileName(staged),ExpectedHash=await VerifiedFiles.HashAsync(staged,token),Length=new FileInfo(staged).Length,PreviousHash=await VerifiedFiles.HashAsync(oldTarget,token)});
    await publisher.RecoverAsync(destination,token);Check(File.ReadAllText(oldTarget)=="previous" && !File.Exists(journal) && !File.Exists(staged),"Pre-publish recovery damaged original.");
    staged=Write(destination,"recover.txt.safesync-part-test2","new good");
    var prior=TrashService.NewPath(destination,"recover.txt","replaced");Directory.CreateDirectory(Path.GetDirectoryName(prior)!);
    var record=new VerifiedFiles.Transaction {Destination="recover.txt",Staged=Path.GetFileName(staged),Previous=Path.GetRelativePath(destination,prior),ExpectedHash=await VerifiedFiles.HashAsync(staged,token),Length=new FileInfo(staged).Length,PreviousHash=await VerifiedFiles.HashAsync(oldTarget,token)};
    JsonFile.Save(journal,record);File.Replace(staged,oldTarget,prior);await publisher.RecoverAsync(destination,token);
    Check(File.ReadAllText(oldTarget)=="new good" && File.ReadAllText(prior)=="previous" && !File.Exists(journal),"Post-publish recovery failed.");
    staged=Write(destination,"recover.txt.safesync-part-test3","next");
    prior=TrashService.NewPath(destination,"recover.txt","replaced");Directory.CreateDirectory(Path.GetDirectoryName(prior)!);
    record=new() {Destination="recover.txt",Staged=Path.GetFileName(staged),Previous=Path.GetRelativePath(destination,prior),ExpectedHash=await VerifiedFiles.HashAsync(staged,token),Length=new FileInfo(staged).Length,PreviousHash=await VerifiedFiles.HashAsync(oldTarget,token)};
    JsonFile.Save(journal,record);File.Replace(staged,oldTarget,prior);File.WriteAllText(oldTarget,"corrupt transfer");await publisher.RecoverAsync(destination,token);
    Check(File.ReadAllText(oldTarget)=="new good" && !File.Exists(journal),"Corrupt published copy did not roll back.");
    var oldTrash=Path.Combine(destination,".safesync-trash",DateTime.Now.AddDays(-101).ToString("yyyyMMdd-HHmmssfff")+"-deleted","old.txt");Directory.CreateDirectory(Path.GetDirectoryName(oldTrash)!);File.WriteAllText(oldTrash,"old");
    var recent=TrashService.NewPath(destination,"recent.txt","deleted");Directory.CreateDirectory(Path.GetDirectoryName(recent)!);File.WriteAllText(recent,"recent");
    trash.RemoveExpired(destination,100,token);Check(!File.Exists(oldTrash) && File.Exists(recent),"100-day retention removed a recent file or kept expired content.");
    var pause=new PauseGate();pause.Pause();Write(source,"paused.txt","pause");
    var waiting=Run(false,["paused.txt"],gate:pause);await Task.Delay(150);
    Check(!waiting.IsCompleted && !File.Exists(Path.Combine(destination,"paused.txt")),"Pause did not suspend the job.");
    pause.Resume();var resumed=await waiting;Check(resumed.Copied>0 && File.Exists(Path.Combine(destination,"paused.txt")),"Resume did not continue the same job.");
    // Cancellation after at least one completion leaves the remaining work in a durable checkpoint.
    for(int i=0;i<8;i++)Write(source,$"resume/{i}.txt",new string('x',2000));
    var cancelGate=new PauseGate();using(var cancel=new CancellationTokenSource())
    {
        var reporter=new InlineProgress(p=>{if(p.Completed>=1)cancel.Cancel();});
        var interrupted=await engine.RunAsync(job,false,Enumerable.Range(0,8).Select(i=>$"resume/{i}.txt"),cancelGate,reporter,cancel.Token);
        Check(interrupted.Canceled && store.LoadState(job).PendingPaths.Count>0,"Interrupted run lost pending work.");
    }
    var continued=await Run(false);Check(continued.Copied>0 && store.LoadState(job).PendingPaths.Count==0,"Checkpoint did not resume pending files.");
    job.MirrorDeletes=false;File.Delete(Path.Combine(source,"new.txt"));await Run(false,["new.txt"]);
    Check(File.Exists(Path.Combine(destination,"new.txt")),"Non-mirror backup deleted a file.");
    var otherJob=new BackupJob {Id=job.Id,Name=job.Name,Source=source,Destination=Folder("another-backup")};
    Check(store.LoadState(otherJob).Files.Count==0,"Snapshot was reused for a different destination.");
    var missingJob=new BackupJob {Source=Path.Combine(testRoot,"missing"),Destination=destination};
    bool rejectedMissing=false;try{await engine.RunAsync(missingJob,true,null,new(),null,token);}catch(DirectoryNotFoundException){rejectedMissing=true;}
    Check(rejectedMissing && File.Exists(backup),"Unavailable source was treated as a deletion scan.");
    var unsupported=new BackupJob {Name="cloud",Source=source,DestinationType="GoogleDrive",Destination="Google Drive / Backup",CloudFolderId="test"};
    bool rejectedCloud=false;try{await engine.RunAsync(unsupported,true,null,new(),null,token);}catch(NotSupportedException){rejectedCloud=true;}
    Check(rejectedCloud,"Unported cloud feature silently pretended success.");
    var autoSource=Folder("automatic-source");var autoDestination=Folder("automatic-backup");
    var autoStore=new ConfigStore(Folder("automatic-data"));
    var autoJob=new BackupJob {Name="Automatic",Source=autoSource,Destination=autoDestination};
    Write(autoSource,"first.txt","initial");
    var automatic=new BackupScheduler(autoStore);
    var automaticHistory=new SyncSessionHistory();
    automatic.Started+=j=>automaticHistory.Begin(j);
    automatic.Progress+=p=>automaticHistory.Progress(autoJob,p);
    automatic.Completed+=(j,r)=>automaticHistory.Complete(j,r);
    Exception? autoError=null;automatic.Failed+=(_,ex)=>autoError=ex;
    automatic.SetJobs([autoJob]);automatic.Start();
    async Task WaitUntil(Func<bool> condition)
    {
        var limit=DateTime.UtcNow.AddSeconds(12);
        while(!condition() && DateTime.UtcNow<limit)
        {
            if(autoError!=null)throw autoError;
            await Task.Delay(100);
        }
        Check(condition(),"Automatic scheduler timed out.");
    }
    try
    {
        await WaitUntil(()=>File.Exists(Path.Combine(autoDestination,"first.txt")) && automatic.RunningCount==0);
        Check(File.ReadAllText(Path.Combine(autoDestination,"first.txt"))=="initial","Startup reconciliation did not back up.");
        automatic.SetPaused(autoJob,true);Write(autoSource,"later.txt","changed");
        await Task.Delay(3500);Check(!File.Exists(Path.Combine(autoDestination,"later.txt")),"Paused automatic job still ran.");
        automatic.SetPaused(autoJob,false);
        await WaitUntil(()=>File.Exists(Path.Combine(autoDestination,"later.txt")) && automatic.RunningCount==0);
        Check(File.Exists(Path.Combine(autoStore.Root,"pending-changes-v2.json")),"Watched changes were not persisted.");
    }
    finally{await automatic.DisposeAsync();}
    Check(automatic.RunningCount==0,"Scheduler left background work after exit.");
    Check(automaticHistory.Runs.Count>=2,"Automatic runs were not recorded while history window was closed.");
    Check(automaticHistory.Runs.Count(r=>r.Copied==1)>=2,"Automatic run results replaced an earlier completion.");
    Check(automaticHistory.Runs.Any(r=>r.EndedUtc!=null && r.Outcome==SyncRunOutcome.Completed),"Scheduler history did not finalize completed run.");
    SessionHistoryTests.Run(Check);
    await CloudTests.RunAsync(testRoot,Check);
    await TwoWayTests.RunAsync(testRoot,Check);
    await DropboxScopeTests.RunAsync(testRoot,Check);
    await ComparisonRegressionTests.RunAsync(testRoot,Check);
    await OneWaySafetyTests.RunAsync(testRoot,Check);
    await RestartIndexRegressionTests.RunAsync(testRoot,Check);
    await AppUpdateTests.RunAsync(testRoot,Check);
    await GracefulStopTests.RunAsync(testRoot,Check);
    await RecoveryRegressionTests.RunAsync(testRoot,Check);
    await FileComparisonTests.RunAsync(testRoot,Check);
    await DeferredResolutionTests.RunAsync(testRoot,Check);
    await NetworkRetryTests.RunAsync(testRoot,Check);
    await DuplicateResolutionTests.RunAsync(testRoot,Check);
    JobProblemTests.Run(testRoot,Check);
    await ParityTests.RunAsync(testRoot,Check);
    await ReleaseSafetyTests.RunAsync(testRoot,Check);
    var nasIndex=Array.IndexOf(args,"--nas");
    if(nasIndex>=0)await ReleaseSafetyTests.NasAsync(testRoot,args[nasIndex+1],Check);
    JsonFile.Save(Path.Combine(testRoot,"result.json"),new {Status="OK",Assertions=passed,TestRoot=testRoot});
    Console.WriteLine($"PASS: {passed} native C# backup, migration and safety assertions. {testRoot}");
}
catch(Exception ex)
{
    Console.Error.WriteLine(ex);Console.Error.WriteLine("Fixtures preserved: "+testRoot);Environment.ExitCode=1;
}

sealed class InlineProgress(Action<BackupProgress> report) : IProgress<BackupProgress>
{
    public void Report(BackupProgress value) => report(value);
}
