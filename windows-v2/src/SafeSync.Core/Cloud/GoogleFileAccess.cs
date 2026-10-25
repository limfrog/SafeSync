namespace SafeSync.Core.Cloud;

// A folder grant is not recursive file authorization. Restricted-mode jobs
// therefore start a new one-way baseline in an app-created folder only.
public static class GoogleFileAccess
{
    public const string Scope="https://www.googleapis.com/auth/drive.file";
    public const string Mode="drive-file-v1";
    public const string FolderKey="safesyncAccess";
    public static void ValidateScope(string scope)
    {
        var scopes=scope.Split(' ',StringSplitOptions.RemoveEmptyEntries);
        if(scopes.Length!=1 || scopes[0]!=Scope)
            throw new CloudBindingException("Google Drive 제한 권한을 확인하지 못했습니다. Google 계정의 기존 SafeSync 접근 권한을 해제한 뒤 다시 연결하세요.");
    }
    public static void ValidateAccount(CloudAccount account)
    {
        if(account.AccessMode!=Mode)throw new CloudBindingException("Google Drive 연결 방식이 변경되었습니다. 환경설정에서 계정을 제한 권한으로 다시 연결하세요. 기존 백업은 보존됩니다.");
    }
    public static void ValidateJob(CloudAccount account,BackupJob job)
    {
        ValidateAccount(account);
        if(job.CloudAccessMode!=Mode)throw new CloudBindingException("이전 Google Drive 작업은 새 전용 백업 폴더로 다시 연결해야 합니다. 이전 백업과 스냅샷은 보존됩니다.");
        if(job.SyncMode!="OneWay")throw new CloudBindingException("Google Drive API 제한 권한은 단방향 백업만 지원합니다. 양방향은 Google Drive 데스크톱 폴더를 로컬 위치로 지정하세요.");
    }
}
