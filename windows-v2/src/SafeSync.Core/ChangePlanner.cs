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
            // A changed tracked file may now be a directory, and old versions
            // could persist directory events as bogus file conflicts. Inspect
            // the current kind instead of trusting that stale snapshot kind.
            // Keep the directory itself for file/folder collision checks; its
            // children, not the directory, are the file copy/deletion work.
            var source=PathPolicy.Combine(root,relative);bool directory=Directory.Exists(source);
            if(!directory && known.ContainsKey(relative))continue;
            directories.Add(relative);
            if(directory)foreach(var file in FileTree.Scan(source,token,_=>boundary?.Invoke())){boundary?.Invoke();pending.Add(PathPolicy.Relative(Path.GetRelativePath(root,file.FullName)));}
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
