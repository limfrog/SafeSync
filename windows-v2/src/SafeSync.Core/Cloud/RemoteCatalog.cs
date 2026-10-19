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
    }
    private readonly string path,identity,scope;
    private readonly IRemoteStore remote;
    public Data State {get;private set;}=new();
    public RemoteCatalog(ConfigStore store,IRemoteStore remote,string scope="")
    {
        this.remote=remote;this.scope=scope;identity=remote.Provider+"|"+remote.AccountId+"|"+remote.Root+"|"+scope;
        var key=Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));path=Path.Combine(store.Root,"remote-catalogs",key+".json");
        if(File.Exists(path)){var saved=JsonFile.Read<Data>(path);if(saved.Identity==identity){saved.Items=new(saved.Items,StringComparer.OrdinalIgnoreCase);State=saved;}}
    }
    private bool InScope(string relative)=>scope.Length==0 ? !PathPolicy.Internal(relative) : relative.Equals(scope,StringComparison.OrdinalIgnoreCase)||relative.StartsWith(scope+"/",StringComparison.OrdinalIgnoreCase);
    private async Task AddTreeAsync(string folder,Dictionary<string,RemoteItem> index,PauseGate pause,CancellationToken token)
    {
        var folders=new Stack<string>();folders.Push(folder);
        while(folders.TryPop(out var directory))
        {
            await pause.WaitAsync(token);var names=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach(var item in await remote.ListAsync(directory,token))
            {
                if(!names.Add(item.Name))throw new IOException("클라우드에 중복 이름이 있습니다: "+directory+"/"+item.Name);
                var relative=directory.Length==0 ? PathPolicy.Relative(item.Name) : directory+"/"+PathPolicy.Relative(item.Name);
                if(!InScope(relative))continue;index[relative]=item;if(item.Folder)folders.Push(relative);
            }
        }
    }
    public async Task RefreshAsync(bool force,PauseGate pause,CancellationToken token)
    {
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
        string cursor;
        if(full)
        {
            cursor=feed!=null ? await feed.CaptureCursorAsync(token) : "";index.Clear();
            if(scope.Length==0 || (await remote.StatAsync(scope,token))?.Folder==true)await AddTreeAsync(scope,index,pause,token);
            foreach(var key in State.Items.Keys.Concat(index.Keys))pending.Add(key);
        }
        else
        {
            cursor=delta!.Cursor;
            foreach(var changed in delta.Paths.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var relative=PathPolicy.Relative(changed);if(!InScope(relative))continue;
                var prior=index.Keys.Where(k=>k.Equals(relative,StringComparison.OrdinalIgnoreCase)||k.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase)).ToArray();
                foreach(var old in prior){index.Remove(old);pending.Add(old);}pending.Add(relative);
                var item=await remote.StatAsync(relative,token);if(item==null)continue;index[relative]=item;
                if(item.Folder){await AddTreeAsync(relative,index,pause,token);foreach(var key in index.Keys.Where(k=>k.StartsWith(relative+"/",StringComparison.OrdinalIgnoreCase)))pending.Add(key);}
            }
        }
        var next=new Data {Identity=identity,Cursor=cursor,Items=index,Pending=pending.ToList()};JsonFile.Save(path,next);State=next;
    }
    public void Acknowledge(){if(State.Pending.Count==0)return;State.Pending.Clear();JsonFile.Save(path,State);}
    public void Update(string relative,RemoteItem? item){if(item==null)State.Items.Remove(relative);else State.Items[relative]=item;}
    public void Save()=>JsonFile.Save(path,State);
    public void Invalidate(){State.Cursor="";Save();}
}
