using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SafeSync.Core.Cloud;
namespace SafeSync.Core;

public sealed record MassChange(string Path,string Side,string Action,string Before,string After);
public sealed record MassChangeProposal(string JobId,string Binding,string Fingerprint,int Baseline,DateTime CreatedUtc,MassChange[] Changes);
public sealed class MassChangeException(int count,int baseline) : IOException($"대량 변경 보호: 기존 {baseline:N0}개 중 {count:N0}개의 변경·삭제를 보류했습니다. 작업 관리의 ‘대량 변경 검토’에서 목록을 확인하고 이번 변경을 허용할 수 있습니다.");

public static class MassChanges
{
    private static string PathFor(ConfigStore store,BackupJob job,string suffix)
    {ConfigStore.ValidateId(job.Id);return Path.Combine(store.Root,"mass-change",job.Id+suffix+".json");}
    private static string Binding(BackupJob j)=>JsonSerializer.Serialize(new{j.Id,j.Source,j.Destination,j.DestinationType,j.SyncMode,j.CloudAccountId,j.CloudFolderId,j.CloudFolderIdentity,j.MirrorDeletes,j.MassChangeMinimum,j.MassChangePercent});
    public static MassChangeProposal? Pending(ConfigStore store,BackupJob job)
    {
        var path=PathFor(store,job,"");if(!File.Exists(path))return null;var proposal=JsonFile.Read<MassChangeProposal>(path);
        return proposal.JobId==job.Id && proposal.Binding==Binding(job) ? proposal : null;
    }
    public static void Approve(ConfigStore store,BackupJob job,string fingerprint)
    {
        var pending=Pending(store,job) ?? throw new IOException("검토할 대량 변경 기록이 없습니다.");
        if(pending.Fingerprint!=fingerprint)throw new IOException("검토 중 변경 목록이 달라졌습니다. 다시 확인하세요.");
        JsonFile.Save(PathFor(store,job,"-approval"),pending);
    }
    private static string Local(string root,string relative)
    {
        var path=PathPolicy.Combine(root,relative);PathPolicy.RejectLinks(root,path);
        if(Directory.Exists(path))return "folder";
        var item=new FileInfo(path);item.Refresh();
        return item.Exists ? $"{item.Length}|{item.LastWriteTimeUtc:O}|{item.CreationTimeUtc:O}" : "missing";
    }
    private static string Stamp(long length,string modified,string created)=>$"{length}|{modified}|{created}";
    public static void Check(ConfigStore store,BackupJob job,JobState state,IEnumerable<string> paths,IReadOnlyDictionary<string,RemoteItem>? remote=null)
    {
        if(!job.ProtectMassChanges)return;
        if(job.MassChangeMinimum<1 || job.MassChangePercent is <1 or >100)throw new InvalidDataException("대량 변경 보호 기준을 확인하세요.");
        var prior=state.Files.Where(f=>f.Status=="BackedUp" && f.Length>=0).ToDictionary(f=>f.RelativePath,StringComparer.OrdinalIgnoreCase);
        var candidates=paths.Where(prior.ContainsKey).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        if(prior.Count<job.MassChangeMinimum || candidates.Length<job.MassChangeMinimum){ClearIfSafe();return;}
        var changes=new List<MassChange>();
        foreach(var path in candidates)
        {
            var old=prior[path];var before=old.SyncSource is {} a ? Stamp(a.Length,a.Modified,a.Created) : Stamp(old.Length,old.LastWriteTimeUtc,old.CreationTimeUtc);
            var now=Local(job.Source,path);
            if(now!=before && now!="folder" && (now!="missing" || job.MirrorDeletes || job.SyncMode=="TwoWay"))changes.Add(new(path,"원본",now=="missing" ? "삭제" : "변경",before,now));
            if(job.SyncMode!="TwoWay" || old.SyncBackup is not {} b)continue;
            before=Stamp(b.Length,b.Modified,b.Created);
            now=job.DestinationType=="Local" ? Local(job.Destination,path) : remote?.GetValueOrDefault(path) is {} item ? Stamp(item.Length,item.ModifiedUtc.ToString("O"),item.CreatedUtc.ToString("O"))+"|"+item.Id+"|"+item.Hash : "missing";
            var expected=job.DestinationType=="Local" ? before : before+"|"+b.Identity+"|"+b.Hash;
            if(now!=expected && now!="folder")changes.Add(new(path,"백업",now=="missing" ? "삭제" : "변경",expected,now));
        }
        var count=changes.Select(c=>c.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        if(count<job.MassChangeMinimum || (long)count*100<(long)prior.Count*job.MassChangePercent){ClearIfSafe();return;}
        changes=changes.OrderBy(c=>c.Path,StringComparer.OrdinalIgnoreCase).ThenBy(c=>c.Side).ToList();
        var binding=Binding(job);var roots=state.OneWaySourceIdentity+"|"+state.OneWayBackupIdentity+"|"+state.SyncSourceIdentity+"|"+state.SyncBackupIdentity+"|"+state.CloudFolderIdentity;
        var fingerprint=Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(binding+roots+JsonSerializer.Serialize(changes))));
        var proposal=new MassChangeProposal(job.Id,binding,fingerprint,prior.Count,DateTime.UtcNow,changes.ToArray());
        var approval=PathFor(store,job,"-approval");
        if(File.Exists(approval))
        {
            var allowed=JsonFile.Read<MassChangeProposal>(approval);File.Delete(approval);
            if(allowed.JobId==job.Id && allowed.Binding==binding && allowed.Fingerprint==fingerprint){ClearIfSafe();return;}
        }
        JsonFile.Save(PathFor(store,job,""),proposal);
        state.PendingPaths=state.PendingPaths.Concat(paths).Distinct(StringComparer.OrdinalIgnoreCase).ToList();state.FullScanRequired=true;store.SaveState(state);
        throw new MassChangeException(count,prior.Count);
        void ClearIfSafe(){foreach(var suffix in new[]{"","-approval"}){var file=PathFor(store,job,suffix);if(File.Exists(file))File.Delete(file);}}
    }
}
