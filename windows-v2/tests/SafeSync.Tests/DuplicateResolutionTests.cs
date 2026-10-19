using System.Security.Cryptography;
using System.Text;
using SafeSync.Core;
using SafeSync.Core.Cloud;

internal static class DuplicateResolutionTests
{
    public static async Task RunAsync(string root,Action<bool,string> check)
    {
        foreach(var mode in new[]{"OneWay","TwoWay"})
        foreach(var action in new[]{ConflictAction.Overwrite,ConflictAction.UseBackup,ConflictAction.KeepBoth,ConflictAction.NormalizeDuplicates})
        {
            var home=Path.Combine(root,"duplicates-checked-"+mode+"-"+action);var source=Path.Combine(home,"source");Directory.CreateDirectory(source);
            var file=Path.Combine(source,"same.txt");await File.WriteAllTextAsync(file,"original");
            var remote=new DuplicateRemote();await remote.Inner.SeedAsync("same.txt","original",DateTime.UtcNow.AddHours(1));
            remote.Inner.Files["same.txt"]=remote.Inner.Files["same.txt"] with{Id="a-primary"};remote.Duplicate("same.txt","original");
            var store=new ConfigStore(Path.Combine(home,"data"));var job=new BackupJob{Source=source,Destination="test cloud",DestinationType="GoogleDrive",CloudAccountId=remote.AccountId,CloudFolderId=remote.Root,SyncMode=mode,MirrorDeletes=true};
            var engine=new BackupEngine(store){CloudFactory=_=>remote};
            Task<BackupResult> Run(IReadOnlyDictionary<string,ConflictAction>? choices=null)=>engine.RunAsync(job,true,null,new(),null,default,choices);
            var same=await Run();check(same.Copied==0 && same.Conflicts.Count+same.Errors.Count==0 && same.Skipped>0,mode+" identical duplicate bytes did not skip.");
            check(store.LoadState(job).Files.Single().Status=="BackedUp",mode+" identical duplicates not checkpointed.");
            if(mode=="TwoWay")check(store.LoadState(job).Files.Single().SyncSource==null,mode+" ambiguous copies gained deletion authority.");
            remote.Duplicate("same.txt","different copy");await File.WriteAllTextAsync(file,"new source");
            var conflict=await Run();check(conflict.Conflicts.Count==1 && remote.Extras.Count==1,mode+" different duplicate silently selected or deleted.");
            var uncheckedForce=await Run(new Dictionary<string,ConflictAction>{{"same.txt",ConflictAction.Overwrite}});
            check(uncheckedForce.Conflicts.Count==1 && remote.Extras.Count==1,mode+" unchecked duplicate force bypassed metadata confirmation.");
            var snapshot=await FileComparisons.ReadAsync(job,"same.txt",remote,default);
            check(snapshot.Readable && snapshot.CanForward && snapshot.CanReverse && snapshot.Duplicates?.Groups.Length==1,mode+" duplicate comparison cannot offer resolution.");
            var stale=new ComparedResolutions();stale.Choose(snapshot,action);remote.Duplicate("same.txt","changed after inspection");
            bool refused=false;try{await Run(stale);}catch(CloudConflictException){refused=true;}
            check(refused && remote.Preserved.Count==0,mode+" stale duplicate decision renamed files.");
            snapshot=await FileComparisons.ReadAsync(job,"same.txt",remote,default);var choices=new ComparedResolutions();choices.Choose(snapshot,action);
            var result=await Run(choices);
            check(remote.Extras.Count==0 && remote.Preserved.Count==1 && remote.Preserved[0].Text=="changed after inspection",mode+" duplicate resolution lost other copy.");
            if(action==ConflictAction.NormalizeDuplicates)
                check(result.Conflicts.Count==1 && Encoding.UTF8.GetString(remote.Inner.Bytes("same.txt"))=="original" && File.ReadAllText(file)=="new source",mode+" name-only resolution forced content change.");
            else
            {
                check(result.Errors.Count+result.Conflicts.Count==0,mode+" checked duplicate copy remained blocked.");
                string expected=action==ConflictAction.UseBackup ? "original" : "new source";
                check(File.ReadAllText(file)==expected && Encoding.UTF8.GetString(remote.Inner.Bytes("same.txt"))==expected,mode+" duplicate copy direction is wrong.");
                if(action==ConflictAction.UseBackup)check(new TrashService().List(source,default).Any(i=>i.RelativePath=="same.txt"),mode+" reverse duplicate copy lost source original.");
                if(action==ConflictAction.KeepBoth)check(remote.Inner.Files.Keys.Any(k=>k.StartsWith("same.txt.SafeSync-conflict-")),mode+" keep both lost canonical original.");
            }
        }
        await GoogleDuplicateProtocolTests.RunAsync(root,check);
    }
    private sealed class DuplicateRemote:IRemoteStore,IRemoteDuplicates
    {
        public MemoryRemote Inner {get;}=new("GoogleDrive");
        public Dictionary<string,(RemoteItem Item,string Text)> Extras {get;}=new();
        public List<(RemoteItem Item,string Text)> Preserved {get;}=[];
        public string Provider=>Inner.Provider;public string Root=>Inner.Root;public string AccountId=>Inner.AccountId;
        public void Duplicate(string path,string text)
        {
            var bytes=Encoding.UTF8.GetBytes(text);Extras[path]=(new("z-extra",RemotePath.Name(path),false,bytes.Length,DateTime.UtcNow,DateTime.UtcNow,Convert.ToHexStringLower(MD5.HashData(bytes)),Guid.NewGuid().ToString()),text);
        }
        public Task InitializeAsync(CancellationToken ct)=>Inner.InitializeAsync(ct);
        public Task<RemoteItem?> StatAsync(string path,CancellationToken ct)=>Extras.ContainsKey(path) ? throw new CloudDuplicateNameException(path) : Inner.StatAsync(path,ct);
        public async Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken ct)=>(await Inner.ListAsync(directory,ct)).Concat(Extras.Where(p=>RemotePath.Parent(p.Key)==directory).Select(p=>p.Value.Item)).ToArray();
        public async Task<IReadOnlyList<RemoteItem>> CandidatesAsync(string path,CancellationToken ct)
        {var item=await Inner.StatAsync(path,ct);return (item==null ? Array.Empty<RemoteItem>() : new[]{item}).Concat(Extras.TryGetValue(path,out var extra) ? new[]{extra.Item} : []).ToArray();}
        public async Task<DuplicatePlan> InspectDuplicatesAsync(string path,CancellationToken ct)
        {var items=(await CandidatesAsync(path,ct)).OrderBy(i=>i.Id,StringComparer.Ordinal).ToArray();return new(items.FirstOrDefault(),items.Length>1 ? [new(path,Root,items)] : []);}
        public async Task PreserveDuplicatesAsync(DuplicatePlan expected,CancellationToken ct)
        {
            foreach(var group in expected.Groups)
            {
                if(!RemoteDuplicates.Same(group.Items,await CandidatesAsync(group.Relative,ct)))throw new CloudConflictException(group.Relative,"changed");
                var extra=Extras[group.Relative];var preserved=group.Relative+".SafeSync-conflict-extra";await Inner.SeedAsync(preserved,extra.Text,extra.Item.ModifiedUtc);
                Inner.Files[preserved]=extra.Item with{Name=RemotePath.Name(preserved)};Preserved.Add(extra);Extras.Remove(group.Relative);
            }
        }
        public Task EnsureFolderAsync(string path,CancellationToken ct)=>Inner.EnsureFolderAsync(path,ct);
        public Task<RemoteItem> UploadAsync(UploadSnapshot s,string path,UploadSession session,Action save,PauseGate pause,CancellationToken ct)=>Inner.UploadAsync(s,path,session,save,pause,ct);
        public Task<RemoteItem> MoveAsync(string from,string to,CancellationToken ct)=>Inner.MoveAsync(from,to,ct);
        public Task DownloadAsync(string path,string local,CancellationToken ct)=>Inner.DownloadAsync(path,local,ct);
        public Task DeleteAsync(string path,CancellationToken ct)=>Inner.DeleteAsync(path,ct);
    }
}
