namespace SafeSync.Core;

public static class ChangePlanner
{
    public static void Add(string root,IEnumerable<string> changes,IReadOnlyDictionary<string,FileEntry> known,ISet<string> pending,CancellationToken token,Action? boundary=null)
    {
        var directories=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var path in changes.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            boundary?.Invoke();token.ThrowIfCancellationRequested();var relative=PathPolicy.Relative(path);if(PathPolicy.Internal(relative))continue;
            pending.Add(relative);
            // Existing snapshot entries are files: avoid a NAS directory query
            // and an O(snapshot size) prefix scan for every changed file.
            if(known.ContainsKey(relative))continue;
            var source=PathPolicy.Combine(root,relative);directories.Add(relative);
            if(Directory.Exists(source))foreach(var file in FileTree.Scan(source,token,_=>boundary?.Invoke())){boundary?.Invoke();pending.Add(PathPolicy.Relative(Path.GetRelativePath(root,file.FullName)));}
        }
        if(directories.Count==0)return;
        foreach(var relative in known.Keys)
        {
            boundary?.Invoke();
            var ancestor=relative;int slash;
            while((slash=ancestor.LastIndexOf('/'))>=0)
            {
                ancestor=ancestor[..slash];if(directories.Contains(ancestor)){pending.Add(relative);break;}
            }
        }
    }
}
