using System.Security.Cryptography;
using System.Text;

namespace SafeSync.Core;

public sealed class TrashListCache<T>
{
    private readonly string path;
    public TrashListCache(ConfigStore store,BackupJob job)
    {
        var identity=job.DestinationType+"|"+job.Destination+"|"+job.CloudFolderId+"|"+job.CloudAccountId;
        path=Path.Combine(store.Root,"trash-lists",Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))+".json");
    }
    public List<T> Read()
    {
        try{return File.Exists(path) ? JsonFile.Read<List<T>>(path) : [];}
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException){return [];}
    }
    public void Save(IEnumerable<T> items)=>JsonFile.Save(path,items.ToList());
}
