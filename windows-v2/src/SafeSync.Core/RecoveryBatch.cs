using System.Text.RegularExpressions;
namespace SafeSync.Core;

public sealed class RecoveryBatch : IDisposable
{
    private static readonly AsyncLocal<string?> current=new();
    private readonly string? prior=current.Value;
    public static string? Id=>current.Value;
    public RecoveryBatch(){current.Value=DateTime.Now.ToString("yyyyMMdd-HHmmssfff")+"-run-"+Guid.NewGuid().ToString("N");}
    public static string Folder(string reason)=> (Id ?? DateTime.Now.ToString("yyyyMMdd-HHmmssfff"))+"-"+reason+"-"+Guid.NewGuid().ToString("N")[..8];
    public static string FromPath(string path)
    {
        var parts=path.Replace('\\','/').Split('/');var index=Array.FindIndex(parts,p=>p.Equals(".safesync-trash",StringComparison.OrdinalIgnoreCase));
        if(index<0 || index+1>=parts.Length)return "";
        var folder=parts[index+1];var match=Regex.Match(folder,@"^\d{8}-\d{9}-run-[a-f0-9]{32}");return match.Success ? match.Value : folder;
    }
    public void Dispose()=>current.Value=prior;
}
