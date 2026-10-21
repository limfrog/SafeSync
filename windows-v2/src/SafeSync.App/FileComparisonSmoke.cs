using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task<int> TestFileComparisonUiAsync(string? previewDirectory)
    {
        int assertions=0;void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        async Task Ready(FrameworkElement window)
        {
            for(int i=0;i<150 && !window.Find<Button>("CompareForwardButton").IsEnabled;i++)await Task.Delay(20);
            window.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        }
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;Theme.Apply(Main,mode);followLatest=true;
            var home=Path.Combine(store.Root,"comparison-ui-"+mode);var source=Path.Combine(home,"원본");var backup=Path.Combine(home,"백업");Directory.CreateDirectory(source);Directory.CreateDirectory(backup);
            foreach(var name in new[]{"프로젝트.wav","오류.txt"}){File.WriteAllText(Path.Combine(source,name),"source original");File.WriteAllText(Path.Combine(backup,name),"backup original longer");}
            var job=new BackupJob{Name="파일 비교 화면 검사",Source=source,Destination=backup,Stopped=true};config.Jobs=[job];RefreshJobs();
            var conflict=new FileIssue(job.Id,job.Name,"프로젝트.wav","양쪽 파일의 내용이 다릅니다. 유지할 사본을 선택하세요.",15,22,DateTime.Now.ToString("O"),DateTime.Now.ToString("O"),SourceCreated:DateTime.Now.ToString("O"),BackupCreated:DateTime.Now.ToString("O"),SourceExists:true,BackupExists:true);
            var result=new BackupResult();result.Conflicts.Add(conflict);result.Errors.Add(conflict with{File="오류.txt",Reason="이전 실행 중 연결이 끊겼습니다. 현재 정보와 처리 방향을 확인하세요."});OnStarted(job);OnCompleted(job,result);
            var run=sessionHistory.Runs[0];var window=ShowFileComparison(job,run);await Ready(window);
            var list=window.Find<ListBox>("ComparisonFiles");
            Check(list.Items.Count==3 && Window.GetWindow(window)==Main && Main.IsEnabled,"Comparison panel omitted errors/conflicts or was not embedded in progress");
            Check(((SolidColorBrush)progressWindow!.Background).Color==(Color)ColorConverter.ConvertFromString(mode=="Dark" ? "#171B22" : "#F5F7FB"),"Reopened progress did not refresh the selected theme");
            Check(!app.Windows.OfType<Window>().Any(w=>w.Title is "SafeSync · 파일 비교 및 처리" or "SafeSync · 문제 해결"),"Resolution still creates a separate window");
            Check(window.Find<TextBlock>("CompareSourcePath").Text==Path.Combine(source,"프로젝트.wav") && window.Find<TextBlock>("CompareBackupPath").Text==Path.Combine(backup,"프로젝트.wav"),"Comparison paths point to wrong sides");
            Check(window.Find<TextBlock>("CompareSourceSize").Text=="15 B" && window.Find<TextBlock>("CompareBackupSize").Text=="22 B","Comparison sizes mixed up");
            Check(window.Find<TextBlock>("CompareSourceCreated").Text.Contains(DateTime.Now.Year.ToString()) && window.Find<TextBlock>("CompareBackupCreated").Text.Contains(DateTime.Now.Year.ToString()),"Comparison omitted creation dates");
            Check(window.Find<Button>("CompareReverseButton").IsEnabled && job.SyncMode=="OneWay","One-way job cannot explicitly restore backup");
            var firstRow=(ComparisonRow)list.SelectedItem;var originalSnapshot=firstRow.Snapshot!;
            var primary=new RemoteItem("a-primary","프로젝트.wav",false,22,DateTime.UtcNow,DateTime.UtcNow,"hash","1");
            firstRow.Snapshot=originalSnapshot with{Duplicates=new(primary,[new("중복 폴더","root",[primary,primary with{Id="b-extra"}])])};
            list.SelectedItem=null;list.SelectedItem=firstRow;await Ready(window);
            Check(window.Find<Button>("CompareDuplicatesButton").IsEnabled && window.Find<TextBlock>("ComparisonDuplicatesText").Text.Contains("b-extra"),"Duplicate UI omitted preservation action or physical-copy metadata");
            window.Find<Button>("CompareDuplicatesButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(firstRow.Action==ConflictAction.NormalizeDuplicates && window.Find<Button>("CompareApplyButton").IsEnabled,"Duplicate name-only preservation cannot be queued");
            var rejectDuplicate=app.Dispatcher.BeginInvoke(()=>app.Windows.OfType<Window>().Single(w=>w.Title=="SafeSync 확인").DialogResult=false);
            window.Find<Button>("CompareApplyButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await rejectDuplicate;
            Check(File.ReadAllText(Path.Combine(backup,"프로젝트.wav"))=="backup original longer","Canceled duplicate action changed backup");
            firstRow.Snapshot=originalSnapshot;firstRow.Action=null;list.SelectedItem=null;list.SelectedItem=firstRow;await Ready(window);
            foreach(var (name,action) in new[]{("CompareForwardButton",ConflictAction.Overwrite),("CompareReverseButton",ConflictAction.UseBackup),("CompareKeepBothButton",ConflictAction.KeepBoth),("CompareIgnoreButton",ConflictAction.Ignore)})
            {
                window.Find<Button>(name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                Check(((ComparisonRow)list.SelectedItem).Action==action && window.Find<Button>("CompareApplyButton").IsEnabled,"Comparison choice not queued: "+name);
            }
            foreach(var row in list.Items.Cast<ComparisonRow>().Where(r=>r.IsFile))if(!list.SelectedItems.Contains(row))list.SelectedItems.Add(row);
            await Ready(window);window.Find<Button>("CompareIgnoreButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(list.Items.Cast<ComparisonRow>().Where(r=>r.IsFile).All(r=>r.Action==ConflictAction.Ignore),"Multiple selection did not assign action to each file");
            RefreshProgress();Check(ReferenceEquals(problemPanel,window) && list.Items.Cast<ComparisonRow>().Where(r=>r.IsFile).All(r=>r.Action==ConflictAction.Ignore),"Progress refresh discarded queued decisions");
            Check(new ComparisonRow(conflict with{File="[테스트].wav"},"오류").IsFile,"Bracketed real filename was mistaken for a job-level error");
            list.SelectedItem=list.Items[0];await Ready(window);
            if(previewDirectory!=null)
            {
                var host=progressWindow!;Main.Width=1180;Main.Height=900;host.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(125);Main.UpdateLayout();var bitmap=new RenderTargetBitmap((int)Math.Ceiling(WorkspaceVisual(host).ActualWidth),(int)Math.Ceiling(WorkspaceVisual(host).ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(WorkspaceVisual(host));var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(Path.Combine(previewDirectory,"FileComparison-"+mode+".png"));png.Save(stream);
            }
            var progressHost=progressWindow!;Main.Width=720;Main.Height=600;progressHost.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(90);Main.UpdateLayout();
            foreach(var name in new[]{"CompareIgnoreButton","CompareApplyButton","CompareReverseButton"})
            {
                var button=window.Find<Button>(name);var bounds=button.TransformToAncestor(WorkspaceVisual(progressHost)).TransformBounds(new Rect(button.RenderSize));
                Check(bounds.Bottom<WorkspaceVisual(progressHost).ActualHeight && bounds.Right<WorkspaceVisual(progressHost).ActualWidth && bounds.Left>=0,"Compact comparison clips action: "+name);
            }
            HideProgress();ShowProgress();Check(ReferenceEquals(problemPanel,window),"Hiding progress discarded queued decisions");ClearProblemWorkspace();Main.Width=1180;Main.Height=800;

            // The actual Apply handler must pass checked decisions through the
            // scheduler; canceling the confirmation must not mutate either side.
            window=ShowFileComparison(job,run);await Ready(window);
            window.Find<Button>("CompareReverseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var cancel=app.Dispatcher.BeginInvoke(()=>app.Windows.OfType<Window>().Single(w=>w.Title=="SafeSync 확인").DialogResult=false);
            window.Find<Button>("CompareApplyButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await cancel;
            Check(File.ReadAllText(Path.Combine(source,"프로젝트.wav"))=="source original" && job.Stopped,"Canceling comparison confirmation changed source or started job");
            var lease=scheduler.AcquireRunLease;scheduler.AcquireRunLease=null;
            try
            {
                var confirm=app.Dispatcher.BeginInvoke(()=>app.Windows.OfType<Window>().Single(w=>w.Title=="SafeSync 확인").DialogResult=true);
                window.Find<Button>("CompareApplyButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await confirm;
                for(int i=0;i<200 && (scheduler.IsRunning(job.Id) || File.ReadAllText(Path.Combine(source,"프로젝트.wav"))=="source original");i++)await Task.Delay(20);
                await Task.Delay(50);
                Check(File.ReadAllText(Path.Combine(source,"프로젝트.wav"))=="backup original longer" && job.SyncMode=="OneWay","Actual comparison apply did not perform isolated reverse copy");
                Check(new TrashService().List(source,default).Any(t=>t.RelativePath=="프로젝트.wav"),"Actual comparison apply lost prior source");
                Check(!window.Find<Button>("CompareApplyButton").IsEnabled,"Old comparison remained writable after new execution");
                problemPanel!.Find<Button>("CompareSourceTrashButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                var trashView=auxiliary.Last(w=>w.FindName("TrashGrid")!=null);
                for(int i=0;i<150 && trashView.Find<DataGrid>("TrashGrid").Items.Count==0;i++)await Task.Delay(20);
                Check(Main.IsEnabled && trashView.Owner==null && trashView.Find<DataGrid>("TrashGrid").Items.Cast<TrashItem>().Any(t=>t.RelativePath=="프로젝트.wav"),"One-way reverse original is not accessible from source trash UI");trashView.Close();
            }
            finally{scheduler.AcquireRunLease=lease;ClearProblemWorkspace();}
            window=ShowFileComparison(job,run);
            Check(!window.Find<Button>("CompareForwardButton").IsEnabled && window.Find<TextBlock>("ComparisonSummary").Text.Contains("읽기 전용"),"Historical comparison allows destructive choice");
            window.Find<Button>("CompareRefreshButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await Ready(window);
            Check(window.Find<Button>("CompareForwardButton").IsEnabled && window.Find<Button>("CompareReverseButton").IsEnabled && window.Find<Button>("CompareKeepBothButton").IsEnabled && window.Find<Button>("CompareIgnoreButton").IsEnabled,"Historical issues cannot be safely rechecked against current files and resolved");
            Check(window.Find<TextBlock>("CompareSourceSize").Text=="22 B" && window.Find<TextBlock>("ComparisonSummary").Text.Contains("현재 파일 재확인"),"Historical recheck still shows obsolete file metadata");
            if(previewDirectory!=null)
            {
                Main.Width=1180;Main.Height=900;Main.UpdateLayout();var host=WorkspaceVisual(progressWindow!);
                var bitmap=new RenderTargetBitmap((int)Math.Ceiling(host.ActualWidth),(int)Math.Ceiling(host.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(host);
                var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(Path.Combine(previewDirectory,"HistoricalReview-"+mode+".png"));png.Save(stream);
            }
            window.Find<Button>("CompareIgnoreButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(window.Find<Button>("CompareApplyButton").IsEnabled,"Rechecked historical decision cannot be applied");
            OnStarted(job);RefreshProgress();
            Check(!window.Find<Button>("CompareApplyButton").IsEnabled && !window.Find<Button>("CompareIgnoreButton").IsEnabled,"New execution did not revoke rechecked historical decisions");
            Check(window.Find<Button>("CompareStopButton").Visibility==Visibility.Visible && window.Find<Button>("CompareStopButton").IsEnabled && !window.Find<Button>("CompareRefreshButton").IsEnabled,"Active comparison offers no safe path to stop before rechecking");
            window.Find<Button>("CompareStopButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(job.Stopped && !job.Paused && sessionHistory.Latest(job.Id)?.Outcome==SyncRunOutcome.Stopping,"Comparison stop did not request finishing instead of pausing");
            OnCompleted(job,new BackupResult());RefreshProgress();
            Check(!window.Find<Button>("CompareApplyButton").IsEnabled,"Completed newer execution resurrected stale decision authority");
            window=problemPanel!; // Result changes may replace the read-only host.
            window.Find<Button>("CompareRefreshButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await Ready(window);
            Check(window.Find<Button>("CompareReverseButton").IsEnabled && window.Find<ListBox>("ComparisonFiles").Items.Cast<ComparisonRow>().All(r=>r.Action==null),"Rechecking after another run failed to clear stale choices");
            var reviewedList=window.Find<ListBox>("ComparisonFiles");
            reviewedList.SelectedItem=reviewedList.Items.OfType<ComparisonRow>().Single(r=>r.Issue.File=="오류.txt");await Ready(window);
            window.Find<Button>("CompareForwardButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var recheckedLease=scheduler.AcquireRunLease;scheduler.AcquireRunLease=null;
            try
            {
                var acceptRechecked=app.Dispatcher.BeginInvoke(()=>app.Windows.OfType<Window>().Single(w=>w.Title=="SafeSync 확인").DialogResult=true);
                window.Find<Button>("CompareApplyButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await acceptRechecked;
                for(int i=0;i<200 && (scheduler.IsRunning(job.Id) || File.ReadAllText(Path.Combine(backup,"오류.txt"))!="source original");i++)await Task.Delay(20);
                Check(File.ReadAllText(Path.Combine(backup,"오류.txt"))=="source original","Rechecked historical action did not reach the safe scheduler apply path");
                Check(new TrashService().List(backup,default).Any(t=>t.RelativePath=="오류.txt"),"Rechecked historical overwrite did not preserve the prior backup");
            }
            finally{scheduler.AcquireRunLease=recheckedLease;}
            ClearProblemWorkspace();
            // Dropbox's stored CreatedUtc is server_modified, not a birth time.
            // Do not present that timestamp as an actual creation date.
            var dropboxJob=new BackupJob{Name="Dropbox 생성일시 검사",Source=source,Destination="Dropbox / Backup",DestinationType="Dropbox"};config.Jobs=[dropboxJob];RefreshJobs();
            var dropboxResult=new BackupResult();dropboxResult.Conflicts.Add(conflict with{JobId=dropboxJob.Id,JobName=dropboxJob.Name});OnStarted(dropboxJob);OnCompleted(dropboxJob,dropboxResult);var dropboxRun=sessionHistory.Runs[0];
            OnStarted(dropboxJob);OnCompleted(dropboxJob,new BackupResult());window=ShowFileComparison(dropboxJob,dropboxRun);
            Check(window.Find<TextBlock>("CompareBackupCreated").Text=="생성일시 정보 없음","Dropbox server-modified time masquerades as creation date");ClearProblemWorkspace();progressWindow!.Find<TabControl>("ProgressTabs").SelectedIndex=0;
            var noRun=new BackupJob{Name="재시작 후 문제 안내",Source=source,Destination=backup};config.Jobs=[noRun];RefreshJobs();RememberProblem(noRun,JobProblem.Classify("폴더에 접근할 수 없습니다.",false,"Missing"));
            ShowJobRecovery(noRun);var recovery=recoveryPanels.Single(p=>p.Value.Job.Id==noRun.Id).Key;
            Check(SelectedRun==null && Window.GetWindow(recovery)==Main && recovery.Find<Button>("RecoveryRetryButton").IsEnabled,"A persisted problem without session history is not repairable inline");
            HideProgress();ShowProgress();Check(SelectedRun==null && ReferenceEquals(recoveryPanels.Single().Key,recovery),"Reopening progress switched a no-history problem to another job");
            ClearProblemWorkspace();problemRequestedJob=null;progressWindow!.Find<TabControl>("ProgressTabs").SelectedIndex=0;
        }
        return assertions;
    }
}
