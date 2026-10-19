namespace SafeSync.Core.Cloud;

public static class CloudFolders
{
    public static string ChildPath(string parent,string name)
    {
        parent=RemotePath.Normalize(parent);name=name.Trim();
        if(name.Contains('/') || name.Contains('\\'))throw new InvalidDataException("폴더 이름만 입력하세요. 경로 구분자는 사용할 수 없습니다.");
        name=PathPolicy.Relative(name);
        if(PathPolicy.Internal(name))throw new InvalidDataException("SafeSync 내부 보관용 이름은 사용할 수 없습니다.");
        return parent.Length==0 ? name : parent+"/"+name;
    }
    public static async Task<string> CreateAsync(IRemoteStore remote,string parent,string name,CancellationToken token)
    {
        var path=ChildPath(parent,name);var gate=CloudBackupEngine.ScopeGate(remote);await gate.WaitAsync(token);
        try
        {
            if(await remote.StatAsync(path,token)!=null)throw new IOException("같은 이름의 파일이나 폴더가 이미 있습니다. 다른 이름을 입력하세요.");
            await remote.EnsureFolderAsync(path,token);
            if((await remote.StatAsync(path,token))?.Folder!=true)throw new IOException("새 폴더 생성을 확인하지 못했습니다. 새로고침 후 확인하세요.");
            return path;
        }
        finally{gate.Release();}
    }
}
