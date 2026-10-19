using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class FileComparisonTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var mode in new[]{"OneWay","TwoWay"})
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            string label=mode+"/"+provider;
            var home=Path.Combine(root,"file-comparison-"+mode+"-"+provider);var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            var remote=provider=="Local" ? null : new MemoryRemote(provider);var store=new ConfigStore(Path.Combine(home,"data"));
            var job=new BackupJob {Source=source,Destination=backup,SyncMode=mode,DestinationType=provider,CloudFolderId=remote?.Root ?? "",CloudAccountId=remote?.AccountId ?? "",MirrorDeletes=true};
            var engine=new BackupEngine(store){CloudFactory=_=>remote!};const string name="한글 폴더/비교.txt";
            string PathOf(string folder,string file=name)=>PathPolicy.Combine(folder,file);
            void Write(string text){Directory.CreateDirectory(Path.GetDirectoryName(PathOf(source))!);File.WriteAllText(PathOf(source),text);File.SetLastWriteTimeUtc(PathOf(source),DateTime.UtcNow.AddDays(-2));}
            async Task Put(string text)
            {
                if(remote!=null)await remote.SeedAsync(name,text,DateTime.UtcNow.AddDays(-1));
                else{Directory.CreateDirectory(Path.GetDirectoryName(PathOf(backup))!);File.WriteAllText(PathOf(backup),text);File.SetLastWriteTimeUtc(PathOf(backup),DateTime.UtcNow.AddDays(-1));}
            }
            string Right()=>remote==null ? File.ReadAllText(PathOf(backup)) : Encoding.UTF8.GetString(remote.Bytes(name));
            Task<FileComparison> Inspect()=>FileComparisons.ReadAsync(job,name,remote,default);
            async Task<ComparedResolutions> Choose(ConflictAction action){var choices=new ComparedResolutions();choices.Choose(await Inspect(),action);return choices;}
            Task<BackupResult> Run(IReadOnlyDictionary<string,ConflictAction>? choices=null,bool full=false)=>engine.RunAsync(job,full,[name],new(),null,default,choices);
            void Healthy(BackupResult result,string stage)=>check(!result.Canceled && result.Errors.Count+result.Conflicts.Count+result.Locked.Count==0,label+" "+stage+": "+string.Join(";",result.Errors.Concat(result.Conflicts).Select(i=>i.Reason)));

            Write("left original");await Put("right original long");var initial=await Run(full:true);
            check(initial.Conflicts.Any(i=>i.File==name),label+" missing initial conflict");
            var issue=initial.Conflicts.Single(i=>i.File==name);
            check(issue.SourceCreated.Length>0 && issue.BackupCreated.Length>0 && issue.SourceExists==true && issue.BackupExists==true,label+" conflict lost creation/existence metadata");
            var comparison=await Inspect();
            check(comparison.Readable && comparison.CanForward && comparison.CanReverse && comparison.Source!.Length==new FileInfo(PathOf(source)).Length && comparison.Backup!.Length==Encoding.UTF8.GetByteCount("right original long"),label+" side metadata invalid");
            Healthy(await Run(await Choose(ConflictAction.UseBackup)),"reverse");
            check(File.ReadAllText(PathOf(source))=="right original long" && Right()=="right original long",label+" reverse overwrote wrong side");
            check(new TrashService().List(source,default).Any(i=>i.RelativePath==name && File.ReadAllText(i.StoragePath)=="left original"),label+" reverse lost prior source");
            check(job.SyncMode==mode,label+" explicit reverse changed automatic mode");

            File.Delete(PathOf(source));var missing=await Inspect();
            check(missing.Source==null && missing.CanReverse && !missing.CanForward,label+" missing source not restorable");
            var refused=await Run(await Choose(ConflictAction.Overwrite));
            check(refused.Conflicts.Any(i=>i.File==name) && !File.Exists(PathOf(source)) && Right()=="right original long",label+" forward choice deleted backup when source was absent");
            Healthy(await Run(await Choose(ConflictAction.UseBackup)),"restore missing source");
            check(File.ReadAllText(PathOf(source))=="right original long" && Right()=="right original long",label+" explicit restore propagated source deletion");

            Write("new left");await Put("new right longer");var stale=await Choose(ConflictAction.Overwrite);Write("edited after choosing");
            var blocked=await Run(stale);
            check(blocked.Conflicts.Any(i=>i.File==name && i.Reason.Contains("비교 후")) && Right()=="new right longer",label+" stale source choice overwrote backup");
            stale=await Choose(ConflictAction.UseBackup);await Put("remote edited after choosing");
            blocked=await Run(stale);
            check(blocked.Conflicts.Any(i=>i.File==name) && File.ReadAllText(PathOf(source))=="edited after choosing",label+" stale backup choice overwrote source");

            Write("keep left");await Put("keep right");Healthy(await Run(await Choose(ConflictAction.KeepBoth)),"keep both");
            check(Right()=="keep left",label+" keep-both failed to copy left");
            check(remote==null ? Directory.EnumerateFiles(Path.GetDirectoryName(PathOf(backup))!,"*.SafeSync-conflict-*").Any(p=>File.ReadAllText(p)=="keep right") : remote.Files.Keys.Any(p=>p.Contains(".SafeSync-conflict-") && Encoding.UTF8.GetString(remote.Bytes(p))=="keep right"),label+" keep-both lost previous right");

            Write("skip left");await Put("skip right");Healthy(await Run(await Choose(ConflictAction.Ignore)),"ignore");
            check(File.ReadAllText(PathOf(source))=="skip left" && Right()=="skip right",label+" ignore mutated a side");
            check((await Run()).Conflicts.Any(i=>i.File==name),label+" ignore permanently hid unresolved difference");

            if(remote!=null)
            {
                remote.CorruptDownload=true;var corrupt=await Run(await Choose(ConflictAction.UseBackup));
                check(corrupt.Errors.Any(i=>i.File==name) && File.ReadAllText(PathOf(source))=="skip left",label+" corrupt reverse download damaged original");
                Healthy(await Run(await Choose(ConflictAction.UseBackup)),"retry corrupt download");
                check(File.ReadAllText(PathOf(source))=="skip right",label+" retry reverse did not resume");
            }
            else
            {
                using(var locked=new FileStream(PathOf(source),FileMode.Open,FileAccess.ReadWrite,FileShare.None))
                {
                    var waiting=await Run(await Choose(ConflictAction.UseBackup));
                    check(waiting.Locked.Any(i=>i.File==name),label+" locked original was not deferred");
                }
                check(File.ReadAllText(PathOf(source))=="skip left",label+" locked reverse damaged source");
            }

            var rebound=await Choose(ConflictAction.Overwrite);var old=job.Destination;job.Destination+=" (changed)";bool rejected=false;
            try{await FileComparisons.VerifyAsync(job,name,remote,rebound,default);}catch(CloudConflictException){rejected=true;}finally{job.Destination=old;}
            check(rejected,label+" decisions survived endpoint change");
            bool unsafePath=false;try{await FileComparisons.ReadAsync(job,"../outside.txt",remote,default);}catch(InvalidDataException){unsafePath=true;}
            check(unsafePath,label+" comparison accepted path traversal");
            var noFile=await FileComparisons.ReadAsync(job,"missing.txt",remote,default);
            check(noFile.Source==null && noFile.Backup==null && !noFile.CanForward && !noFile.CanReverse,label+" missing files masqueraded as empty files");
            var rootChoice=new ComparedResolutions();rootChoice.Choose(noFile,ConflictAction.UseBackup);
            Directory.Move(source,source+"-prior");Directory.CreateDirectory(source);
            bool rootChanged=false;
            try{await FileComparisons.VerifyAsync(job,"missing.txt",remote,rootChoice,default);}catch(CloudConflictException){rootChanged=true;}
            finally{Directory.Delete(source);Directory.Move(source+"-prior",source);}
            check(rootChanged,label+" replaced root with same missing-file metadata was accepted");
            Directory.Move(source,source+"-offline");
            try{var offline=await Inspect();check(offline.SourceError.Length>0 && !offline.CanReverse && !offline.CanForward,label+" offline root treated as missing file");}
            finally{Directory.Move(source+"-offline",source);}

            // Simulate a crash AFTER publishing a damaged reverse-copy result.
            // A normal restarted run must recover the source-side journal even
            // for one-way jobs, without requiring another reverse command.
            string previous=TrashService.NewPath(source,name,"interrupted-restore");Directory.CreateDirectory(Path.GetDirectoryName(previous)!);File.WriteAllText(previous,"last safe source");
            string staged=PathOf(source)+".safesync-part-crash-test";File.WriteAllText(staged,"intended downloaded bytes");File.WriteAllText(PathOf(source),"damaged publish");
            string journal=Path.Combine(source,".safesync-txn-v2-comparison-test.json");
            JsonFile.Save(journal,new VerifiedFiles.Transaction {Destination=name,Staged=Path.GetRelativePath(source,staged),Previous=Path.GetRelativePath(source,previous),PreviousHash=await VerifiedFiles.HashAsync(previous,default),ExpectedHash=await VerifiedFiles.HashAsync(staged,default),Length=new FileInfo(staged).Length});
            string expired=PathPolicy.Combine(source,".safesync-trash/20000101-000000000-replaced-fixture/expired.txt");Directory.CreateDirectory(Path.GetDirectoryName(expired)!);File.WriteAllText(expired,"old trash");
            engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=_=>remote!};
            await Run(new Dictionary<string,ConflictAction>{{name,ConflictAction.Ignore}});
            check(File.ReadAllText(PathOf(source))=="last safe source" && !File.Exists(journal) && !File.Exists(staged),label+" restart failed to recover interrupted source replacement");
            check(!File.Exists(expired),label+" reverse-copy source trash ignored retention");
        }
    }
}
