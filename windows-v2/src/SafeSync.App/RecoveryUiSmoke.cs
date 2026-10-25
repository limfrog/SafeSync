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
    private async Task<int> TestRecoveryUiAsync(string? previewDirectory)
    {
        int assertions=0;void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;Theme.Apply(Main,mode);noticeLedger.Dismiss(noticeLedger.Entries.ToArray());notices.Clear();
            var job=new BackupJob {Name="메시지 검사",Source=Path.Combine(store.Root,"smoke-source"),Destination=Path.Combine(store.Root,"smoke-backup")};
            config.Jobs=[job];RefreshJobs();
            var result=new BackupResult();result.Errors.Add(new(job.Id,job.Name,"프로젝트/파일.txt","예시 파일 오류 — 실제 백업과 무관한 화면 검사",0,0,"",""));
            OnCompleted(job,result);ShowNotices();var window=messagesWindow!;window.UpdateLayout();
            await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            Check(window.IsVisible && Main.IsEnabled && window.Owner==null,"Message browser blocked the main window");
            Check(window.Find<DataGrid>("MessagesGrid").Items.Count==1 && window.Find<Button>("ClearMessagesButton").IsEnabled,"Message browser omitted the clear action");
            if(previewDirectory!=null)
            {
                var bmp=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);bmp.Render(window);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bmp));using var output=File.Create(Path.Combine(previewDirectory,"Messages-"+mode+".png"));png.Save(output);
            }
            window.Find<Button>("ClearMessagesButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(window.Find<DataGrid>("MessagesGrid").Items.Count==0 && !window.Find<Button>("ClearMessagesButton").IsEnabled && window.Find<TextBlock>("MessagesEmptyText").Visibility==Visibility.Visible,"Clearing messages did not show the empty state");
            Check(result.Errors.Count==1 && results[job.Id].Errors.Count==1 && !Main.Find<Button>("NotificationsButton").IsEnabled,"Clearing notices changed backup errors or left the badge active");
            OnCompleted(job,result);Check(notices.Count==0,"Unresolved dismissed file error reappeared on retry");window.Close();
            Check(!Main.Find<MenuItem>("RebindCloudJobMenuItem").IsEnabled,"Local job offered cloud rebind");
            var cloudJob=new BackupJob {Name="가져온 클라우드 작업",Source=job.Source,DestinationType="GoogleDrive",Destination="Google Drive / 이전 위치",CloudFolderId="old-folder",CloudAccountId="old-account",CloudBindingReviewRequired=true};
            var accounts=CloudAccounts.Read(config);accounts.GoogleDrive.AccountId="synthetic-account";accounts.GoogleDrive.AccountName="화면 검사 계정";accounts.GoogleDrive.RefreshTokenProtected="synthetic-not-a-token";accounts.GoogleDrive.AccessMode=GoogleFileAccess.Mode;accounts.Write(config);
            config.Jobs=[cloudJob];RefreshJobs();OnFailed(cloudJob,new CloudBindingException("계정·폴더 확인 필요 (모사)"));
            Check(cloudJob.Stopped && !cloudJob.Paused && cloudJob.Status=="클라우드 연결 확인 필요" && Main.Find<MenuItem>("RebindCloudJobMenuItem").IsEnabled,"Changed cloud binding did not enter a recoverable waiting state");
            bool confirmedDialogSeen=false;
            var cancel=app.Dispatcher.BeginInvoke(()=>
            {
                var dialog=app.Windows.OfType<Window>().Single(w=>w.Title=="클라우드 위치 다시 연결");
                confirmedDialogSeen=VisualChildren<TextBlock>(dialog).Any(t=>t.Text.Contains("첫 비교에서는 이전 기록에 따른 삭제를 전파하지 않습니다."));dialog.DialogResult=false;
            });
            var prepared=PrepareCloudJob(cloudJob,true);await cancel;
            Check(confirmedDialogSeen && prepared==null && config.Jobs.Single().Id==cloudJob.Id && cloudJob.CloudAccountId=="old-account","Canceling rebind changed job/account or omitted deletion warning");
            var duplicate=new ConflictRow(new(cloudJob.Id,cloudJob.Name,"dup.txt",new CloudDuplicateNameException("dup.txt").Message,0,0,"",""));
            Check(!duplicate.CanResolve && duplicate.ActionLabel.Contains("중복 이름 정리"),"Duplicate names offered an unsafe overwrite action");
        }
        return assertions;
    }
}
