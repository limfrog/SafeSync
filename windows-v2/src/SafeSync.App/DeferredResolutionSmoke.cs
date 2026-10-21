using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private int TestNetworkRetryUi()
    {
        int assertions=0;void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;Theme.Apply(Main,mode);
            var job=new BackupJob{Name="네트워크 자동 재시도",Source=Path.Combine(store.Root,"network-ui-"+mode),Destination=Path.Combine(store.Root,"network-backup-"+mode)};
            config.Jobs=[job];RefreshJobs();
            var result=new BackupResult();result.Errors.Add(new(job.Id,job.Name,"offline.txt","예기치 않은 네트워크 오류가 발생했습니다.",0,0,"","",AutomaticNetworkRetry:true));
            OnStarted(job);OnCompleted(job,result);var run=sessionHistory.Latest(job.Id)!;
            var panel=ShowFileComparison(job,run);
            var window=progressWindow!;
            Check(panel.Find<ListBox>("ComparisonFiles").Items.OfType<ComparisonRow>().All(r=>!r.IsFile),"Transient network failure appeared in file decision list");
            Check(!panel.Find<Button>("CompareForwardButton").IsEnabled && !panel.Find<Button>("CompareIgnoreButton").IsEnabled,"Network-only error enabled a manual overwrite or ignore");
            Check(window.Find<DataGrid>("ProgressErrorGrid").Items.OfType<FileIssue>().Single().Handling=="자동 재시도","Network error was removed from error history");
            Check(!window.Find<Button>("CompareErrorsButton").IsEnabled && window.Find<TextBlock>("ProblemTabHeader").Text=="문제 해결 0","Network-only error requires problem resolution");
            Check(!noticeLedger.Entries.Any(e=>e.JobId==job.Id) && job.Status=="네트워크 재시도 대기","Network-only error raised a notice or claimed completion");
            ClearProblemWorkspace();
        }
        return assertions;
    }

    private async Task<int> TestDeferredResolutionUiAsync()
    {
        int assertions=0;void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;Theme.Apply(Main,mode);
            var home=Path.Combine(store.Root,"deferred-ui-"+mode);var source=Path.Combine(home,"source");var backup=Path.Combine(home,"backup");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            File.WriteAllText(Path.Combine(source,"a.txt"),"left");File.SetLastWriteTimeUtc(Path.Combine(source,"a.txt"),DateTime.UtcNow.AddDays(-2));
            File.WriteAllText(Path.Combine(backup,"a.txt"),"right");File.SetLastWriteTimeUtc(Path.Combine(backup,"a.txt"),DateTime.UtcNow.AddDays(-1));
            File.WriteAllText(Path.Combine(source,"z.txt"),"normal last file");
            var job=new BackupJob{Name="실행 중 처리 예약 검사",Source=source,Destination=backup};config.Jobs=[job];RefreshJobs();
            var previous=new BackupResult();previous.Errors.Add(new(job.Id,job.Name,"a.txt","이전 실행의 일반 파일 오류",4,5,"",""));OnStarted(job);OnCompleted(job,previous);var oldRun=sessionHistory.Latest(job.Id)!;
            var reached=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);using var release=new ManualResetEventSlim();bool blocked=false;
            void Block(BackupProgress p){if(p.JobId==job.Id && p.CurrentFile=="z.txt" && !blocked){blocked=true;reached.TrySetResult();if(!release.Wait(TimeSpan.FromSeconds(25)))throw new TimeoutException();}}
            scheduler.Progress+=Block;var lease=scheduler.AcquireRunLease;scheduler.AcquireRunLease=null;
            var task=scheduler.RunAsync(job,true);
            try
            {
                await reached.Task.WaitAsync(TimeSpan.FromSeconds(15));
                var panel=ShowFileComparison(job,oldRun);
                async Task Ready(){for(int i=0;i<250 && !panel.Find<Button>("CompareForwardButton").IsEnabled;i++)await Task.Delay(20);}
                await Ready();
                Check(panel.Find<Button>("CompareForwardButton").IsEnabled && panel.Find<Button>("CompareReverseButton").IsEnabled && panel.Find<Button>("CompareKeepBothButton").IsEnabled,"Active job disables file decision buttons");
                Check(panel.Find<Button>("CompareRefreshButton").IsEnabled && panel.Find<Button>("CompareApplyButton").Visibility==Visibility.Collapsed,"Active job still requires a separate reservation/apply button");
                panel.Find<Button>("CompareForwardButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(scheduler.QueuedResolutionCount(job.Id)==1 && File.ReadAllText(Path.Combine(backup,"a.txt"))=="right" && !File.Exists(Path.Combine(backup,"z.txt")),"UI choice mutated files before normal sync finished");
                panel.Find<Button>("CompareReverseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(scheduler.QueuedResolutionCount(job.Id)==1 && scheduler.ResolutionState(job.Id,"a.txt").Action==ConflictAction.UseBackup,"Clicking a different button did not replace the queued action");
                Check(((ComparisonRow)panel.Find<ListBox>("ComparisonFiles").SelectedItem).ActionText.Contains("예약") && !app.Windows.OfType<Window>().Any(w=>w.Title=="SafeSync 확인"),"One-click reservation is invisible or opened an extra confirmation");
                ClearProblemWorkspace();panel=ShowFileComparison(job,oldRun);await Ready();
                Check(panel.Find<Button>("CompareCancelQueuedButton").IsEnabled && panel.Find<TextBlock>("ComparisonSummary").Text.Contains("실행 대기 1개"),"Recreated panel lost or concealed accepted queue");
                panel.Find<Button>("CompareCancelQueuedButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(scheduler.QueuedResolutionCount(job.Id)==0 && !panel.Find<Button>("CompareCancelQueuedButton").IsEnabled,"UI cannot cancel pending choices");
                panel.Find<Button>("CompareKeepBothButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(scheduler.QueuedResolutionCount(job.Id)==1,"UI cannot requeue after cancel");
                release.Set();await task.WaitAsync(TimeSpan.FromSeconds(20));await Task.Delay(100);
                Check(File.ReadAllText(Path.Combine(backup,"a.txt"))=="left" && File.ReadAllText(Path.Combine(backup,"z.txt"))=="normal last file","Deferred UI choice did not run after complete normal sync");
                Check(Directory.EnumerateFiles(backup,"*.SafeSync-conflict-*").Any(p=>File.ReadAllText(p)=="right"),"Deferred UI keep-both lost prior backup");
                Check(sessionHistory.Runs.Count(r=>r.JobId==job.Id)==3 && scheduler.QueuedResolutionCount(job.Id)==0,"Deferred execution omitted history or left queue behind");
            }
            finally{release.Set();await task.WaitAsync(TimeSpan.FromSeconds(20));scheduler.Progress-=Block;scheduler.AcquireRunLease=lease;ClearProblemWorkspace();}
        }
        return assertions;
    }
}
