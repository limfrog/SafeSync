using System;
using System.IO;
using System.Linq;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private BackupJob? PrepareCloudJob(BackupJob job,bool force=false)
    {
        if(job.DestinationType=="Local" || (!force && !CloudJobBinding.NeedsReview(config,job)))return job;
        if(scheduler.IsRunning(job.Id)){Tell("현재 파일 처리가 끝난 뒤 클라우드 위치를 다시 연결하세요.");return null;}
        var account=CloudAccounts.Read(config).For(job.DestinationType);
        if(account.RefreshTokenProtected.Length==0 || account.AccountId.Length==0)
        {Tell("환경설정의 클라우드 계정에서 먼저 로그인한 뒤, ‘작업 → 클라우드 위치 다시 연결’을 선택하세요.");return null;}
        if(job.DestinationType=="GoogleDrive" && account.AccessMode!=GoogleFileAccess.Mode){Tell("환경설정에서 Google Drive를 제한 권한으로 다시 연결한 뒤 전용 백업 폴더를 선택하세요.");return null;}
        if(job.DestinationType=="GoogleDrive" && !Confirm("Google Drive 제한 권한 작업은 새 전용 폴더에 단방향 백업합니다. 이전 백업은 보존되며 이전 폴더 전체를 그대로 인계하지 않습니다. 이 방식으로 이전할까요?"))return null;
        var text=$"'{job.Name}'의 클라우드 계정 또는 백업 폴더를 다시 확인합니다.\n\n기존 위치: {job.Destination}\n현재 연결 계정: {account.AccountName}\n\n사용할 폴더를 직접 선택한 뒤 확인하면 새 기준으로 비교합니다. 기존 스냅샷과 미완료 전송 기록은 보존하고 새 위치에 재사용하지 않습니다. 첫 비교에서는 이전 기록에 따른 삭제를 전파하지 않습니다.\n\n계속해서 백업 폴더를 선택할까요?";
        if(MessageWindow(text,"클라우드 위치 다시 연결",true).ShowDialog()!=true)return null;
        var choice=ChooseCloudFolder(job.DestinationType,Main);if(choice==null)return null;
        if(!Confirm($"'{job.Name}'의 백업 위치를 아래와 같이 연결할까요?\n\n{choice.Display}\n\n{(job.SyncMode=="TwoWay" ? "양방향 첫 실행은 양쪽 파일을 합치고, 서로 다른 내용은 충돌로 남깁니다." : "원본을 새 위치와 비교하고 서로 다른 파일은 기존 충돌·덮어쓰기 규칙을 적용합니다.")}\n기존 파일을 모두 무조건 덮어쓰는 동작은 하지 않습니다."))return null;
        try
        {
            var replacement=CloudJobBinding.Rebind(config,job,choice.Reference,choice.Display,choice.AccountId,choice.FolderIdentity);
            var old=config.Jobs;var revised=old.Select(j=>j.Id==job.Id ? replacement : j).ToList();
            if(File.Exists(store.ConfigPath))File.Copy(store.ConfigPath,store.ConfigPath+".before-rebind-"+Guid.NewGuid().ToString("N"));
            config.Jobs=revised;try{store.Save(config);}catch{config.Jobs=old;throw;}
            RefreshJobs();Jobs.SelectedItem=replacement;scheduler.SetJobs(jobs);
            ReplaceRecoveryJob(job.Id,replacement);
            Log(job.Name+": 확인한 클라우드 폴더로 다시 연결했습니다. 이전 스냅샷·전송 기록은 보존하며 새 기준으로 비교합니다.");return replacement;
        }
        catch(Exception ex){Tell(ex.Message,"클라우드 다시 연결 실패");return null;}
    }
}
