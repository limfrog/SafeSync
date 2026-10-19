using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SafeSync.Core;
using SafeSync.Core.Cloud;
using Forms = System.Windows.Forms;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private static string AppVersion=>typeof(DesktopController).Assembly.GetCustomAttributes(false).OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion.Split('+')[0] ?? "1.0.0-preview.1";
    private readonly Application app;
    private readonly ConfigStore store;
    private AppConfig config;
    private readonly BackupScheduler scheduler;
    private readonly CloudServices cloud;
    private readonly Forms.NotifyIcon tray;
    private readonly System.Drawing.Icon trayIcon;
    private readonly List<System.Drawing.Icon> frames=[];
    private readonly DispatcherTimer trayTimer;
    private readonly ObservableCollection<BackupJob> jobs=[];
    private readonly Dictionary<string,BackupProgress> progress=[];
    private readonly Dictionary<string,BackupResult> results=[];
    private readonly SyncSessionHistory sessionHistory=new();
    private bool followLatest=true,selectingHistory;
    private string conflictRunId="";
    private DateTimeOffset lastHistoryTick=DateTimeOffset.MinValue;
    private readonly HashSet<string> notices=[];
    private readonly NoticeLedger noticeLedger;
    private readonly JobProblemStore problemStore;
    private readonly ActivityLog activityLog;
    private readonly List<Window> auxiliary=[];
    private readonly HashSet<Task> auxiliaryTasks=[];
    private readonly List<System.Threading.CancellationTokenSource> auxiliaryTokens=[];
    private Window? progressWindow;
    private bool exiting;
    private int animationFrame;
    private readonly bool smoke;
    public Window Main { get; }
    private DataGrid Jobs => Main.Find<DataGrid>("JobsGrid");
    private BackupJob? Selected => Jobs.SelectedItem as BackupJob;

    public DesktopController(Application app,ConfigStore store,bool smoke)
    {
        this.app=app;this.store=store;this.smoke=smoke;
        config=store.Load();noticeLedger=new(store.Root);activityLog=new(store.Root);problemStore=new(store.Root);
        foreach(var notice in noticeLedger.Entries)notices.Add(notice.JobId+"|"+notice.File+"|"+notice.Message);
        Main=Views.Load("Main");Main.Title="SafeSync · "+AppVersion;
        if(smoke){Main.ShowInTaskbar=false;Main.WindowStartupLocation=WindowStartupLocation.Manual;Main.Left=-32000;Main.Top=-32000;}
        Theme.Apply(Main,config.ThemeMode);
        Main.Width=Clamp(config.WindowLayout.MainWidth,800,2200,1180);
        Main.Height=Clamp(config.WindowLayout.MainHeight,540,1400,720);
        Main.Find<RowDefinition>("MainActivityRow").Height=new GridLength(Clamp(config.WindowLayout.MainActivityHeight,64,600,155));
        using (var resource = Application.GetResourceStream(new Uri("pack://application:,,,/SafeSync;component/Assets/SafeSync.ico")).Stream)
        {
            trayIcon=(System.Drawing.Icon)new System.Drawing.Icon(resource).Clone();
        }
        var image = BitmapDecoder.Create(new Uri("pack://application:,,,/SafeSync;component/Assets/SafeSync.ico"),BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnLoad).Frames.OrderByDescending(f=>f.PixelWidth).First();
        Main.Icon=image;Main.Find<Image>("BrandImage").Source=image;
        tray=new Forms.NotifyIcon {Icon=trayIcon,Text="SafeSync 1.0.0 Preview",Visible=!smoke};
        var menu=new Forms.ContextMenuStrip();
        menu.Items.Add("SafeSync 열기",null,(_,_) => app.Dispatcher.Invoke(ShowMain));
        menu.Items.Add("모든 작업 백업",null,(_,_) => app.Dispatcher.Invoke(() => RunAll()));
        menu.Items.Add("프로그램 종료",null,async (_,_) => await app.Dispatcher.InvokeAsync(ExitAsync).Task.Unwrap());
        tray.ContextMenuStrip=menu;tray.DoubleClick += (_,_) => app.Dispatcher.Invoke(ShowMain);
        foreach (var file in Directory.EnumerateFiles(Path.Combine(AppContext.BaseDirectory,"Assets"),"SafeSync-Progress-*.ico").Order())
            frames.Add(new System.Drawing.Icon(file));
        cloud=new CloudServices(()=>config);
        scheduler=new BackupScheduler(store) {RetentionDays=config.TrashRetentionDays,AcquireRunLease=LegacyRunLease.Acquire,CloudFactory=cloud.ForJob};
        scheduler.Progress += value => app.Dispatcher.BeginInvoke(() => OnProgress(value));
        scheduler.Started += job=>app.Dispatcher.BeginInvoke(()=>OnStarted(job));
        scheduler.Completed += (job,result) => app.Dispatcher.BeginInvoke(() => OnCompleted(job,result));
        scheduler.Failed += (job,error) => app.Dispatcher.BeginInvoke(() => OnFailed(job,error));
        scheduler.StateChanged += job=>app.Dispatcher.BeginInvoke(()=>
        {
            if(job.Stopped)job.Status=job.CloudBindingReviewRequired ? "클라우드 연결 확인 필요" : scheduler.IsRunning(job.Id) ? "종료 중…" : "대기 중";
            RefreshActions();Jobs.Items.Refresh();RefreshProgress();RefreshRecoveryWindows();
        });
        trayTimer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(160)};
        trayTimer.Tick += (_,_) =>
        {
            var historyNow=DateTimeOffset.UtcNow;if(historyNow-lastHistoryTick>=TimeSpan.FromSeconds(1)){lastHistoryTick=historyNow;sessionHistory.Tick(historyNow);}
            bool active=scheduler.RunningCount>0;
            tray.Icon=active && frames.Count>0 ? frames[animationFrame++ % frames.Count] : notices.Count>0 ? System.Drawing.SystemIcons.Warning : trayIcon;
            tray.Text=active ? "SafeSync - 백업 진행 중" : notices.Count>0 ? "SafeSync - 확인할 메시지 있음" : "SafeSync 1.0.0 Preview";
            Main.Find<TextBlock>("ServiceBadge").Text=active ? $"● 작업 {scheduler.RunningCount}개 진행 중" : "● 전환 검증본 · 로컬/클라우드";
        };
        WireMain();RestoreKnownProblems();RefreshJobs();
        Log("SafeSync "+AppVersion+" 시작 — 이전 PowerShell 버전과 설정 공간을 분리했습니다.");
        Log("클라우드 API·승계 기능 검증본 — 실제 계정은 테스트용 백업 폴더부터 확인하세요. 변경 기록을 사용할 수 없는 위치는 안전한 메타데이터 확인으로 대체합니다.");
        if(!smoke && config.AutoStart){try{AutoStart.Set(true,Environment.ProcessPath!);}catch(Exception ex){Log("자동 시작 갱신 실패: "+ex.Message);}}
        if (!smoke) { scheduler.SetJobs(jobs);scheduler.Start();trayTimer.Start();TrackAuxiliary(LoadWaitingAsync()); }
    }
    private static double Clamp(double value,double min,double max,double fallback) => double.IsFinite(value) ? Math.Clamp(value,min,max) : fallback;
    private void WireMain()
    {
        Click(Main,"AddButton",() => EditJob(null));Click(Main,"MenuAddJobItem",() => EditJob(null));
        Click(Main,"EditButton",() => { if(Selected is {} job) EditJob(job); });
        Click(Main,"DeleteButton",DeleteJob);
        Click(Main,"RunButton",() => { if(Selected is {} job) _=RunAsync(job); });
        Click(Main,"FullScanButton",() => { if(Selected is {} job) _=RunAsync(job,true); });
        Click(Main,"RebindCloudJobMenuItem",()=>{if(Selected is {} job)PrepareCloudJob(job,true);});
        Click(Main,"ResolveJobMenuItem",()=>{if(Selected is {} job)ShowJobRecovery(job);});
        Click(Main,"RunAllButton",RunAll);
        Click(Main,"StopJobMenuItem",()=>
        {
            if(Selected is not {} job)return;
            scheduler.StopJob(job);sessionHistory.SetStopping(job.Id);
            job.Status=scheduler.IsRunning(job.Id) ? "종료 중…" : "대기 중";
            Save();RefreshActions();Jobs.Items.Refresh();RefreshProgress();
            Log(job.Name+": 현재 파일의 검증·교체를 마친 뒤 작업 종료. 자동 감시·예약 실행은 다시 시작할 때까지 대기합니다.");
        });
        Click(Main,"PauseButton",() =>
        {
            if(Selected is not {} job)return;
            if(job.Stopped){_=RunAsync(job);return;}
            if(CloudJobBinding.NeedsReview(config,job)){_=RunAsync(job);return;}
            scheduler.SetPaused(job,!job.Paused);sessionHistory.SetPaused(job.Id,job.Paused);Save();RefreshActions();Jobs.Items.Refresh();RefreshProgress();
            Log(job.Name + (job.Paused ? ": 일시정지" : ": 다시 시작"));
        });
        Click(Main,"SettingsButton",ShowSettings);Click(Main,"SettingsShortcutButton",ShowSettings);
        Click(Main,"MenuProgressItem",ToggleProgress);
        Click(Main,"TrashButton",ShowTrash);
        Click(Main,"MenuMessagesItem",ShowNotices);Click(Main,"NotificationsButton",ShowNotices);
        Click(Main,"MenuExportJobsItem",ExportJobs);Click(Main,"MenuImportJobsItem",ImportJobs);
        Click(Main,"MenuAboutItem",() => Tell($"SafeSync {AppVersion}\n제작자: 임호\nlimfrog75@gmail.com\n\nC#/.NET 기반 전환 검증본입니다. 아직 1.9.15 대체용이 아닙니다.","SafeSync 정보"));
        Click(Main,"MenuExitItem",() => _=ExitAsync());
        Click(Main,"MenuCloudAccountsItem",ShowCloudAccounts);
        var jobMenu=Main.Find<Button>("JobActionsButton");
        jobMenu.Click += (_,_) => { jobMenu.ContextMenu.PlacementTarget=jobMenu;jobMenu.ContextMenu.IsOpen=true; };
        foreach (var item in jobMenu.ContextMenu.Items.OfType<MenuItem>())
            item.Click += (_,_) => Main.Find<MenuItem>((string)item.Tag).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Jobs.ItemsSource=jobs;Jobs.SelectionChanged += (_,_) => RefreshActions();
        Jobs.MouseDoubleClick += (_,e) =>
        {
            if(Selected is not {} job)return;
            var cell=Ancestor<DataGridCell>(e.OriginalSource as DependencyObject);
            if(cell?.Column.Header?.ToString()=="상태"){ShowJobRecovery(job);return;}
            if(cell?.Column.Header?.ToString() is "원본 위치" or "백업 위치")
            {
                var path=cell.Column.Header.ToString()=="원본 위치" ? job.Source : job.Destination;
                if(job.DestinationType!="Local" && cell.Column.Header.ToString()=="백업 위치")return;
                if(Directory.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe",Quote(path)) {UseShellExecute=true});
            }
        };
        Main.Closing += (_,e) => { if(exiting)return;e.Cancel=true;HideMain(); };
        Main.StateChanged += (_,_) => { if(Main.WindowState==WindowState.Minimized)HideMain(); };
        Main.SizeChanged += (_,_) => LimitActivity();
        Main.Find<Grid>("MainLayoutRoot").LayoutUpdated += (_,_) => LimitActivity();
        WireWorkspace();
    }
    private static T? Ancestor<T>(DependencyObject? element) where T : DependencyObject
    {
        while(element!=null) {if(element is T match)return match;element=VisualTreeHelper.GetParent(element);}return null;
    }
    private static string Quote(string value) => "\""+value.TrimEnd('\\')+"\"";
    internal static void Click(FrameworkElement window,string name,Action action)
    {
        if(window.FindName(name) is ButtonBase button)button.Click += (_,_) => action();
        else window.Find<MenuItem>(name).Click += (_,_) => action();
    }
    public void ShowMain()
    {
        Main.Show();Main.WindowState=WindowState.Normal;Main.Activate();
    }
    private void HideMain()
    {
        CaptureLayout();Main.Hide();
        if(!smoke && config.SoundOnMinimize)System.Media.SystemSounds.Asterisk.Play();
    }
    private void LimitActivity()
    {
        var root=Main.Find<Grid>("MainLayoutRoot");
        if(!root.IsVisible || root.ActualHeight<=0)return;
        if(VisualTreeHelper.GetParent(root) is not FrameworkElement viewport || viewport.ActualHeight<=0)return;
        var row=Main.Find<RowDefinition>("MainActivityRow");
        double fixedHeight=root.RowDefinitions.Where((_,i)=>i!=1 && i!=3).Sum(r=>r.ActualHeight);
        var limit=Math.Max(64,viewport.ActualHeight-root.Margin.Top-root.Margin.Bottom-fixedHeight-90);
        if(Math.Abs(row.MaxHeight-limit)>.5)row.MaxHeight=limit;
        if(row.Height.IsAbsolute && row.Height.Value>limit)row.Height=new GridLength(limit);
    }
    private void CaptureLayout()
    {
        if(Main.WindowState==WindowState.Normal) {config.WindowLayout.MainWidth=Main.Width;config.WindowLayout.MainHeight=Main.Height;}
        if(Main.Find<Grid>("MainLayoutRoot").IsVisible)config.WindowLayout.MainActivityHeight=Main.Find<RowDefinition>("MainActivityRow").ActualHeight;
        if(progressWindow is {} p)
        {
            config.WindowLayout.ProgressHistoryHeight=p.Find<RowDefinition>("ProgressHistoryRow").ActualHeight;
        }
        Save();
    }
    private void RefreshJobs()
    {
        string? id=Selected?.Id;jobs.Clear();
        foreach(var job in config.Jobs)
        {
            job.Status=job.CloudBindingReviewRequired ? "클라우드 연결 확인 필요" : job.Stopped ? scheduler.IsRunning(job.Id) ? "종료 중…" : "대기 중" : job.Paused ? "일시정지" : problemStore.Get(job.Id)!=null ? "확인 필요" : "대기 중";
            jobs.Add(job);
        }
        Jobs.SelectedItem=jobs.FirstOrDefault(j=>j.Id==id) ?? jobs.FirstOrDefault();
        Main.Find<TextBlock>("JobCountText").Text=$"작업 {jobs.Count}개";
        Main.Find<FrameworkElement>("EmptyJobsHint").Visibility=jobs.Count==0 ? Visibility.Visible : Visibility.Collapsed;
        Main.Find<TextBlock>("FooterText").Text=$"Windows {AppVersion} · C#/.NET 전환 검증본";
        RefreshActions();
    }
    private void RefreshActions()
    {
        var job=Selected;bool selected=job!=null;bool local=selected;
        bool stopping=job?.Stopped==true && scheduler.IsRunning(job.Id);
        foreach(var name in new[]{"EditButton","DeleteButton","TrashButton"})Main.Find<MenuItem>(name).IsEnabled=selected && (name!="TrashButton" || local);
        Main.Find<MenuItem>("FullScanButton").IsEnabled=local && job?.Paused==false && !stopping;
        Main.Find<MenuItem>("StopJobMenuItem").IsEnabled=selected && job?.Stopped==false;
        Main.Find<MenuItem>("RebindCloudJobMenuItem").IsEnabled=selected && job!.DestinationType!="Local" && !scheduler.IsRunning(job.Id);
        Main.Find<MenuItem>("ResolveJobMenuItem").IsEnabled=selected;
        foreach(var name in new[]{"JobActionsButton","PauseButton"})Main.Find<Button>(name).IsEnabled=selected;
        Main.Find<Button>("RunButton").IsEnabled=local && (job?.Paused==false || job?.Stopped==true) && !stopping;
        Main.Find<Button>("PauseButton").IsEnabled=selected && !stopping;
        Main.Find<Button>("PauseButton").Content=job?.Stopped==true ? "▶ 작업 시작" : job?.Paused==true ? "▶ 다시 시작" : "Ⅱ 일시정지";
        Main.Find<Button>("PauseButton").ToolTip=job?.Stopped==true ? "종료 대기 중인 작업을 새 실행으로 시작합니다." : "현재 실행을 일시정지하거나 이어서 진행합니다.";
        foreach(var item in Main.Find<Button>("JobActionsButton").ContextMenu.Items.OfType<MenuItem>())item.IsEnabled=Main.Find<MenuItem>((string)item.Tag).IsEnabled;
    }
    private void Save()
    {
        try { store.Save(config); }
        catch(Exception ex) { Log("설정 저장 실패: "+ex.Message);notices.Add("설정 저장 실패|"+ex.Message);UpdateNotices(); }
    }
    private bool LegacyRunning()
    {
        if(LegacyRunLease.OwnedByThisProcess)return false;
        try { using var mutex=System.Threading.Mutex.OpenExisting("Local\\SafeSync.Launch");return true; }
        catch(System.Threading.WaitHandleCannotBeOpenedException) {return false;}
    }
    private async Task RunAsync(BackupJob job,bool full=false,IReadOnlyDictionary<string,ConflictAction>? resolutions=null)
    {
        if(!smoke && LegacyRunning()) {Tell("기존 PowerShell 버전 SafeSync를 종료한 뒤 이 프리뷰의 백업을 실행하세요. 같은 백업 위치를 두 프로그램이 동시에 변경하지 않도록 막았습니다.");return;}
        var prepared=PrepareCloudJob(job);if(prepared==null)return;
        // Decisions made for conflicts at the old endpoint are not authority
        // to overwrite/download files at a newly selected endpoint.
        if(prepared.Id!=job.Id)resolutions=null;
        job=prepared;
        if(job.Stopped){if(!scheduler.ResumeJob(job))return;Save();RefreshActions();}
        else if(job.Paused){scheduler.SetPaused(job,false);Save();RefreshActions();}
        if(!smoke && Main.IsVisible && Main.WindowState==WindowState.Normal)ShowProgress();
        job.Status="실행 중";Jobs.Items.Refresh();RefreshActions();RefreshRecoveryWindows();
        try {await scheduler.RunAsync(job,full,resolutions);}
        catch(Exception ex){OnFailed(job,ex);}
    }
    private void RunAll()
    {
        if(LegacyRunning()){Tell("기존 SafeSync 1.x를 완전히 종료한 뒤 실행하세요.");return;}
        foreach(var job in jobs.Where(j=>!j.Paused && !j.Stopped))_=RunAsync(job);
    }
    private void OnProgress(BackupProgress value)
    {
        if(jobs.FirstOrDefault(j=>j.Id==value.JobId) is {} historyJob)RecordRun(()=>sessionHistory.Progress(historyJob,value));
        progress[value.JobId]=value;
        if(jobs.FirstOrDefault(j=>j.Id==value.JobId) is {} job)job.Status=job.Stopped ? "종료 중…" : job.Paused ? "일시정지" : value.Stage;
        Jobs.Items.Refresh();RefreshProgress();
    }
    private void OnCompleted(BackupJob job,BackupResult result)
    {
        RememberResultProblem(job,result);
        RecordRun(()=>sessionHistory.Complete(job,result));
        results[job.Id]=result;restoredLocked[job.Id]=result.Locked.ToArray();progress.Remove(job.Id);
        job.Status=job.Stopped ? "대기 중" : result.Canceled ? "중단됨" : result.Errors.Count>0 ? "오류 있음" : result.Conflicts.Count>0 ? "충돌 확인" : result.Locked.Count>0 ? "사용 중 파일 대기" : "완료";
        Log($"{job.Name}: 복사 {result.Copied}, 동일 {result.Skipped}, 충돌 {result.Conflicts.Count}, 사용 중 {result.Locked.Count}, 오류 {result.Errors.Count}");
        int newNotices=noticeLedger.Apply(job.Id,result);
        notices.Clear();foreach(var notice in noticeLedger.Entries)notices.Add(notice.JobId+"|"+notice.File+"|"+notice.Message);
        if(!smoke && newNotices>0 && result.Errors.Count>0 && config.SoundOnBackupError && Main.IsVisible && Main.WindowState==WindowState.Normal)System.Media.SystemSounds.Exclamation.Play();
        else if(!smoke && !result.Canceled && result.Errors.Count==0 && config.SoundOnBackupComplete && Main.IsVisible && Main.WindowState==WindowState.Normal)System.Media.SystemSounds.Asterisk.Play();
        Jobs.Items.Refresh();UpdateNotices();RefreshProgress();RefreshActions();RefreshRecoveryWindows();Save();
    }
    private void OnFailed(BackupJob job,Exception ex)
    {
        RememberProblem(job,JobProblem.From(ex,job.DestinationType!="Local"));
        RecordRun(()=>sessionHistory.Fail(job,ex));
        progress.Remove(job.Id);job.Status="실패";Log(job.Name+": "+ex.Message);
        if(ex is CloudBindingException && job.DestinationType!="Local")
        {job.CloudBindingReviewRequired=true;scheduler.StopJob(job);job.Status="클라우드 연결 확인 필요";Save();RefreshActions();}
        bool fresh=noticeLedger.Add(job.Id,ex.Message);
        notices.Remove(job.Id+"|"+ex.Message);
        var visibleNotice=noticeLedger.Entries.FirstOrDefault(n=>n.JobId==job.Id && n.File.Length==0 && n.Message==ex.Message);
        if(visibleNotice!=null)notices.Add(NoticeKey(visibleNotice));
        UpdateNotices();Jobs.Items.Refresh();RefreshProgress();RefreshActions();RefreshRecoveryWindows();
        if(!smoke && fresh && config.SoundOnBackupError && Main.IsVisible && Main.WindowState==WindowState.Normal)System.Media.SystemSounds.Exclamation.Play();
    }
    private void UpdateNotices()
    {
        var button=Main.Find<Button>("NotificationsButton");button.Content=$"확인할 메시지 {notices.Count}";button.IsEnabled=notices.Count>0;
        RefreshMessages();
    }
    private void Log(string text)
    {
        try{activityLog.Append(text);}catch(Exception ex) when(ex is IOException or UnauthorizedAccessException){text+=" [로그 저장 실패: "+ex.Message+"]";}
        var box=Main.Find<TextBox>("ActivityBox");box.AppendText(DateTime.Now.ToString("HH:mm:ss")+"  "+text+Environment.NewLine);
        if(box.Text.Length>100000)box.Text=box.Text[^70000..];box.ScrollToEnd();
    }
    private void DeleteJob()
    {
        if(Selected is not {} job)return;
        if(scheduler.IsRunning(job.Id)){Tell("백업 중인 작업은 종료 후 삭제하세요.");return;}
        if(!Confirm($"'{job.Name}' 작업을 목록에서 삭제할까요? 실제 파일은 삭제하지 않습니다."))return;
        config.Jobs.Remove(job);Save();RefreshJobs();scheduler.SetJobs(jobs);
    }
    public async Task ExitAsync()
    {
        if(exiting)return;exiting=true;Main.IsEnabled=false;
        ClearProblemWorkspace();
        foreach(var token in auxiliaryTokens)token.Cancel();
        await scheduler.DisposeAsync();
        try{await Task.WhenAll(auxiliaryTasks.ToArray());}catch(Exception ex){Log("종료 중 보조 작업 확인: "+ex.Message);}
        CaptureLayout();
        trayTimer.Stop();tray.Visible=false;tray.Dispose();
        foreach(var frame in frames)frame.Dispose();trayIcon.Dispose();
        foreach(var window in auxiliary.ToArray())window.Close();progressWindow?.Close();Main.Close();
        foreach(var token in auxiliaryTokens)token.Dispose();auxiliaryTokens.Clear();
        cloud.Dispose();
        app.Shutdown();
    }
    private void TrackAuxiliary(Task task)
    {
        auxiliaryTasks.Add(task);_=ObserveAsync();
        async Task ObserveAsync()
        {
            try{await task;}catch(Exception ex){Log("보조 작업 확인: "+ex.Message);}
            finally{auxiliaryTasks.Remove(task);}
        }
    }
}
