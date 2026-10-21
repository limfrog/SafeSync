using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private readonly Dictionary<FrameworkElement,(BackupJob Job,SyncRun? Run,Func<bool> CanRepair)> recoveryPanels=[];
    private void RememberProblem(BackupJob job,JobProblem? problem)
    {try{problemStore.Set(job.Id,problem);}catch(Exception ex){Log("문제 해결 정보 저장 실패: "+ex.Message);}}
    private void RestoreKnownProblems()
    {
        foreach(var job in config.Jobs.Where(j=>problemStore.Get(j.Id)==null))
        {
            var notice=noticeLedger.Entries.Where(e=>e.JobId==job.Id).OrderBy(e=>e.File.Length>0).FirstOrDefault();
            if(notice!=null)RememberProblem(job,JobProblem.Classify(notice.Message,job.DestinationType!="Local",notice.Kind=="Conflict" ? "Conflict" : "",notice.File));
        }
    }
    private void RememberResultProblem(BackupJob job,BackupResult result)
    {
        var issue=result.Errors.FirstOrDefault(i=>!NetworkFailures.Automatic(i)) ?? result.Conflicts.FirstOrDefault() ?? result.Errors.FirstOrDefault();
        if(issue!=null)RememberProblem(job,JobProblem.Classify(issue.Reason,job.DestinationType!="Local",NetworkFailures.Automatic(issue) ? "Network" : result.Conflicts.Contains(issue) ? "Conflict" : "",issue.File));
        else if(!result.Canceled)RememberProblem(job,null);
    }
    private void ReplaceRecoveryJob(string oldId,BackupJob replacement)
    {if(problemRequestedJob?.Id==oldId){ClearProblemWorkspace();ShowJobRecovery(replacement);}RefreshRecoveryWindows();}
    private void RefreshRecoveryWindows()
    {
        foreach(var (window,context) in recoveryPanels.ToArray())
        {
            var job=context.Job;var run=context.Run;var issue=run?.Errors.FirstOrDefault(i=>!NetworkFailures.Automatic(i)) ?? run?.Conflicts.FirstOrDefault() ?? run?.Errors.FirstOrDefault();
            var problem=run==null || sessionHistory.IsLatest(run) ? problemStore.Get(job.Id) : run.FailureReason.Length>0 ? JobProblem.Classify(run.FailureReason,job.DestinationType!="Local",run.AutomaticNetworkRetry ? "Network" : "") : issue!=null ? JobProblem.Classify(issue.Reason,job.DestinationType!="Local",NetworkFailures.Automatic(issue) ? "Network" : run.Conflicts.Contains(issue) ? "Conflict" : "",issue.File) : null;
            bool running=scheduler.IsRunning(job.Id),present=context.CanRepair();
            window.Find<TextBlock>("RecoveryJobName").Text=job.Name;
            window.Find<TextBlock>("RecoveryTitle").Text=problem?.Title ?? (job.Stopped ? "작업을 시작할 준비가 되었습니다" : "최근 실행에서 문제가 해소되었습니다");
            window.Find<TextBlock>("RecoveryGuidance").Text=problem?.Guidance ?? "백업 파일과 스냅샷은 유지됩니다. 필요한 경우 이 작업을 다시 시작할 수 있습니다.";
            window.Find<TextBox>("RecoveryError").Text=problem==null ? "확인된 문제가 없습니다." : (problem.File.Length>0 ? problem.File+Environment.NewLine : "")+problem.Message;
            window.Find<TextBlock>("RecoveryLocations").Text="원본: "+job.Source+Environment.NewLine+"백업: "+job.Destination;
            window.Find<TextBlock>("RecoveryRunStatus").Text=!present ? "작업 설정이 변경된 이전 기록입니다. 현재 작업을 선택하세요." : running && job.Stopped ? "종료 중… 현재 파일을 안전하게 마무리한 뒤 대기합니다." : running ? "현재 작업 실행 중 · 결과를 확인하고 있습니다." : job.Stopped ? "대기 중 · 자동 실행은 멈췄습니다. 다시 시도하면 작업을 시작합니다." : "해결 후 아래 버튼으로 작업을 다시 시작할 수 있습니다.";
            foreach(var name in new[]{"RecoveryRetryButton","RecoveryEditButton"})window.Find<Button>(name).IsEnabled=present && !running;
            window.Find<Button>("RecoveryWaitButton").IsEnabled=present && !job.Stopped;
            foreach(var name in new[]{"RecoveryAccountsButton","RecoveryRebindButton"})window.Find<Button>(name).Visibility=job.DestinationType=="Local" ? Visibility.Collapsed : Visibility.Visible;
            window.Find<Button>("RecoveryAccountsButton").IsEnabled=present && scheduler.RunningCount==0;
            window.Find<Button>("RecoveryRebindButton").IsEnabled=present && !running;
            window.Find<Button>("RecoveryOpenButton").IsEnabled=present;
            window.Find<Button>("RecoveryConflictsButton").IsEnabled=(run?.Conflicts.Count ?? 0)+(run?.Errors.Count ?? 0)>0;
        }
    }
    private void ShowJobRecovery(BackupJob job)
    {
        ShowFileComparison(job,selectedFile:"[작업]");RefreshRecoveryWindows();
    }
    private FrameworkElement CreateRecoveryPanel(BackupJob job,SyncRun? run,Func<bool> canRepair)
    {
        var window=Views.LoadElement("JobRecovery");recoveryPanels[window]=(job,run,canRepair);
        void Repair(Action action,bool idle=true){if(canRepair() && (!idle || !scheduler.IsRunning(job.Id)))action();}
        Click(window,"RecoveryRetryButton",()=>Repair(()=>TrackAuxiliary(RetryProblemAsync(job))));
        Click(window,"RecoveryOpenButton",()=>Repair(()=>OpenBackupLocation(job),false));
        Click(window,"RecoveryAccountsButton",()=>Repair(()=>{if(scheduler.RunningCount==0)ShowCloudAccounts();RefreshRecoveryWindows();}));
        Click(window,"RecoveryRebindButton",()=>Repair(()=>{PrepareCloudJob(job,true);RefreshRecoveryWindows();}));
        Click(window,"RecoveryEditButton",()=>Repair(()=>{EditJob(job);RefreshRecoveryWindows();}));
        Click(window,"RecoveryConflictsButton",()=>
        {
            if(problemPanel?.Find<ListBox>("ComparisonFiles") is {} list)list.SelectedItem=list.Items.OfType<ComparisonRow>().FirstOrDefault(r=>r.IsFile);
        });
        Click(window,"RecoveryWaitButton",()=>
        {
            Repair(()=>{scheduler.StopJob(job);job.Status=scheduler.IsRunning(job.Id) ? "종료 중…" : "대기 중";Save();Jobs.Items.Refresh();RefreshActions();RefreshRecoveryWindows();},false);
        });
        RefreshRecoveryWindows();return window;
    }
    private async Task RetryProblemAsync(BackupJob job)
    {
        if(!jobs.Any(j=>j.Id==job.Id) || scheduler.IsRunning(job.Id))return;
        followLatest=true;RefreshActions();await RunAsync(job);RefreshActions();RefreshRecoveryWindows();
    }
    private static string BackupLocationTarget(BackupJob job)
    {
        if(job.DestinationType=="GoogleDrive")
        {
            if(!Regex.IsMatch(job.CloudFolderId,"^[a-zA-Z0-9_-]{1,200}$"))throw new InvalidDataException("Google Drive 폴더를 다시 선택하세요.");
            return "https://drive.google.com/drive/folders/"+Uri.EscapeDataString(job.CloudFolderId);
        }
        if(job.DestinationType=="Dropbox")
        {
            var path=SafeSync.Core.Cloud.RemotePath.Normalize(job.CloudFolderId.Trim('/'));
            return "https://www.dropbox.com/home"+(path.Length==0 ? "" : "/"+string.Join('/',path.Split('/').Select(Uri.EscapeDataString)));
        }
        return job.Destination;
    }
    private void OpenBackupLocation(BackupJob job)
    {
        try
        {
            var target=BackupLocationTarget(job);
            if(job.DestinationType=="Local")
            {
                if(!Directory.Exists(target)){Tell("백업 폴더에 접근할 수 없습니다. 드라이브·NAS 연결을 확인하거나 작업 설정에서 위치를 선택하세요.");return;}
                Process.Start(new ProcessStartInfo("explorer.exe",Quote(target)){UseShellExecute=true});
            }
            else Process.Start(new ProcessStartInfo(target){UseShellExecute=true});
        }
        catch(Exception ex){Tell(ex.Message,"백업 위치 열기 실패");}
    }
}
