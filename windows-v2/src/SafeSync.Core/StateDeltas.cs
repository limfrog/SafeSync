namespace SafeSync.Core;

// Base snapshot replacement activates a new generation before old deltas are
// removed. A crash at either boundary cannot apply an obsolete delta twice.
public static class StateDeltas
{
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string,object> Gates=new(StringComparer.OrdinalIgnoreCase);
    private static object Gate(string path)=>Gates.GetOrAdd(Path.GetFullPath(path),_=>new());
    public sealed class Delta
    {
        public string Generation {get;set;}="";
        public List<FileEntry> Entries {get;set;}=[];
        public List<string> Removed {get;set;}=[];
        public List<string> Completed {get;set;}=[];
    }
    public static JobState Load(string path)
    {
        lock(Gate(path))
        {
        var state=JsonFile.Read<JobState>(path);var folder=path+".native-deltas";
        if(!Directory.Exists(folder))return state;
        var entries=state.Files.ToDictionary(e=>PathPolicy.Relative(e.RelativePath),StringComparer.OrdinalIgnoreCase);
        var pending=state.PendingPaths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach(var file in Directory.EnumerateFiles(folder,"*.json").Order(StringComparer.Ordinal))
        {
            PathPolicy.RejectLinks(Path.GetDirectoryName(path)!,file);
            var delta=JsonFile.Read<Delta>(file);if(delta.Generation!=state.Generation)continue;
            foreach(var entry in delta.Entries)entries[PathPolicy.Relative(entry.RelativePath)]=entry;
            foreach(var removed in delta.Removed)entries.Remove(PathPolicy.Relative(removed));
            foreach(var completed in delta.Completed)pending.Remove(PathPolicy.Relative(completed));
        }
        state.Files=entries.Values.ToList();state.PendingPaths=pending.ToList();state.CheckpointActive=pending.Count>0;return state;
        }
    }
    public static void Append(string path,JobState state,IReadOnlyDictionary<string,FileEntry> entries,ISet<string> pending,IEnumerable<string> paths)
    {
        lock(Gate(path))
        {
        var delta=new Delta {Generation=state.Generation};
        foreach(var relative in paths.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            PathPolicy.Relative(relative);
            if(entries.TryGetValue(relative,out var entry))delta.Entries.Add(entry);else delta.Removed.Add(relative);
            if(!pending.Contains(relative))delta.Completed.Add(relative);
        }
        var folder=path+".native-deltas";
        JsonFile.Save(Path.Combine(folder,DateTime.UtcNow.Ticks.ToString("D19")+"-"+Guid.NewGuid().ToString("N")+".json"),delta);
        }
    }
    public static void Save(string path,JobState state)
    {
        lock(Gate(path))
        {
        // Old extension data must not serialize a second Generation property
        // over the new generation, otherwise completed deltas may be replayed.
        if(state.Extra!=null)foreach(var key in state.Extra.Keys.Where(k=>k.Equals("Generation",StringComparison.OrdinalIgnoreCase)).ToArray())state.Extra.Remove(key);
        state.Generation=Guid.NewGuid().ToString("N");JsonFile.Save(path,state);
        var folder=path+".native-deltas";
        if(Directory.Exists(folder))foreach(var file in Directory.EnumerateFiles(folder,"*.json"))File.Delete(file);
        }
    }
}
