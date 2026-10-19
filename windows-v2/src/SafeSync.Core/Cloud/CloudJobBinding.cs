using System.Text.Json;

namespace SafeSync.Core.Cloud;

public sealed class CloudBindingException(string message) : IOException(message);

public static class CloudJobBinding
{
    public static bool NeedsReview(AppConfig config,BackupJob job)
    {
        if(job.DestinationType=="Local")return false;
        var account=CloudAccounts.Read(config).For(job.DestinationType);
        return job.CloudBindingReviewRequired || job.CloudAccountId.Length==0 || job.CloudAccountId!=account.AccountId;
    }
    // The caller must obtain explicit confirmation of the selected folder.
    // A fresh job ID prevents old baselines, pending deletions or transactions
    // from being replayed against another account/root. Old state is retained.
    public static BackupJob Rebind(AppConfig config,BackupJob previous,string folder,string display,string accountId,string identity)
    {
        if(previous.DestinationType=="Local")throw new InvalidOperationException("클라우드 작업만 다시 연결할 수 있습니다.");
        var account=CloudAccounts.Read(config).For(previous.DestinationType);
        if(accountId.Length==0 || accountId!=account.AccountId || account.RefreshTokenProtected.Length==0)
            throw new CloudBindingException("폴더를 선택한 계정이 현재 연결 계정과 다릅니다. 폴더를 다시 선택하세요.");
        var job=JsonSerializer.Deserialize<BackupJob>(JsonSerializer.Serialize(previous))!;
        job.Id=Guid.NewGuid().ToString("N");job.CloudFolderId=folder;job.Destination=display;
        job.CloudAccountId=accountId;job.CloudFolderIdentity=identity;job.CloudBindingReviewRequired=false;
        job.Stopped=true;job.Paused=false;job.LastScheduledRun="";
        ConfigStore.ValidateJob(job);return job;
    }
}
