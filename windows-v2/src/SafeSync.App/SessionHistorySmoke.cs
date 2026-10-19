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
            ShowProgress();var window=progressWindow!;Theme.Apply(window,mode);window.Width=1180;window.Height=800;
            Check(sessionHistory.Runs.Count==before,"Progress created duplicate history entry");
            var result=new BackupResult {Copied=6,Skipped=4,Trashed=1};var issue=new FileIssue(job.Id,job.Name,"Audio/Session_04.wav","수정 시간은 같지만 크기가 다릅니다.",48000,52000,"2026-10-19 09:10:00","2026-10-19 09:10:00");result.Conflicts.Add(issue);result.Locked.Add(issue);result.Errors.Add(issue);
            OnCompleted(job,result);var first=sessionHistory.Runs[0];
            Check(window.Find<DataGrid>("HistoryGrid").Items.Count==sessionHistory.Runs.Count && first.Copied==6,"History table dropped completion");
            Check(window.Find<DataGrid>("ProgressErrorGrid").Items.Count==1 && window.Find<DataGrid>("ProgressLockedGrid").Items.Count==1,"Details did not show selected run issues");
            Check(window.Find<Button>("ApplyConflictActionsButton").IsEnabled,"Latest conflict cannot be resolved");
            OnStarted(job);OnCompleted(job,new BackupResult {Skipped=12});var latest=sessionHistory.Runs[0];
            Check(latest!=first && sessionHistory.Runs.Contains(first),"Repeated run replaced previous result");
            window.Find<DataGrid>("HistoryGrid").SelectedItem=first;RefreshProgress();
            Check(!window.Find<Button>("ApplyConflictActionsButton").IsEnabled && conflictRows.All(r=>!r.CanResolve),"Historical conflict allows stale overwrite");
            Check(window.Find<TextBlock>("ResultDetailText").Text.Contains("복사 6"),"Historical result was replaced by latest result");
            OnStarted(job);OnProgress(new(job.Id,job.Name,"파일 비교","Project/새 파일.cpr",2,10));
            Check(ReferenceEquals(SelectedRun,first),"New progress changed manually selected history");
            window.Find<Button>("FollowLatestButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(SelectedRun?.IsActive==true && ReferenceEquals(SelectedRun,sessionHistory.Runs[0]),"Follow-latest button does not select active run");
            window.Find<Button>("ProgressPauseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(!job.Paused && SelectedRun?.Outcome==SyncRunOutcome.Running,"Resume from progress window failed");
            window.Find<Button>("ProgressPauseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(job.Paused && SelectedRun?.Outcome==SyncRunOutcome.Paused,"Pause from progress window failed");
            window.Hide();OnFailed(job,new IOException("클라우드 연결 확인 실패 (모사)"));ShowProgress();
            Check(SelectedRun?.Outcome==SyncRunOutcome.Failed && window.Find<DataGrid>("ProgressErrorGrid").Items.Count==1,"Failure while hidden disappeared");
            Check(window.Find<TextBlock>("ResultDetailText").Text.Contains("모사"),"Exception details are missing");
            window.Find<DataGrid>("HistoryGrid").SelectedItem=first;RefreshProgress();window.Find<TabControl>("ProgressTabs").SelectedIndex=1;
            window.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            Check(window.Owner==null && Main.IsEnabled,"History window became modal");
            Check(window.Find<DataGrid>("ProgressConflictGrid").ActualHeight>50,"Conflict details are squeezed out");
            if(previewDirectory!=null)
            {
                void Render(string name){window.UpdateLayout();var bmp=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);bmp.Render(window);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bmp));using var output=File.Create(Path.Combine(previewDirectory,name+"-"+mode+".png"));png.Save(output);}
                Render("SessionHistory-Conflicts");window.Find<TabControl>("ProgressTabs").SelectedIndex=0;Render("SessionHistory-Result");
                window.Width=760;window.Height=620;window.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(500);window.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                Render("SessionHistory-Compact");
            }
            Check(window.Find<TabControl>("ProgressTabs").ActualHeight>=100,"Resizing hides the detail area");
            var footer=VisualChildren<TextBlock>(window).Single(t=>t.Text.StartsWith("창을 닫아도 백업은 계속됩니다."));
            var viewport=(FrameworkElement)VisualTreeHelper.GetParent(window.Find<Grid>("ProgressRoot"));
            Check(footer.TransformToAncestor(viewport).TransformBounds(new Rect(footer.RenderSize)).Bottom<=viewport.ActualHeight+1,"Compact window hides session footer");
            Check(window.Find<DataGrid>("HistoryGrid").Columns.All(c=>c.ActualWidth>=c.MinWidth-.5),"Compact window shrinks history columns below readable width");
            window.Width=1180;window.Height=800;window.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(190);window.UpdateLayout();CaptureLayout();
            Check(Math.Abs(config.WindowLayout.ProgressHistoryHeight-190)<1,"History splitter height not saved");
            window.Find<TabControl>("ProgressTabs").SelectedIndex=0;window.Hide();
        }
        return assertions;
    }
}
