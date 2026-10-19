using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeSync.Core;
using SafeSync.Core.Cloud;

// Explicit opt-in only. Never run against a user's existing backup root.
// Credentials are read in memory and never copied into the test fixture/report.
internal static class LiveGoogleTests
{
    public static async Task RecheckAsync(string output,string configPath,string fixture)
    {
        var report=JsonFile.Read<JsonElement>(Path.Combine(fixture,"google-live-result.json"));
        if(report.String("Status")!="OK")throw new InvalidOperationException("Only a previously successful live-test fixture may be rechecked.");
        string id=report.String("TestFolderId"),label=report.String("TestFolderName");
        var config=GoogleOnly(configPath);var before=SHA256.HashData(File.ReadAllBytes(configPath));
        var store=new ConfigStore(Path.Combine(fixture,"google-live-state"));
        var saved=JsonFile.Read<JobState>(Directory.EnumerateFiles(Path.Combine(store.Root,"manifests"),"*.sync.json").Single());
        if(saved.Source!=Path.Combine(fixture,"google-live-source") || saved.DestinationType!="GoogleDrive" || saved.CloudFolderId!=id || saved.CloudAccountId!=CloudAccounts.Read(config).GoogleDrive.AccountId)
            throw new InvalidOperationException("Live-test snapshot identity mismatch.");
        var job=new BackupJob{Id=saved.JobId,Source=saved.Source,Destination=saved.Destination,DestinationType=saved.DestinationType,CloudFolderId=id,CloudAccountId=saved.CloudAccountId,MirrorDeletes=true};
        var runs=new List<object>();int passed=0;
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(5));
        try
        {
            for(int run=0;run<2;run++)
            {
                // Reconcile a source after lost local history while retaining a
                // valid Google cursor. This must not rebuild the remote tree.
                if(run==0){var state=store.LoadState(job);state.FullScanRequired=true;store.SaveState(state);}
                using var metrics=new MetricsHandler();using var client=new HttpClient(metrics){Timeout=TimeSpan.FromMinutes(2)};
                using var services=new CloudServices(()=>config,client);var remote=new ScopedGoogle(services.ForJob(job),id,label);
                var stages=new List<string>();var watch=Stopwatch.StartNew();
                var engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=_=>remote};
                var result=await engine.RunAsync(job,false,null,new(),new Reporter(p=>stages.Add(p.Stage)),timeout.Token,reconcileOffline:true);
                runs.Add(new{Run=run+1,Milliseconds=watch.ElapsedMilliseconds,metrics.Requests,SourceScanned=stages.Contains("원본 폴더 비교"),remote.NonInternalListCalls,result.Copied,result.Skipped,Errors=result.Errors.Count});
                if(result.Errors.Count>0 || result.Conflicts.Count>0 || result.Canceled || result.Copied>0)throw new InvalidOperationException("Unchanged restart recheck was not clean.");passed++;
                if(remote.NonInternalListCalls>0)throw new InvalidOperationException("Source reconciliation unnecessarily rebuilt the Google folder tree.");passed++;
                if(store.LoadState(job).PendingPaths.Count!=0)throw new InvalidOperationException("Restart left pending files.");passed++;
            }
            JsonFile.Save(Path.Combine(output,"google-recheck.json"),new{Status="OK",Assertions=passed,Runs=runs,ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),TestFolderId=id});
            Console.WriteLine($"PASS: {passed} live Google restart checks. {output}");
        }
        catch(Exception ex)
        {
            JsonFile.Save(Path.Combine(output,"google-recheck.json"),new{Status="FAILED",Assertions=passed,Runs=runs,Failure=ex.Message,ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),TestFolderId=id});
            throw new InvalidOperationException("Google restart recheck failed: "+ex.Message);
        }
    }
    public static async Task RunAsync(string root,string configPath)
    {
        var before=SHA256.HashData(File.ReadAllBytes(configPath));var config=GoogleOnly(configPath);
        var stateStore=new ConfigStore(Path.Combine(root,"google-live-state"));
        var source=Path.Combine(root,"google-live-source");Directory.CreateDirectory(source);
        var events=new List<object>();var checks=new List<string>();string phase="authentication",folderId="",folderName="";
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(20));var token=timeout.Token;
        using var metrics=new MetricsHandler();using var client=new HttpClient(metrics){Timeout=TimeSpan.FromMinutes(2)};
        using var services=new CloudServices(()=>config,client);
        BackupJob? job=null;ScopedGoogle? remote=null;
        void Save(string status,string? failure=null)
            =>JsonFile.Save(Path.Combine(root,"google-live-result.json"),new{Status=status,RealGoogleAccount=true,Phase=phase,TestFolderName=folderName,TestFolderId=folderId,
                Checks=checks,Events=events,Failure=failure,metrics.TokenError,metrics.TokenExchanges,metrics.Requests,metrics.StatusQueries,metrics.LostReplies,
                DataChunkStarts=metrics.ChunkStarts.ToArray(),ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),
                ExistingBackupUsed=false,PhysicalNetworkDisconnect=false,TestFilesPreserved=true});
        void Check(bool value,string label){if(!value)throw new InvalidOperationException(label);checks.Add(label);}
        async Task<T> Step<T>(string name,Func<Task<T>> action)
        {
            phase=name;Save("RUNNING");Console.WriteLine("Google live: "+name);var watch=Stopwatch.StartNew();
            var value=await action();events.Add(new{Stage=name,Milliseconds=watch.ElapsedMilliseconds});Save("RUNNING");return value;
        }
        string Write(string relative,string text)
        {
            var path=PathPolicy.Combine(source,relative);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,text,Encoding.UTF8);
            File.SetCreationTimeUtc(path,DateTime.UtcNow.AddMinutes(-20));File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddMinutes(-10));return path;
        }
        BackupEngine Engine(ScopedGoogle selected)=>new(new ConfigStore(stateStore.Root)){CloudFactory=_=>selected};
        async Task<BackupResult> Run(bool full=false,IEnumerable<string>? paths=null,IReadOnlyDictionary<string,ConflictAction>? resolutions=null,PauseGate? pause=null)
            =>await Engine(remote!).RunAsync(job!,full,paths,pause??new(),null,token,resolutions);
        void Healthy(BackupResult result,string label)=>Check(!result.Canceled && result.Errors.Count==0,label+"; "+string.Join("; ",result.Errors.Select(e=>e.Reason)));
        async Task VerifyDownload(string relative,string expectedLocal,string label)
        {
            string downloaded=Path.Combine(root,"download-"+Guid.NewGuid().ToString("N"));await remote!.DownloadAsync(relative,downloaded,token);
            Check(await VerifiedFiles.HashAsync(downloaded,token)==await VerifiedFiles.HashAsync(expectedLocal,token),label);
        }
        try
        {
            var accountRoot=services.ForAccountRoot("GoogleDrive");
            await Step("authenticate",async()=>{await accountRoot.InitializeAsync(token);return true;});Check(metrics.TokenExchanges==1,"Real token refresh and account binding passed");
            await Step("create-isolated-test-folder",async()=>
            {
                folderName="SafeSync-validation-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8];
                Check(await accountRoot.StatAsync(folderName,token)==null,"Unique test folder did not exist before test");
                await accountRoot.EnsureFolderAsync(folderName,token);
                var created=await accountRoot.StatAsync(folderName,token) ?? throw new IOException("Created test folder missing");
                Check(created.Folder && created.Id!=accountRoot.Root && created.Name==folderName,"Created folder scope validated");folderId=created.Id;
                job=new(){Name="Isolated Google live test",Source=source,DestinationType="GoogleDrive",Destination="Google Drive / "+folderName,CloudFolderId=folderId,CloudAccountId=accountRoot.AccountId,MirrorDeletes=true};
                remote=new ScopedGoogle(services.ForJob(job),folderId,folderName);await remote.InitializeAsync(token);return true;
            });
            string alpha=Write("alpha.txt","처음 원본"),conflictPath=Write("same-time-conflict.txt","same timestamp source"),lockedPath=Write("locked.txt","locked fixture");
            Write("nested/한글😀.txt","Unicode 경로 검사");File.WriteAllBytes(Write("empty.bin",""),[]);
            var large=Write("large.bin","");File.WriteAllBytes(large,RandomNumberGenerator.GetBytes(16*1024*1024+123));File.SetLastWriteTimeUtc(large,DateTime.UtcNow.AddMinutes(-10));
            for(int i=0;i<8;i++)Write($"small/{i}.txt","small "+i);
            int expected=14;
            var first=await Step("first-backup",()=>Run(true));Healthy(first,"Initial live backup completed without errors");
            Check(first.Copied==expected && first.Conflicts.Count==0,"All 14 initial files backed up");
            var firstState=stateStore.LoadState(job!);Check(firstState.Files.Count==expected && firstState.PendingPaths.Count==0,"Initial cloud snapshot persisted");
            await Step("download-and-hash",async()=>
            {
                foreach(string relative in new[]{"alpha.txt","empty.bin","nested/한글😀.txt","large.bin"})await VerifyDownload(relative,PathPolicy.Combine(source,relative),"Downloaded SHA256 matches "+relative);
                var item=await remote!.StatAsync("alpha.txt",token) ?? throw new IOException("alpha missing");
                Check(Math.Abs((item.ModifiedUtc-File.GetLastWriteTimeUtc(alpha)).TotalSeconds)<2,"Google modified time preserved");
                Check(Math.Abs((item.CreatedUtc-File.GetCreationTimeUtc(alpha)).TotalSeconds)<2,"Google creation time preserved");return true;
            });
            var stages=new List<string>();
            var unchanged=await Step("restart-and-unchanged-comparison",async()=>await Engine(remote!).RunAsync(job!,false,null,new(),new Reporter(p=>stages.Add(p.Stage)),token));
            Healthy(unchanged,"Restarted cloud comparison succeeded");Check(unchanged.Copied==0,"Unchanged files were not re-uploaded");
            Check(!stages.Contains("원본 폴더 비교"),"Restart without offline reconciliation reused the source snapshot");
            Check(new RemoteCatalog(new ConfigStore(stateStore.Root),remote!).State.Cursor.Length>0,"Real Google Changes cursor persisted");

            File.WriteAllText(alpha,"수정된 원본 두 번째 버전",Encoding.UTF8);File.SetLastWriteTimeUtc(alpha,DateTime.UtcNow);
            var changed=await Step("incremental-replacement",()=>Run(paths:["alpha.txt"]));Healthy(changed,"Incremental replacement succeeded");Check(changed.Copied==1,"Only changed alpha uploaded");
            await VerifyDownload("alpha.txt",alpha,"Updated backup content verified");
            var publisher=new CloudPublisher(stateStore,job!,remote!);var trash=new CloudTrash(remote!,publisher,stateStore);
            async Task<List<CloudTrashItem>> Trash(){var rows=new List<CloudTrashItem>();await foreach(var row in trash.ListAsync(token))rows.Add(row);return rows;}
            Check((await Trash()).Any(t=>t.RelativePath=="alpha.txt"),"Replaced version stored in real cloud trash");

            await Step("create-test-only-conflict",async()=>
            {
                var alternate=Path.Combine(root,"external-edit.txt");File.WriteAllText(alternate,"different cloud content; deliberately a different length");
                File.SetCreationTimeUtc(alternate,File.GetCreationTimeUtc(conflictPath));File.SetLastWriteTimeUtc(alternate,File.GetLastWriteTimeUtc(conflictPath));
                var snapshot=await publisher.StageAsync(alternate,token);await publisher.PublishAsync("same-time-conflict.txt",snapshot,await remote!.StatAsync("same-time-conflict.txt",token),false,new(),token);return true;
            });
            Write("after-conflict.txt","must continue despite conflict");
            var conflicted=await Step("conflict-does-not-stop-other-files",()=>Run(paths:["same-time-conflict.txt","after-conflict.txt"]));Healthy(conflicted,"Conflict was not a general error");
            Check(conflicted.Conflicts.Count==1 && conflicted.Copied==1,"Conflict reported while unrelated file backed up");
            Check(stateStore.LoadState(job!).Files.Single(f=>f.RelativePath=="same-time-conflict.txt").Status=="Conflict","Conflict state persisted");
            var beforeIgnore=await remote!.StatAsync("same-time-conflict.txt",token);
            var ignored=await Step("ignore-conflict-this-run",()=>Run(resolutions:new Dictionary<string,ConflictAction>{{"same-time-conflict.txt",ConflictAction.Ignore}}));Healthy(ignored,"Ignore conflict completed");
            Check(RemotePath.Same(beforeIgnore!,(await remote.StatAsync("same-time-conflict.txt",token))!),"Ignored conflict did not overwrite cloud content");
            var resolved=await Step("resolve-conflict-keep-both",()=>Run(resolutions:new Dictionary<string,ConflictAction>{{"same-time-conflict.txt",ConflictAction.KeepBoth}}));Healthy(resolved,"Keep-both conflict resolution succeeded");
            Check(resolved.Copied==1 && (await remote.ListAsync("",token)).Any(f=>f.Name.StartsWith("same-time-conflict.txt.SafeSync-conflict-",StringComparison.Ordinal)),"Previous cloud version kept under renamed file");
            await VerifyDownload("same-time-conflict.txt",conflictPath,"Conflict resolution copied source exactly");

            await Step("locked-file-wait-and-retry",async()=>
            {
                using(var locked=new FileStream(lockedPath,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
                {
                    var waiting=await Run(paths:["locked.txt"]);Check(waiting.Locked.Count==1 && waiting.Errors.Count==0,"Locked source only appeared in waiting list");
                    Check(stateStore.LoadState(job!).PendingPaths.Contains("locked.txt"),"Locked source persisted for retry");
                }
                var retried=await Run();Healthy(retried,"Unlocked file retry succeeded");Check(!stateStore.LoadState(job!).PendingPaths.Contains("locked.txt"),"Unlocked file removed from waiting queue");return true;
            });
            await Step("delete-to-trash-and-restore",async()=>
            {
                var previous=await remote.StatAsync("alpha.txt",token) ?? throw new IOException("alpha missing before deletion");
                File.Delete(alpha);var deletion=await Run(paths:["alpha.txt"]);Healthy(deletion,"Mirrored deletion succeeded");Check(deletion.Trashed==1 && await remote.StatAsync("alpha.txt",token)==null,"Deleted source moved backup to trash");
                var selected=(await Trash()).Single(t=>t.RelativePath=="alpha.txt" && t.Item.Id==previous.Id);await trash.OperateAsync(selected,true,token);
                Check((await remote.StatAsync("alpha.txt",token))?.Id==previous.Id,"Trash restore returned the original cloud file");
                // The UI pauses after restore. This fixture has no scheduler;
                // recreate its synthetic source before subsequent test runs.
                File.WriteAllText(alpha,"수정된 원본 두 번째 버전",Encoding.UTF8);File.SetLastWriteTimeUtc(alpha,previous.ModifiedUtc);
                await VerifyDownload("alpha.txt",alpha,"Restored file content verified");return true;
            });
            await Step("retention-and-selected-trash-delete",async()=>
            {
                var expiry=Path.Combine(root,"expiry-payload");File.WriteAllText(expiry,"old test trash");
                var snapshot=await publisher.StageAsync(expiry,token);await publisher.PublishAsync("expiry-probe.txt",snapshot,null,false,new(),token);
                string expired=".safesync-trash/20000101-120000-deleted/expiry-probe.txt";await remote.MoveAsync("expiry-probe.txt",expired,token);
                var cleanup=await Run();Healthy(cleanup,"Real retention cleanup succeeded");Check(await remote.StatAsync(expired,token)==null,"Expired test batch removed after 100-day retention");
                var recent=(await Trash()).First(t=>t.RelativePath=="alpha.txt");await trash.OperateAsync(recent,false,token);
                Check(await remote.StatAsync(recent.StoragePath,token)==null,"Selected real trash file deleted");Check(await remote.StatAsync("alpha.txt",token)!=null,"Trash deletion preserved active backup");return true;
            });
            await Step("pause-and-resume",async()=>
            {
                Write("pause.txt","paused real cloud transfer");var pause=new PauseGate();pause.Pause();var pending=Run(paths:["pause.txt"],pause:pause);
                try{await Task.Delay(250,token);Check(!pending.IsCompleted && await remote.StatAsync("pause.txt",token)==null,"Paused transfer did not publish file");}
                finally{pause.Resume();}
                var resumed=await pending;Healthy(resumed,"Same paused cloud run resumed");Check(resumed.Copied==1,"Resumed cloud file uploaded");return true;
            });
            await Step("lost-upload-response-and-session-recovery",async()=>
            {
                var path=Write("resume.bin","");File.WriteAllBytes(path,RandomNumberGenerator.GetBytes(8*1024*1024+123));File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddMinutes(-10));
                metrics.ChunkStarts.Clear();int queries=metrics.StatusQueries;metrics.DropNextIncompleteChunk=true;
                var interrupted=await Run(paths:["resume.bin"]);
                Check(metrics.LostReplies==1 && interrupted.Errors.Count==1,"Server accepted chunk, response loss simulated only in test client");
                Check(stateStore.LoadState(job!).PendingPaths.Contains("resume.bin"),"Interrupted real upload retained pending snapshot");
                Check(Directory.EnumerateFiles(Path.Combine(stateStore.Root,"cloud-transactions-v2"),"*.json").Any(),"Interrupted upload journal retained");
                remote=new ScopedGoogle(services.ForJob(job!),folderId,folderName);var recovered=await Run();Healthy(recovered,"Upload session reconciled on restarted engine");
                Check(metrics.StatusQueries>queries,"Recovery queried real Google resumable session status");
                Check(metrics.ChunkStarts.SequenceEqual(new long[]{0,8*1024*1024}),"Already accepted first 8 MiB chunk was not re-uploaded");
                Check(!stateStore.LoadState(job!).PendingPaths.Contains("resume.bin") && !Directory.EnumerateFiles(Path.Combine(stateStore.Root,"cloud-transactions-v2"),"*.json").Any(),"Recovered snapshot and journal finalized");
                await VerifyDownload("resume.bin",path,"Recovered upload downloaded SHA256 matches source");return true;
            });
            Check(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),"Existing account configuration unchanged");
            Save("OK");Console.WriteLine($"PASS: {checks.Count} real Google checks. {root}");
            Console.WriteLine("Test folder: https://drive.google.com/drive/folders/"+folderId);
        }
        catch(Exception ex)
        {
            // Never log HTTP bodies, tokens, credentials or resumable URLs.
            string summary=ex is CloudApiException api ? $"HTTP {(int)api.Status}" : ex.GetType().Name+": "+System.Text.RegularExpressions.Regex.Replace(ex.Message,@"https?://\S+","[URL omitted]");
            Save("FAILED",summary);throw new InvalidOperationException("Real Google verification failed at "+phase+" ("+ex.GetType().Name+"). See isolated google-live-result.json.");
        }
    }
    public static async Task TwoWayAsync(string root,string configPath)
    {
        var before=SHA256.HashData(File.ReadAllBytes(configPath));var config=GoogleOnly(configPath);
        var source=Path.Combine(root,"google-two-way-source");Directory.CreateDirectory(source);
        var store=new ConfigStore(Path.Combine(root,"google-two-way-state"));
        var checks=new List<string>();var stages=new List<object>();string folderId="",folderName="",phase="authenticate";
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(12));var ct=timeout.Token;
        using var services=new CloudServices(()=>config);
        void Check(bool value,string label){if(!value)throw new InvalidOperationException(label);checks.Add(label);}
        void Save(string status,string? failure=null)=>JsonFile.Save(Path.Combine(root,"google-two-way-result.json"),new{Status=status,Phase=phase,Checks=checks,Stages=stages,TestFolderId=folderId,TestFolderName=folderName,Failure=failure,ExistingBackupsTouched=false,TestFilesPreserved=true,ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath)))});
        try
        {
            var accountRoot=services.ForAccountRoot("GoogleDrive");await accountRoot.InitializeAsync(ct);
            folderName="SafeSync-validation-twoway-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..8];
            Check(await accountRoot.StatAsync(folderName,ct)==null,"Dedicated folder did not previously exist");
            await accountRoot.EnsureFolderAsync(folderName,ct);folderId=(await accountRoot.StatAsync(folderName,ct))!.Id;
            var job=new BackupJob {Name="Isolated two-way Google test",SyncMode="TwoWay",Source=source,Destination=folderName,DestinationType="GoogleDrive",CloudFolderId=folderId,CloudAccountId=CloudAccounts.Read(config).GoogleDrive.AccountId};
            var selected=new ScopedGoogle(services.ForJob(job),folderId,folderName);await selected.InitializeAsync(ct);
            var publisher=new CloudPublisher(store,job,selected);var engine=new BackupEngine(store){CloudFactory=_=>selected};
            string Write(string name,string value){var path=PathPolicy.Combine(source,name);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllText(path,value,Encoding.UTF8);return path;}
            async Task Put(string name,string value)
            {
                var external=Path.Combine(root,"external-"+Guid.NewGuid().ToString("N"));File.WriteAllText(external,value,Encoding.UTF8);
                var snapshot=await publisher.StageAsync(external,ct);await publisher.PublishAsync(name,snapshot,await selected.StatAsync(name,ct),false,new(),ct);
            }
            async Task<BackupResult> Run(string label,bool full=false,string[]? dirty=null,Dictionary<string,ConflictAction>? actions=null)
            {
                phase=label;Save("RUNNING");Console.WriteLine("Google two-way: "+label);var watch=Stopwatch.StartNew();
                var value=await engine.RunAsync(job,full,dirty,new(),null,ct,actions,reconcileOffline:label=="restart-unchanged");
                stages.Add(new{Stage=label,Milliseconds=watch.ElapsedMilliseconds,value.Copied,value.Skipped,value.Trashed,Conflicts=value.Conflicts.Count,Errors=value.Errors.Select(x=>x.Reason).ToArray()});
                Check(value.Errors.Count==0 && !value.Canceled,label+": clean execution");return value;
            }
            Write("source-only.txt","source version");await Put("remote-only.txt","remote version");
            Check((await Run("initial-union",true)).Copied==2,"Initial union copied in both directions");
            Check(File.ReadAllText(PathPolicy.Combine(source,"remote-only.txt"))=="remote version","Remote-only file downloaded");
            int scans=selected.NonInternalListCalls;
            Check((await Run("unchanged")).Copied==0 && selected.NonInternalListCalls==scans,"Unchanged run reused remote cursor without folder scan");
            Write("source-only.txt","source changed");Check((await Run("source-edit",dirty:["source-only.txt"])).Copied==1,"Source edit uploaded");
            await Put("remote-only.txt","remote changed");Check((await Run("remote-edit",true)).Copied==1,"Remote edit downloaded");
            Check(File.ReadAllText(PathPolicy.Combine(source,"remote-only.txt"))=="remote changed","Downloaded remote edit verified");
            await publisher.TrashAsync("source-only.txt",(await selected.StatAsync("source-only.txt",ct))!,ct);
            Check((await Run("remote-deletion",true)).Trashed==1,"Cloud deletion propagated to source");
            Check(!File.Exists(PathPolicy.Combine(source,"source-only.txt")) && new TrashService().List(source,ct).Any(x=>x.RelativePath=="source-only.txt"),"Deleted source retained in local trash");
            File.Delete(PathPolicy.Combine(source,"remote-only.txt"));Check((await Run("source-deletion",dirty:["remote-only.txt"])).Trashed==1,"Source deletion propagated to cloud trash");
            Check(await selected.StatAsync("remote-only.txt",ct)==null,"Cloud active file removed");
            Write("conflict.txt","baseline");await Run("conflict-baseline",dirty:["conflict.txt"]);
            Write("conflict.txt","local edit");await Put("conflict.txt","remote edit");Write("unrelated.txt","continues");
            var conflict=await Run("simultaneous-edits",true);
            Check(conflict.Conflicts.Count==1 && conflict.Copied==1,"Conflict isolated while unrelated file copied");
            Check(File.ReadAllText(PathPolicy.Combine(source,"conflict.txt"))=="local edit","Conflict did not overwrite local edit");
            Check((await Run("choose-backup",actions:new(){{"conflict.txt",ConflictAction.UseBackup}})).Conflicts.Count==0,"Explicit backup choice resolved conflict");
            Check(File.ReadAllText(PathPolicy.Combine(source,"conflict.txt"))=="remote edit","Backup choice restored remote bytes");
            Write("conflict.txt","edited before deletion");await publisher.TrashAsync("conflict.txt",(await selected.StatAsync("conflict.txt",ct))!,ct);
            Check((await Run("delete-edit-conflict",true)).Conflicts.Count==1,"Remote deletion versus local edit preserved as conflict");
            await Run("choose-source",actions:new(){{"conflict.txt",ConflictAction.Overwrite}});
            engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=_=>selected};scans=selected.NonInternalListCalls;
            Check((await Run("restart-unchanged")).Copied==0 && selected.NonInternalListCalls==scans,"Restart retained common baseline and cloud catalog");
            Check(store.LoadState(job).PendingPaths.Count==0,"All resolved paths checkpointed");
            Directory.CreateDirectory(Path.Combine(source,"empty","nested"));await Run("empty-folders",true);
            Check((await selected.StatAsync("empty/nested",ct))?.Folder==true,"Nested empty folder synchronized");
            Write("tree/sub/한글.txt","nested content");await Run("nested-file",true);
            Check((await selected.StatAsync("tree/sub/한글.txt",ct))?.Length==new FileInfo(Path.Combine(source,"tree","sub","한글.txt")).Length,"Nested file synchronized");
            Check(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),"Existing configuration unchanged");
            Save("OK");Console.WriteLine($"PASS: {checks.Count} real Google two-way assertions. {root}");
        }
        catch(Exception ex){Save("FAILED",ex.GetType().Name+": "+ex.Message);throw;}
    }
    public static async Task ProbeAsync(string root,string configPath)
    {
        var before=SHA256.HashData(File.ReadAllBytes(configPath));
        var config=GoogleOnly(configPath);using var metrics=new MetricsHandler();
        using var client=new HttpClient(metrics){Timeout=TimeSpan.FromMinutes(2)};
        using var services=new CloudServices(()=>config,client);
        using var timeout=new CancellationTokenSource(TimeSpan.FromMinutes(3));
        try
        {
            var remote=services.ForAccountRoot("GoogleDrive");await remote.InitializeAsync(timeout.Token);
            JsonFile.Save(Path.Combine(root,"google-probe.json"),new{Status="OK",RealAccount=true,ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath))),TokenExchanges=metrics.TokenExchanges});
            Console.WriteLine("PASS: connected Google account authenticated through SafeSync; configuration unchanged.");
        }
        catch(Exception ex)
        {
            JsonFile.Save(Path.Combine(root,"google-probe.json"),new{Status="FAILED",FailureType=ex.GetType().Name,HttpStatus=ex is CloudApiException api ? (int?)api.Status : null,metrics.TokenError,ConfigUnchanged=before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(configPath)))});
            throw new InvalidOperationException("Google connection probe failed: "+ex.GetType().Name+" "+metrics.TokenError+". See isolated google-probe.json; no tokens were logged.");
        }
    }
    private static AppConfig GoogleOnly(string configPath)
    {
        var source=JsonFile.Read<AppConfig>(configPath);var account=CloudAccounts.Read(source).GoogleDrive;
        if(account.AccountId.Length==0 || account.RefreshTokenProtected.Length==0 || account.ClientId.Length==0)throw new InvalidOperationException("Google account is not connected in the selected configuration.");
        var config=new AppConfig();new CloudAccounts{GoogleDrive=account}.Write(config);return config;
    }

    private sealed class MetricsHandler : DelegatingHandler
    {
        private int tokenExchanges;
        private long requests;
        private int statusQueries,lostReplies;
        public long Requests=>Interlocked.Read(ref requests);
        public int StatusQueries=>statusQueries;
        public int LostReplies=>lostReplies;
        public bool DropNextIncompleteChunk {get;set;}
        public List<long> ChunkStarts {get;}=[];
        public int TokenExchanges=>tokenExchanges;
        public string TokenError {get;private set;}="";
        internal MetricsHandler():base(new HttpClientHandler{AllowAutoRedirect=false}){}
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
        {
            Interlocked.Increment(ref requests);
            bool chunk=request.Method==HttpMethod.Put && request.Content?.Headers.ContentRange is {HasRange:true};
            if(chunk){lock(ChunkStarts)ChunkStarts.Add(request.Content!.Headers.ContentRange!.From!.Value);}
            else if(request.Method==HttpMethod.Put && request.Content?.Headers.ContentRange is {HasRange:false,Length:>0})Interlocked.Increment(ref statusQueries);
            var response=await base.SendAsync(request,token);
            if(chunk && DropNextIncompleteChunk && (int)response.StatusCode==308)
            {DropNextIncompleteChunk=false;Interlocked.Increment(ref lostReplies);response.Dispose();throw new HttpRequestException("Injected loss of an accepted test-only upload response");}
            if(request.RequestUri?.Host=="oauth2.googleapis.com")
            {
                Interlocked.Increment(ref tokenExchanges);
                if(!response.IsSuccessStatusCode)
                {
                    try
                    {
                        using var body=JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
                        var error=body.RootElement.String("error");
                        if(error is "invalid_grant" or "invalid_client" or "unauthorized_client" or "invalid_request" or "temporarily_unavailable")TokenError=error;
                    }
                    catch(JsonException){}
                }
            }
            return response;
        }
    }
    private sealed class Reporter(Action<BackupProgress> report) : IProgress<BackupProgress>
    {public void Report(BackupProgress value)=>report(value);}
    private sealed class ScopedGoogle : IRemoteStore,IRemoteChanges,IRemoteBatch,IRemoteParallel
    {
        private readonly IRemoteStore inner;
        private readonly string id,label;
        public int NonInternalListCalls {get;private set;}
        internal ScopedGoogle(IRemoteStore inner,string id,string label)
        {
            if(!label.StartsWith("SafeSync-validation-",StringComparison.Ordinal)||inner.Root!=id)throw new InvalidOperationException("Live test scope mismatch");
            this.inner=inner;this.id=id;this.label=label;
        }
        private void Guard(string path){RemotePath.Normalize(path);if(inner.Root!=id)throw new InvalidOperationException("Test root changed");}
        public string Provider=>inner.Provider;public string Root=>inner.Root;public string AccountId=>inner.AccountId;
        public async Task InitializeAsync(CancellationToken token)
        {
            await inner.InitializeAsync(token);Guard("");var root=await inner.StatAsync("",token);
            if(root?.Folder!=true || root.Id!=id || root.Name!=label)throw new InvalidOperationException("Newly created test root identity changed");
        }
        public Task<RemoteItem?> StatAsync(string path,CancellationToken token){Guard(path);return inner.StatAsync(path,token);}
        public Task<IReadOnlyList<RemoteItem>> ListAsync(string path,CancellationToken token){Guard(path);if(!path.StartsWith(".safesync-",StringComparison.Ordinal))NonInternalListCalls++;return inner.ListAsync(path,token);}
        public Task EnsureFolderAsync(string path,CancellationToken token){Guard(path);return inner.EnsureFolderAsync(path,token);}
        public Task<RemoteItem> UploadAsync(UploadSnapshot file,string path,UploadSession session,Action save,PauseGate pause,CancellationToken token){Guard(path);return inner.UploadAsync(file,path,session,save,pause,token);}
        public Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token){Guard(from);Guard(to);return inner.MoveAsync(from,to,token);}
        public Task DownloadAsync(string path,string local,CancellationToken token){Guard(path);return inner.DownloadAsync(path,local,token);}
        public Task DeleteAsync(string path,CancellationToken token){Guard(path);return inner.DeleteAsync(path,token);}
        public Task<string> CaptureCursorAsync(CancellationToken token)=>((IRemoteChanges)inner).CaptureCursorAsync(token);
        public Task<RemoteChanges> ChangesAsync(string cursor,IReadOnlyDictionary<string,RemoteItem> known,CancellationToken token)=>((IRemoteChanges)inner).ChangesAsync(cursor,known,token);
        public Task<IReadOnlyDictionary<string,RemoteItem?>> StatManyAsync(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> paths,CancellationToken token)=>((IRemoteBatch)inner).StatManyAsync(known,paths,token);
    }
}
