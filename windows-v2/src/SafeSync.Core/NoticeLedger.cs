namespace SafeSync.Core;

public sealed record NoticeEntry(string JobId,string File,string Kind,string Message);
public sealed class NoticeLedger
{
    private readonly string path;
    private readonly Dictionary<string,NoticeEntry> entries=new(StringComparer.OrdinalIgnoreCase);
    public IReadOnlyCollection<NoticeEntry> Entries=>entries.Values;
    public NoticeLedger(string root)
    {
        path=Path.Combine(root,"notices-v2.json");
        if(File.Exists(path))foreach(var entry in JsonFile.Read<List<NoticeEntry>>(path))entries[Key(entry)]=entry;
    }
    private static string Key(NoticeEntry e)=>e.JobId+"|"+e.Kind+"|"+(e.File.Length>0 ? e.File.Replace('\\','/') : e.Message);
    public int Apply(string jobId,BackupResult result,JobState? state=null)
    {
        var unresolved=result.Errors.Select(i=>new NoticeEntry(jobId,i.File,"Error",i.Reason))
            .Concat(result.Conflicts.Select(i=>new NoticeEntry(jobId,i.File,"Conflict",i.Reason))).ToArray();
        var keys=unresolved.Select(Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var statuses=state?.Files.ToDictionary(e=>e.RelativePath,e=>e.Status,StringComparer.OrdinalIgnoreCase);
        var resolvedPaths=result.ResolvedPaths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach(var pair in entries.Where(p=>p.Value.JobId==jobId).ToArray())
        {
            var file=pair.Value.File;
            // A canceled/partial execution is not proof that a missing issue was resolved.
            bool resolved=resolvedPaths.Contains(file) || result.Locked.Any(i=>i.File.Equals(file,StringComparison.OrdinalIgnoreCase) && pair.Value.Kind=="Error") || (statuses!=null && file.Length>0 &&
                (!statuses.TryGetValue(file,out var status) || status=="BackedUp" || (status=="Locked" && pair.Value.Kind=="Error")));
            if(resolved || (!result.Canceled && file.Length==0 && !keys.Contains(pair.Key)))entries.Remove(pair.Key);
        }
        int added=0;foreach(var entry in unresolved){if(!entries.ContainsKey(Key(entry)))added++;entries[Key(entry)]=entry;}
        Save();return added;
    }
    public bool Add(string jobId,string message)
    {
        var entry=new NoticeEntry(jobId,"","Error",message);bool added=entries.TryAdd(Key(entry),entry);Save();return added;
    }
    private void Save()=>JsonFile.Save(path,entries.Values.ToList());
}
