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
    private async Task<int> TestSessionHistoryAsync(string? previewDirectory)
    {
        int assertions=0;
        void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;followLatest=true;
            var job=new BackupJob {Name="스튜디오 프로젝트",Source=Path.Combine(store.Root,"smoke-source"),Destination="Google Drive / Backup / Studio",DestinationType="GoogleDrive",CloudFolderId="synthetic-folder",CloudAccountId="synthetic-account",Paused=true};
            config.Jobs=[job];RefreshJobs();OnStarted(job);var before=sessionHistory.Runs.Count;
            OnProgress(new(job.Id,job.Name,"검증 전용 임시 위치로 전송","Audio/Session_04.wav",6,12));
            ShowProgress();var window=progressWindow!;Theme.Apply(window,mode);Main.Width=1180;Main.Height=800;
            Check(sessionHistory.Runs.Count==before,"Progress created duplicate history entry");
            var result=new BackupResult {Copied=6,Skipped=4,Trashed=1};var issue=new FileIssue(job.Id,job.Name,"Audio/Session_04.wav","수정 시간은 같지만 크기가 다릅니다.",48000,52000,"2026-10-19 09:10:00","2026-10-19 09:10:00");result.Conflicts.Add(issue);result.Locked.Add(issue);result.Errors.Add(issue);
            OnCompleted(job,result);var first=sessionHistory.Runs[0];
            Check(window.Find<DataGrid>("HistoryGrid").Items.Count==sessionHistory.Runs.Count && first.Copied==6,"History table dropped completion");
            Check(window.Find<DataGrid>("ProgressErrorGrid").Items.Count==1 && window.Find<DataGrid>("ProgressLockedGrid").Items.Count==1,"Details did not show selected run issues");
            Check(window.Find<Button>("ApplyConflictActionsButton").IsEnabled,"Latest conflict cannot be resolved");
            OnStarted(job);OnCompleted(job,new BackupResult {Skipped=12});var latest=sessionHistory.Runs[0];
            Check(latest!=first && sessionHistory.Runs.Contains(first),"Repeated run replaced previous result");
            window.Find<DataGrid>("HistoryGrid").SelectedItem=first;RefreshProgress();
            Check(window.Find<Button>("ApplyConflictActionsButton").IsEnabled && conflictRows.All(r=>!r.CanResolve),"Historical issues cannot open current-file review or permit unchecked stale overwrite");
            Check(window.Find<TextBlock>("ResultDetailText").Text.Contains("복사 6"),"Historical result was replaced by latest result");
            OnStarted(job);OnProgress(new(job.Id,job.Name,"파일 비교","Project/새 파일.cpr",2,10));
            Check(ReferenceEquals(SelectedRun,first),"New progress changed manually selected history");
            window.Find<Button>("FollowLatestButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(SelectedRun?.IsActive==true && ReferenceEquals(SelectedRun,sessionHistory.Runs[0]),"Follow-latest button does not select active run");
            window.Find<Button>("ProgressPauseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(!job.Paused && SelectedRun?.Outcome==SyncRunOutcome.Running,"Resume from progress window failed");
            window.Find<Button>("ProgressPauseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(job.Paused && SelectedRun?.Outcome==SyncRunOutcome.Paused,"Pause from progress window failed");
            HideProgress();OnFailed(job,new IOException("클라우드 연결 확인 실패 (모사)"));ShowProgress();
            Check(SelectedRun?.Outcome==SyncRunOutcome.Failed && window.Find<DataGrid>("ProgressErrorGrid").Items.Count==1,"Failure while hidden disappeared");
            Check(window.Find<TextBlock>("ResultDetailText").Text.Contains("모사"),"Exception details are missing");
            window.Find<DataGrid>("HistoryGrid").SelectedItem=first;RefreshProgress();window.Find<TabControl>("ProgressTabs").SelectedIndex=1;
            Main.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            Check(window.Owner==null && Main.IsEnabled,"History window became modal");
            Check(window.Find<DataGrid>("ProgressConflictGrid").ActualHeight>50,"Conflict details are squeezed out");
            if(previewDirectory!=null)
            {
                void Render(string name){Main.UpdateLayout();var bmp=new RenderTargetBitmap((int)Math.Ceiling(WorkspaceVisual(window).ActualWidth),(int)Math.Ceiling(WorkspaceVisual(window).ActualHeight),96,96,PixelFormats.Pbgra32);bmp.Render(WorkspaceVisual(window));var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bmp));using var output=File.Create(Path.Combine(previewDirectory,name+"-"+mode+".png"));png.Save(output);}
                Render("SessionHistory-Conflicts");window.Find<TabControl>("ProgressTabs").SelectedIndex=0;Render("SessionHistory-Result");
                Main.Width=760;Main.Height=620;window.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(500);Main.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                Render("SessionHistory-Compact");
            }
            Check(window.Find<TabControl>("ProgressTabs").ActualHeight>=100,"Resizing hides the detail area");
            var footer=VisualChildren<TextBlock>(WorkspaceVisual(window)).Single(t=>t.Text.StartsWith("창을 닫아도 백업은 계속됩니다."));
            var viewport=WorkspaceVisual(window);
            Check(footer.TransformToAncestor(viewport).TransformBounds(new Rect(footer.RenderSize)).Bottom<=viewport.ActualHeight+1,"Compact tab clips session footer instead of providing scrolling");
            Check(window.Find<DataGrid>("HistoryGrid").Columns.All(c=>c.ActualWidth>=c.MinWidth-.5),"Compact window shrinks history columns below readable width");
            Main.Width=1180;Main.Height=900;Main.UpdateLayout();await Main.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);window.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(190);Main.UpdateLayout();CaptureLayout();
            Check(config.WindowLayout.ProgressHistoryHeight>=90 && Math.Abs(config.WindowLayout.ProgressHistoryHeight-window.Find<RowDefinition>("ProgressHistoryRow").ActualHeight)<1,"History splitter height not saved");
            followLatest=true;OnStarted(job);OnProgress(new(job.Id,job.Name,"파일 전송","Audio/last.wav",1,3));
            Main.Find<MenuItem>("StopJobMenuItem").RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            Check(job.Stopped && !job.Paused && SelectedRun?.Outcome==SyncRunOutcome.Stopping,"Stop menu did not separate ending from pause");
            Check(window.Find<TextBlock>("ActiveSummaryText").Text=="종료 중…" && window.Find<Button>("ProgressPauseButton").Visibility==Visibility.Collapsed,"Progress window omitted stopping label or offered pause");
            OnProgress(new(job.Id,job.Name,"교체 후 검증","Audio/last.wav",2,3));
            Main.UpdateLayout();
            Check(SelectedRun?.StatusText=="종료 중…" && VisualChildren<TextBlock>(window.Find<ItemsControl>("ProgressItems")).Any(t=>t.Text.StartsWith("종료 중…")),"Last-file progress hid finishing message");
            if(previewDirectory!=null)
            {
                var bmp=new RenderTargetBitmap((int)Math.Ceiling(WorkspaceVisual(window).ActualWidth),(int)Math.Ceiling(WorkspaceVisual(window).ActualHeight),96,96,PixelFormats.Pbgra32);bmp.Render(WorkspaceVisual(window));var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bmp));using var output=File.Create(Path.Combine(previewDirectory,"SessionHistory-Stopping-"+mode+".png"));png.Save(output);
            }
            OnCompleted(job,new BackupResult {Canceled=true,Copied=2});Main.UpdateLayout();
            Check(job.Status=="대기 중" && SelectedRun?.Outcome==SyncRunOutcome.Waiting && !SelectedRun.IsActive,"Completed stop did not enter idle waiting");
            Check(window.Find<TextBlock>("ResultTitleText").Text=="대기 중" && window.Find<ItemsControl>("ProgressItems").Items.Count==0 && window.Find<Button>("ProgressPauseButton").Visibility==Visibility.Collapsed,"Waiting result retained active transfer or pause controls");
            Check(window.Find<TextBlock>("ResultDetailText").Text.Contains("남은 작업은 저장") && Main.Find<Button>("PauseButton").Content.ToString()=="▶ 작업 시작","Waiting result omitted saved pending work or showed resume");
            window.Find<TabControl>("ProgressTabs").SelectedIndex=0;HideProgress();
        }
        return assertions;
    }
}
