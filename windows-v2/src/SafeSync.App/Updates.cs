using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private readonly AppUpdateClient updateClient=new();
    private readonly CancellationTokenSource updateLifetime=new();
    private CancellationTokenSource? updateTransfer;
    private DispatcherTimer? updateStartupTimer,updateTimer;
    private Task? updateTask;
    private Window? updateWindow;
    private AppUpdateRelease? updateRelease;
    private string updateStatus="아직 업데이트를 확인하지 않았습니다.",updateFile="",updateNotified="";
    private bool updateBusy,automaticUpdateOperation;
    private long updateReceived,updateTotal;
    private IDisposable? updateBackupHold;
    private event Action? UpdateDisplayChanged;
    private string UpdateCache=>Path.Combine(store.Root,"app-updates-v1");
    private void StartUpdates()
    {
        updateStartupTimer=new(){Interval=TimeSpan.FromSeconds(20)};
        updateStartupTimer.Tick+=(_,_)=>{updateStartupTimer.Stop();if(config.AutomaticallyCheckUpdates)BeginUpdateCheck(false);};updateStartupTimer.Start();
        updateTimer=new(){Interval=TimeSpan.FromHours(1)};
        updateTimer.Tick+=(_,_)=>{if(config.AutomaticallyCheckUpdates)BeginUpdateCheck(false);};updateTimer.Start();
    }
    private void BindUpdateSettings(Window window)
    {
        window.Find<CheckBox>("AutoUpdateCheck").IsChecked=config.AutomaticallyCheckUpdates;
        window.Find<CheckBox>("AutoDownloadCheck").IsChecked=config.AutomaticallyDownloadUpdates;
        window.Find<TextBlock>("UpdateCurrentVersionText").Text="현재 버전: "+AppVersion;
        void Render()=>window.Find<TextBlock>("UpdateSummaryText").Text=updateStatus;
        UpdateDisplayChanged+=Render;window.Closed+=(_,_)=>UpdateDisplayChanged-=Render;Render();
        Click(window,"CheckUpdatesButton",()=>BeginUpdateCheck(true));
    }
    private void ShowUpdates()
    {
        if(updateWindow is {} open){open.Show();open.Activate();return;}
        var window=NewDialog("Updates",false);updateWindow=window;
        window.Resources[typeof(Button)]=Main.Resources[typeof(Button)];
        window.Find<TextBlock>("InstalledVersionText").Text="현재 버전: "+AppVersion;
        void Render()
        {
            window.Find<TextBlock>("AvailableVersionText").Text=updateRelease==null ? "새 버전을 확인하세요." : "새 버전: "+updateRelease.Version;
            window.Find<TextBlock>("UpdateStatusText").Text=updateStatus;
            window.Find<TextBlock>("UpdateNotesText").Text=updateRelease?.Notes ?? "GitHub의 검증된 배포 파일을 사용합니다.";
            var progress=window.Find<ProgressBar>("UpdateDownloadProgress");progress.IsIndeterminate=updateBusy && updateTotal==0;
            progress.Maximum=Math.Max(1,updateTotal);progress.Value=updateReceived;
            window.Find<Button>("UpdateCheckButton").IsEnabled=!updateBusy;
            window.Find<Button>("UpdateDownloadButton").IsEnabled=!updateBusy && updateRelease!=null;
            window.Find<Button>("UpdateInstallButton").IsEnabled=!updateBusy && updateRelease!=null && updateFile.Length>0;
            window.Find<Button>("UpdateCancelButton").IsEnabled=updateBusy;
        }
        UpdateDisplayChanged+=Render;
        window.Closed+=(_,_)=>{UpdateDisplayChanged-=Render;updateWindow=null;};
        Click(window,"UpdateCheckButton",()=>BeginUpdateCheck(true));
        Click(window,"UpdateDownloadButton",()=>RunUpdateOperation(DownloadUpdateAsync,false));
        Click(window,"UpdateInstallButton",()=>
        {
            if(updateRelease==null || !Confirm($"SafeSync {updateRelease.Version} 업데이트를 설치할까요?\n진행 중인 파일을 안전하게 마친 뒤 앱을 닫고 설치 프로그램을 실행합니다. 작업과 계정 설정은 유지됩니다."))return;
            RunUpdateOperation(InstallUpdateAsync,false);
        });
        Click(window,"UpdateCancelButton",()=>updateTransfer?.Cancel());
        Click(window,"UpdateCloseButton",window.Close);
        Render();window.Show();window.Activate();
    }
    private void BeginUpdateCheck(bool interactive)
    {
        if(interactive)ShowUpdates();
        RunUpdateOperation(async token=>
        {
            if(smoke){updateStatus="화면 검사 중에는 외부 업데이트를 확인하지 않습니다.";return;}
            updateStatus="GitHub의 새 버전을 확인하고 있습니다…";UpdateDisplayChanged?.Invoke();
            var found=await updateClient.CheckAsync(AppVersion,"windows-x64",token);
            token.ThrowIfCancellationRequested();
            if(found==null){updateRelease=null;updateFile="";updateStatus="현재 버전이 최신입니다.";return;}
            if(updateRelease?.Version!=found.Version)updateFile="";
            updateRelease=found;updateStatus="새 버전 "+found.Version+"을 사용할 수 있습니다.";
            Log("SafeSync 새 버전 확인: "+found.Version);
            UpdateDisplayChanged?.Invoke();
            if(updateNotified!=found.Version)
            {
                updateNotified=found.Version;
                if(Main.IsVisible && Main.WindowState!=WindowState.Minimized)ShowUpdates();
            }
            if(config.AutomaticallyDownloadUpdates)await DownloadUpdateAsync(token);
        },!interactive);
    }
    private void RunUpdateOperation(Func<CancellationToken,Task> action,bool automatic)
    {
        if(exiting || updateBusy)return;
        updateBusy=true;automaticUpdateOperation=automatic;updateReceived=0;updateTotal=0;
        updateTask=RunAsync();
        async Task RunAsync()
        {
            using var transfer=CancellationTokenSource.CreateLinkedTokenSource(updateLifetime.Token);updateTransfer=transfer;
            try{UpdateDisplayChanged?.Invoke();await action(transfer.Token);}
            catch(OperationCanceledException){if(!exiting)updateStatus=transfer.IsCancellationRequested ? "업데이트 작업을 취소했습니다. 다시 시도할 수 있습니다." : "업데이트 응답/대기 시간이 초과되었습니다. 다시 시도하세요.";}
            catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or HttpRequestException or System.Text.Json.JsonException or InvalidOperationException or System.ComponentModel.Win32Exception)
            {updateStatus="업데이트 확인/다운로드 실패: "+ex.Message;Log(updateStatus);}
            finally{updateTransfer=null;updateBusy=false;automaticUpdateOperation=false;if(!exiting)UpdateDisplayChanged?.Invoke();}
        }
    }
    private async Task DownloadUpdateAsync(CancellationToken token)
    {
        var release=updateRelease ?? throw new InvalidOperationException("먼저 새 버전을 확인하세요.");
        updateFile="";updateStatus="새 버전 다운로드 및 무결성 검증 중…";updateTotal=release.Size;UpdateDisplayChanged?.Invoke();
        var reporter=new Progress<AppUpdateProgress>(p=>
        {
            if(exiting || !updateBusy || updateFile.Length>0)return;
            updateReceived=p.Received;updateTotal=p.Total;
            updateStatus=$"다운로드 {p.Received/(1024d*1024):N1} / {p.Total/(1024d*1024):N1} MB";UpdateDisplayChanged?.Invoke();
        });
        updateFile=await updateClient.DownloadAsync(release,"windows-x64",UpdateCache,reporter,token);
        updateReceived=updateTotal=release.Size;
        updateStatus="다운로드와 체크섬 검증이 완료됐습니다. ‘업데이트 설치’를 누르세요.";Log("SafeSync "+release.Version+" 업데이트 다운로드 검증 완료");
    }
    private async Task InstallUpdateAsync(CancellationToken token)
    {
        if(updateRelease==null || updateFile.Length==0)throw new InvalidOperationException("검증된 설치 파일을 먼저 다운로드하세요.");
        updateStatus="현재 파일의 백업을 안전하게 마치는 중…";UpdateDisplayChanged?.Invoke();
        using var wait=CancellationTokenSource.CreateLinkedTokenSource(token);wait.CancelAfter(TimeSpan.FromMinutes(20));
        var hold=await scheduler.HoldForUpdateAsync(wait.Token);
        try
        {
            PathPolicy.RejectLinks(UpdateCache,updateFile);
            using var fileGuard=new FileStream(updateFile,FileMode.Open,FileAccess.Read,FileShare.Read);
            if(!await AppUpdateClient.VerifyAsync(updateFile,updateRelease,token))throw new InvalidDataException("설치 파일이 변경되었습니다. 다시 다운로드하세요.");
            token.ThrowIfCancellationRequested();
            var process=Process.Start(new ProcessStartInfo(updateFile){UseShellExecute=true}) ?? throw new IOException("설치 프로그램을 실행하지 못했습니다.");process.Dispose();
            updateBackupHold=hold;hold=null!;
            updateStatus="설치 프로그램을 실행했습니다. SafeSync를 종료합니다.";
            _=app.Dispatcher.BeginInvoke(new Action(()=>_=ExitAsync()));
        }
        finally{hold?.Dispose();}
    }
    private void ApplyUpdatePreferences()
    {
        if(automaticUpdateOperation && (!config.AutomaticallyCheckUpdates || !config.AutomaticallyDownloadUpdates))updateTransfer?.Cancel();
    }
    private async Task StopUpdatesAsync()
    {
        updateStartupTimer?.Stop();updateTimer?.Stop();updateLifetime.Cancel();
        if(updateTask!=null)await updateTask;
        updateClient.Dispose();updateLifetime.Dispose();
    }
}
