using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class RestartIndexRegressionTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            var home=Path.Combine(root,"restart-folder-repair",provider);
            var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");
            Directory.CreateDirectory(Path.Combine(source,"folder"));Directory.CreateDirectory(backup);
            File.WriteAllText(Path.Combine(source,"folder","old.txt"),"old");
            var remote=provider=="Local" ? null : new MemoryRemote(provider);
            var job=new BackupJob {Source=source,Destination=backup,DestinationType=provider,CloudFolderId=remote?.Root ?? "",CloudAccountId=remote?.AccountId ?? "",MirrorDeletes=true};
            var store=new ConfigStore(Path.Combine(home,"state"));
            Task<BackupResult> Run(bool full=false,string[]? changes=null,IReadOnlyDictionary<string,ConflictAction>? actions=null)
            {
                var engine=new BackupEngine(new ConfigStore(store.Root)){CloudFactory=remote==null ? null : _=>remote};
                return engine.RunAsync(job,full,changes,new(),null,default,actions);
            }
            var first=await Run(true);
            check(first.Copied==1 && first.Errors.Count+first.Conflicts.Count==0,provider+": folder repair baseline failed.");
            var repeated=await Run(changes:["folder"]);
            check(repeated.Errors.Count+repeated.Conflicts.Count==0,provider+": a live directory event became a missing-file conflict.");
            check(!store.LoadState(job).Files.Any(e=>e.RelativePath=="folder") && !store.LoadState(job).PendingPaths.Contains("folder"),provider+": directory event persisted as a file row.");
            // Reproduce the exact old on-disk bogus conflict, not just a clean new job.
            var state=store.LoadState(job);
            state.Files.Add(new FileEntry {RelativePath="folder",Status="Conflict",LastError="previous invalid folder event"});
            state.PendingPaths.Add("folder");state.CheckpointActive=true;store.SaveState(state);
            File.WriteAllText(Path.Combine(source,"folder","new.txt"),"new");
            var repaired=await Run(changes:["folder"]);
            state=store.LoadState(job);
            check(repaired.Copied==1 && repaired.Errors.Count+repaired.Conflicts.Count==0,provider+": stale directory row prevented discovering new children.");
            check(state.Files.Count==2 && state.Files.All(e=>e.Status=="BackedUp") && state.PendingPaths.Count==0 && !state.CheckpointActive,provider+": stale folder conflict did not repair its snapshot.");
            check(remote==null ? File.ReadAllText(Path.Combine(backup,"folder","old.txt"))=="old" : Encoding.UTF8.GetString(remote.Bytes("folder/old.txt"))=="old",provider+": directory repair modified an existing child.");
            check(remote==null ? File.ReadAllText(Path.Combine(backup,"folder","new.txt"))=="new" : Encoding.UTF8.GetString(remote.Bytes("folder/new.txt"))=="new",provider+": directory repair missed a new child.");

            if(provider!="Local")continue;
            Directory.CreateDirectory(Path.Combine(source,"collision"));File.WriteAllText(Path.Combine(backup,"collision"),"must preserve");
            File.WriteAllText(Path.Combine(source,"independent.txt"),"continues");
            var collision=await Run(changes:["collision","independent.txt"]);
            check(collision.Conflicts.Any(i=>i.File=="collision") && File.ReadAllText(Path.Combine(backup,"collision"))=="must preserve","Folder/file collision was discarded or overwritten.");
            check(File.ReadAllText(Path.Combine(backup,"independent.txt"))=="continues","Folder/file collision stopped unrelated files.");
            var ignored=await Run(changes:["collision"],actions:new Dictionary<string,ConflictAction>{{"collision",ConflictAction.Ignore}});
            check(ignored.Conflicts.Count==0 && File.ReadAllText(Path.Combine(backup,"collision"))=="must preserve","Ignore on a directory/file conflict lost its existing behavior.");
            // A formerly tracked file can become a directory. Its children must
            // be discovered even while that old path is already in the snapshot.
            File.WriteAllText(Path.Combine(source,"kind"),"old kind");await Run(changes:["kind"]);
            File.Delete(Path.Combine(source,"kind"));Directory.CreateDirectory(Path.Combine(source,"kind"));
            File.WriteAllText(Path.Combine(source,"kind","child.txt"),"new kind");
            TrashService.Move(backup,"kind","test-kind-change");
            var changedKind=await Run(changes:["kind"]);
            check(changedKind.Errors.Count==0 && File.ReadAllText(Path.Combine(backup,"kind","child.txt"))=="new kind","Tracked file-to-directory change lost nested file discovery.");
            // A missing legacy source is NOT a repaired live directory. Keep the
            // deletion review barrier and the existing backup data intact.
            state=store.LoadState(job);state.Files.Add(new FileEntry {RelativePath="legacy-missing",Status="Conflict"});state.PendingPaths.Add("legacy-missing");store.SaveState(state);
            File.WriteAllText(Path.Combine(backup,"legacy-missing"),"legacy data");
            var missing=await Run(changes:["legacy-missing"]);
            check(missing.Conflicts.Any(i=>i.File=="legacy-missing") && File.ReadAllText(Path.Combine(backup,"legacy-missing"))=="legacy data","Directory repair bypassed missing legacy file deletion protection.");
        }
    }
}
