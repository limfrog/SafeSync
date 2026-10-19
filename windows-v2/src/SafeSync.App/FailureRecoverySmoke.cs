using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task<int> TestFailureRecoveryAsync(string? previewDirectory)
    {
        int assertions=0;void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;Theme.Apply(Main,mode);noticeLedger.Dismiss(noticeLedger.Entries.ToArray());notices.Clear();followLatest=true;
            var job=new BackupJob {Name="Recent Backup · 복구 검사",Source=Path.Combine(store.Root,"smoke-source"),DestinationType="GoogleDrive",Destination="Google Drive / Backup",CloudFolderId="synthetic-folder",CloudAccountId="synthetic-account"};
            config.Jobs=[job];RefreshJobs();var error=new IOException("클라우드에 중복 이름이 있습니다: 프로젝트/._Melody.zip");OnFailed(job,error);
            Check(Main.FindName("ResolveJobButton")==null && Main.Find<MenuItem>("ResolveJobMenuItem").IsEnabled,"Failed job did not offer a visible recovery action");
            ShowProgress();var progressView=progressWindow!;Check(progressView.Find<WrapPanel>("ResultRecoveryActions").Visibility==Visibility.Visible && progressView.Find<Button>("ResultRetryButton").IsEnabled,"Failed progress result ended without recovery/retry actions");
            progressView.Find<Button>("ResultResolveButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var window=recoveryPanels.Single(p=>p.Value.Job.Id==job.Id).Key;window.UpdateLayout();
            Check(Main.IsEnabled && Window.GetWindow(window)==Main && progressView.Find<TabItem>("ProblemTab").IsSelected && window.Find<TextBlock>("RecoveryTitle").Text.Contains("이름이 같은"),"Recovery panel is not in the lower progress area or omitted actual cause");
            Check(window.Find<TextBox>("RecoveryError").Text.Contains("._Melody.zip") && window.Find<Button>("RecoveryRebindButton").Visibility==Visibility.Visible && window.Find<Button>("RecoveryOpenButton").IsEnabled,"Recovery omitted error details or cloud repair options");
            ShowNotices();var messageView=messagesWindow!;Check(messageView.Find<Button>("ResolveMessageButton").IsEnabled,"Notice browser did not link to recovery");
            messageView.Find<Button>("ClearMessagesButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));messageView.Close();
            OnFailed(job,error);
            ShowJobRecovery(job);
            window=recoveryPanels.Single(p=>p.Value.Job.Id==job.Id).Key;
            Check(notices.Count==0 && problemStore.Get(job.Id)!=null && new JobProblemStore(store.Root).Get(job.Id)!=null,"Dismissed global failure reappeared or lost recovery guidance");
            window.Find<Button>("RecoveryWaitButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(job.Stopped && !job.Paused && job.Status=="대기 중" && window.Find<Button>("RecoveryRetryButton").IsEnabled,"Wait action was not a resumable, non-paused stopped state");
            if(previewDirectory!=null)
            {
                Main.UpdateLayout();var bmp=new RenderTargetBitmap((int)Math.Ceiling(WorkspaceVisual(progressView).ActualWidth),(int)Math.Ceiling(WorkspaceVisual(progressView).ActualHeight),96,96,PixelFormats.Pbgra32);bmp.Render(WorkspaceVisual(progressView));var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bmp));using var output=File.Create(Path.Combine(previewDirectory,"FailureRecovery-"+mode+".png"));png.Save(output);
            }
            Main.Width=720;Main.Height=600;Main.UpdateLayout();
            Check(problemPanel!.Find<ScrollViewer>("ComparisonDetailsScroll").ActualHeight>0,"Compact recovery panel has no scrollable details area");
            Main.Width=800;Main.Height=540;Main.UpdateLayout();await Main.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            var viewport=Main;
            Check(Main.Find<TextBlock>("FooterText").TransformToAncestor(viewport).TransformBounds(new Rect(Main.Find<TextBlock>("FooterText").RenderSize)).Bottom<=viewport.ActualHeight+1,"Visible recovery button pushed main status bar outside compact window");
            var failedRun=sessionHistory.Runs.First();job.Stopped=false;OnStarted(job);OnCompleted(job,new BackupResult {Skipped=1});
            progressView.Find<DataGrid>("HistoryGrid").SelectedItem=failedRun;RefreshProgress();
            Check(progressView.Find<WrapPanel>("ResultRecoveryActions").Visibility==Visibility.Collapsed,"Old failed history allowed stale job recovery/retry");
            Check(problemStore.Get(job.Id)==null && Main.FindName("ResolveJobButton")==null,"Successful job retained failure badge");
            Check(BackupLocationTarget(job)=="https://drive.google.com/drive/folders/synthetic-folder","Cloud repair link opened an unexpected endpoint");
            ClearProblemWorkspace();progressView.Find<TabControl>("ProgressTabs").SelectedIndex=0;Main.Width=1180;Main.Height=800;Main.Width=1180;Main.Height=720;
        }
        // Exercise the actual app retry handler, scheduler and completion events
        // against an isolated local fixture; never acquire the live app's lease.
        var home=Path.Combine(store.Root,"recovery-retry");var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(backup);
        var retryJob=new BackupJob {Name="로컬 복구 재시도 검사",Source=source,Destination=backup,Paused=true};config.Jobs=[retryJob];RefreshJobs();OnFailed(retryJob,new DirectoryNotFoundException("원본 폴더 연결 확인 필요"));ShowJobRecovery(retryJob);
        var retryWindow=recoveryPanels.Single(p=>p.Value.Job.Id==retryJob.Id).Key;
        Check(retryWindow.Find<Button>("RecoveryAccountsButton").Visibility==Visibility.Collapsed && retryWindow.Find<Button>("RecoveryRebindButton").Visibility==Visibility.Collapsed,"Local failure offered cloud-only options");
        retryWindow.Find<Button>("RecoveryWaitButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Directory.CreateDirectory(source);File.WriteAllText(Path.Combine(source,"recovered.txt"),"safe recovery");
        var lease=scheduler.AcquireRunLease;scheduler.AcquireRunLease=null;
        try
        {
            retryWindow.Find<Button>("RecoveryRetryButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            for(int i=0;i<250 && (scheduler.IsRunning(retryJob.Id) || problemStore.Get(retryJob.Id)!=null);i++)await Task.Delay(20);
            Check(File.Exists(Path.Combine(backup,"recovered.txt")) && File.ReadAllText(Path.Combine(backup,"recovered.txt"))=="safe recovery","Recovery retry did not perform the pending backup");
            Check(!retryJob.Stopped && !retryJob.Paused && retryJob.Status=="완료" && problemStore.Get(retryJob.Id)==null,"Retry did not return from failed/waiting state to completed work");
            Check(new JobProblemStore(store.Root).Get(retryJob.Id)==null && !notices.Any(n=>n.Contains("원본 폴더 연결 확인 필요")),"Successful retry retained stale diagnostic/notice");
        }
        finally{scheduler.AcquireRunLease=lease;ClearProblemWorkspace();progressWindow!.Find<TabControl>("ProgressTabs").SelectedIndex=0;}
        return assertions;
    }
}
