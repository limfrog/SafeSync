using System.Security.Cryptography;
using System.Text;

namespace SafeSync.Core.Cloud;

public sealed record RemoteChanges(string Cursor,IReadOnlyList<string> Paths);
public interface IRemoteChanges
{
    Task<string> CaptureCursorAsync(CancellationToken token);
    Task<RemoteChanges> ChangesAsync(string cursor,IReadOnlyDictionary<string,RemoteItem> known,CancellationToken token);
}
public interface IRemoteBatch
{
    Task<IReadOnlyDictionary<string,RemoteItem?>> StatManyAsync(IReadOnlyDictionary<string,RemoteItem> known,IEnumerable<string> paths,CancellationToken token);
}
public interface IRemoteParallel { }

// Cursor and unconsumed paths commit together. The backup snapshot must first
// contain these paths before Acknowledge is called, including on cancellation.
public sealed class RemoteCatalog
{
    public sealed class Data
    {
        public string Identity {get;set;}="";
        public string Cursor {get;set;}="";
        public Dictionary<string,RemoteItem> Items {get;set;}=new(StringComparer.OrdinalIgnoreCase);
        public List<string> Pending {get;set;}=[];
        public List<string> Ambiguous {get;set;}=[];
        public Dictionary<string,string[]> DuplicateFolderIds {get;set;}=new(StringComparer.OrdinalIgnoreCase);
        // A duplicate name remains ambiguous until the user normalizes it, but
        // identical physical copies do not need to be hashed on every remote
        // poll. The signature is invalidated by any related change-feed path
        // or an explicit full refresh.
        public Dictionary<string,string> StableAmbiguous {get;set;}=new(StringComparer.OrdinalIgnoreCase);
    }
    private readonly string path,identity,scope;
    private readonly object stableLock=new();
    private readonly IRemoteStore remote;
    public Data State {get;private set;}=new();
    public RemoteCatalog(ConfigStore store,IRemoteStore remote,string scope="")
    {
        this.remote=remote;this.scope=scope;identity=remote.Provider+"|"+remote.AccountId+"|"+remote.Root+"|"+scope;
        var key=Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));path=Path.Combine(store.Root,"remote-catalogs",key+".json");
        if(File.Exists(path)){var saved=JsonFile.Read<Data>(path);if(saved.Identity==identity){saved.Items=new(saved.Items,StringComparer.OrdinalIgnoreCase);saved.DuplicateFolderIds=new(saved.DuplicateFolderIds,StringComparer.OrdinalIgnoreCase);saved.StableAmbiguous=new(saved.StableAmbiguous,StringComparer.OrdinalIgnoreCase);State=saved;}}
    }
    private bool InScope(string relative)=>scope.Length==0 ? !PathPolicy.Internal(relative) : relative.Equals(scope,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(scope+"/",StringComparison.OrdinalIgnoreCase);
    public bool IsAmbiguous(string path)=>State.Ambiguous.Any(p=>Related(path,p));
    public bool IsStableAmbiguous(string path)=>State.StableAmbiguous.ContainsKey(path);
    public void TrustAmbiguous(string relative,IReadOnlyList<RemoteItem> candidates)
    {
        relative=PathPolicy.Relative(relative);
        if(candidates.Count<2 || candidates.Any(i=>i.Id.Length==0))return;
        lock(stableLock)
        {
            State.StableAmbiguous[relative]=Signature(candidates);
            State.Items[relative]=candidates.OrderBy(i=>i.Id,StringComparer.Ordinal).First();
            JsonFile.Save(path,State);
        }
    }
    private static string Signature(IEnumerable<RemoteItem> items)
    {
        var value=string.Join("\n",items.OrderBy(i=>i.Id,StringComparer.Ordinal).Select(i=>string.Join("\u001f",i.Id,i.Name,i.Folder,i.Length,i.ModifiedUtc.ToUniversalTime().Ticks,i.CreatedUtc.ToUniversalTime().Ticks,i.Hash,i.Revision,i.Binary,i.Sha256)));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }
    private static bool Related(string a,string b)=>a.Equals(b,StringComparison.OrdinalIgnoreCase)||a.StartsWith(b+"/",StringComparison.OrdinalIgnoreCase)||b.StartsWith(a+"/",StringComparison.OrdinalIgnoreCase);
    private async Task AddTreeAsync(string folder,Dictionary<string,RemoteItem> index,HashSet<string> ambiguous,Dictionary<string,string[]> duplicateFolders,PauseGate pause,CancellationToken token)
    {
        var folders=new Stack<string>();folders.Push(folder);
        while(folders.TryPop(out var directory))
        {
            await pause.WaitAsync(token);pause.ThrowIfStopRequested();
            foreach(var group in (await remote.ListAsync(directory,token)).GroupBy(i=>i.Name,StringComparer.OrdinalIgnoreCase))
            {
                var item=group.First();
                var relative=directory.Length==0 ? PathPolicy.Relative(item.Name) : directory+"/"+PathPolicy.Relative(item.Name);
                if(!InScope(relative))continue;
                if(group.Skip(1).Any()){ambiguous.Add(relative);if(remote is IRemoteDuplicates && group.All(i=>i.Folder)){duplicateFolders[relative]=group.Select(i=>i.Id).Order(StringComparer.Ordinal).ToArray();folders.Push(relative);}continue;}
                index[relative]=item;if(item.Folder)folders.Push(relative);
            }
        }
    }
    public async Task RefreshAsync(bool force,PauseGate pause,CancellationToken token)
    {
        pause.ThrowIfStopRequested();
        var feed=remote as IRemoteChanges;
        bool full=force || State.Identity!=identity || State.Cursor.Length==0 || feed==null;
        RemoteChanges? delta=null;
        if(!full)
        {
            try{delta=await feed!.ChangesAsync(State.Cursor,State.Items,token);}
            catch(CloudApiException ex) when(ex.Status is System.Net.HttpStatusCode.Gone or System.Net.HttpStatusCode.Conflict){full=true;}
        }
        var pending=State.Pending.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var index=new Dictionary<string,RemoteItem>(State.Items,StringComparer.OrdinalIgnoreCase);
        var ambiguous=State.Ambiguous.ToHashSet(StringComparer.OrdinalIgnoreCase);
        var duplicateFolders=new Dictionary<string,string[]>(State.DuplicateFolderIds,StringComparer.OrdinalIgnoreCase);
        var stableAmbiguous=new Dictionary<string,string>(State.StableAmbiguous,StringComparer.OrdinalIgnoreCase);
        string cursor;
        if(full)
        {
            cursor=feed!=null ? await feed.CaptureCursorAsync(token) : "";index.Clear();ambiguous.Clear();duplicateFolders.Clear();stableAmbiguous.Clear();
            if(scope.Length==0 || (await remote.StatAsync(scope,token))?.Folder==true)await AddTreeAsync(scope,index,ambiguous,duplicateFolders,pause,token);
            foreach(var key in State.Items.Keys.Concat(index.Keys))pending.Add(key);
        }
        else
        {
            cursor=delta!.Cursor;
            var traversed=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var changed in delta.Paths.Concat(State.Ambiguous).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(p=>p.Count(c=>c=='/')))
            {
                pause.ThrowIfStopRequested();
                var relative=PathPolicy.Relative(changed);if(!InScope(relative))continue;
                foreach(var key in stableAmbiguous.Keys.Where(p=>Related(p,relative)).ToArray())stableAmbiguous.Remove(key);
                if(traversed.Any(p=>relative.StartsWith(p+"/",StringComparison.OrdinalIgnoreCase)))continue;
                // A stable ambiguous folder must not trigger a whole subtree
                // scan every minute. Validate its physical IDs; feed changes
                // inside the subtree still force a refresh, including deletion.
                if(!delta.Paths.Any(p=>Related(p,relative)) && duplicateFolders.TryGetValue(relative,out var ids) && remote is IRemoteDuplicates stable)
                {
                    var copies=await stable.CandidatesAsync(relative,token);
                    if(copies.All(i=>i.Folder) && ids.SequenceEqual(copies.Select(i=>i.Id).Order(StringComparer.Ordinal)))
                    {traversed.Add(relative);continue;}
                }
                var prior=index.Keys.Where(k=>k.Equals(relative,StringComparison.OrdinalIgnoreCase)||k.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase)).ToArray();
                foreach(var old in prior){index.Remove(old);pending.Add(old);}pending.Add(relative);
                ambiguous.RemoveWhere(p=>p.Equals(relative,StringComparison.OrdinalIgnoreCase)||p.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase));
                foreach(var key in duplicateFolders.Keys.Where(p=>p.Equals(relative,StringComparison.OrdinalIgnoreCase)||p.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase)).ToArray())duplicateFolders.Remove(key);
                try
                {
                    var item=await remote.StatAsync(relative,token);if(item==null)continue;index[relative]=item;
                    if(item.Folder){await AddTreeAsync(relative,index,ambiguous,duplicateFolders,pause,token);foreach(var key in index.Keys.Where(k=>k.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase)))pending.Add(key);}
                }
                catch(CloudDuplicateNameException ex)
                {
                    var conflict=PathPolicy.Relative(ex.RelativePath);ambiguous.Add(conflict);
                    foreach(var key in index.Keys.Where(k=>k.Equals(conflict,StringComparison.OrdinalIgnoreCase)||k.StartsWith(conflict+"/",StringComparison.OrdinalIgnoreCase)).ToArray()){index.Remove(key);pending.Add(key);}
                    if(remote is IRemoteDuplicates duplicates && (await duplicates.CandidatesAsync(conflict,token)) is {Count:>0} copies && copies.All(i=>i.Folder))
                    {
                        duplicateFolders[conflict]=copies.Select(i=>i.Id).Order(StringComparer.Ordinal).ToArray();
                        await AddTreeAsync(conflict,index,ambiguous,duplicateFolders,pause,token);traversed.Add(conflict);
                        foreach(var key in index.Keys.Where(k=>k.StartsWith(conflict+"/",StringComparison.OrdinalIgnoreCase)))pending.Add(key);
                    }
                }
            }
        }
        foreach(var conflict in ambiguous)if(!stableAmbiguous.ContainsKey(conflict))pending.Add(conflict);
        var next=new Data {Identity=identity,Cursor=cursor,Items=index,Pending=pending.ToList(),Ambiguous=ambiguous.ToList(),DuplicateFolderIds=duplicateFolders,StableAmbiguous=stableAmbiguous};JsonFile.Save(path,next);State=next;
    }
    public void Acknowledge(){if(State.Pending.Count==0)return;State.Pending.Clear();JsonFile.Save(path,State);}
    public void Update(string relative,RemoteItem? item){if(item==null)State.Items.Remove(relative);else State.Items[relative]=item;}
    public void Save()=>JsonFile.Save(path,State);
    public void Invalidate(){State.Cursor="";Save();}
}
