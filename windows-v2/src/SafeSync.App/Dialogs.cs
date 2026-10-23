using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private Window MessageWindow(string text,string title,bool confirm)
    {
        var window=new Window {Title=title,Width=560,MaxHeight=600,SizeToContent=SizeToContent.Height,Owner=Main.IsVisible ? Main : null,WindowStartupLocation=Main.IsVisible ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,FontFamily=new FontFamily("Segoe UI, Malgun Gothic"),ResizeMode=ResizeMode.NoResize};
        Theme.Apply(window,config.ThemeMode);
        window.Resources[typeof(Button)]=Main.Resources[typeof(Button)];
        window.SetResourceReference(Control.BackgroundProperty,"SafeSyncWindowBrush");
        var panel=new StackPanel {Margin=new Thickness(24)};
        panel.Children.Add(new ScrollViewer {MaxHeight=420,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Content=new TextBlock {Text=text,TextWrapping=TextWrapping.Wrap,Foreground=window.Foreground}});
        var buttons=new StackPanel {Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,18,0,0)};
        if(confirm) {var cancel=new Button {Content="취소",Padding=new Thickness(18,8,18,8),Margin=new Thickness(0,0,8,0)};cancel.Click+=(_,_)=>window.DialogResult=false;buttons.Children.Add(cancel);}
        var okay=new Button {Content=confirm ? "확인" : "닫기",Padding=new Thickness(18,8,18,8)};
        okay.SetResourceReference(Control.BackgroundProperty,"SafeSyncSurfaceBrush");okay.SetResourceReference(Control.ForegroundProperty,"SafeSyncTextBrush");okay.SetResourceReference(Control.BorderBrushProperty,"SafeSyncBorderBrush");
        okay.Click+=(_,_)=>window.DialogResult=true;buttons.Children.Add(okay);panel.Children.Add(buttons);window.Content=panel;
        return window;
    }
    private void Tell(string text,string title="SafeSync") {MessageWindow(text,title,false).ShowDialog();}
    private bool Confirm(string text) => MessageWindow(text,"SafeSync 확인",true).ShowDialog()==true;
    private Window NewDialog(string name,bool owner=true)
    {
        var window=Views.Load(name);Theme.Apply(window,config.ThemeMode);
        if(name is "Settings" or "JobEditor" or "CloudAccounts")window.Resources[typeof(Button)]=Main.Resources[typeof(Button)];
        if(smoke){window.ShowInTaskbar=false;window.WindowStartupLocation=WindowStartupLocation.Manual;window.Left=-32000;window.Top=-32000;}
        window.Icon=Main.Icon;if(owner && Main.IsVisible)window.Owner=auxiliary.LastOrDefault(w=>w.IsVisible && w.Owner!=null) ?? Main;
        auxiliary.Add(window);window.Closed+=(_,_)=>auxiliary.Remove(window);
        return window;
    }
    private void ShowSettings()
    {
        var window=NewDialog("Settings");
        BindUpdateSettings(window);
        window.Find<CheckBox>("AutoStartCheck").IsChecked=config.AutoStart;
        window.Find<CheckBox>("AutoStartCheck").IsEnabled=!smoke;
        window.Find<CheckBox>("AutoStartCheck").ToolTip="저장하면 현재 사용자 로그인 시 이 실행 파일을 시작합니다. 표준 1.x 자동 시작 항목은 전환하며, 수동 등록 항목은 별도로 확인하세요.";
        Click(window,"CloudAccountsButton",ShowCloudAccounts);
        window.Find<TextBox>("RetentionBox").Text=config.TrashRetentionDays.ToString();
        window.Find<CheckBox>("SoundOnMinimizeCheck").IsChecked=config.SoundOnMinimize;
        window.Find<CheckBox>("SoundOnBackupCompleteCheck").IsChecked=config.SoundOnBackupComplete;
        window.Find<CheckBox>("SoundOnBackupErrorCheck").IsChecked=config.SoundOnBackupError;
        window.Find<RadioButton>(config.ThemeMode=="Dark" ? "ThemeDarkRadio" : "ThemeLightRadio").IsChecked=true;
        Click(window,"CloseButton",window.Close);
        Click(window,"SaveButton",() =>
        {
            if(!int.TryParse(window.Find<TextBox>("RetentionBox").Text,out var days) || days is <1 or >3650){Tell("휴지통 보관 기간은 1~3650일입니다.");return;}
            config.TrashRetentionDays=days;scheduler.RetentionDays=days;
            config.SoundOnMinimize=window.Find<CheckBox>("SoundOnMinimizeCheck").IsChecked==true;
            config.SoundOnBackupComplete=window.Find<CheckBox>("SoundOnBackupCompleteCheck").IsChecked==true;
            config.SoundOnBackupError=window.Find<CheckBox>("SoundOnBackupErrorCheck").IsChecked==true;
            config.AutomaticallyCheckUpdates=window.Find<CheckBox>("AutoUpdateCheck").IsChecked==true;
            config.AutomaticallyDownloadUpdates=window.Find<CheckBox>("AutoDownloadCheck").IsChecked==true;
            ApplyUpdatePreferences();
            config.ThemeMode=window.Find<RadioButton>("ThemeDarkRadio").IsChecked==true ? "Dark" : "Light";
            try {if(!smoke)AutoStart.Set(window.Find<CheckBox>("AutoStartCheck").IsChecked==true,Environment.ProcessPath!);config.AutoStart=window.Find<CheckBox>("AutoStartCheck").IsChecked==true;store.Save(config);foreach(var open in auxiliary.Append(Main))Theme.Apply(open,config.ThemeMode);window.Close();Log("환경설정을 저장했습니다.");}
            catch(Exception ex){Tell(ex.Message,"설정 저장 실패");}
        });
        window.ShowDialog();
    }
    private void EditJob(BackupJob? existing)
    {
        if(existing!=null && scheduler.IsRunning(existing.Id)){Tell("백업이 끝난 뒤 작업 설정을 변경하세요.");return;}
        var window=NewDialog("JobEditor");
        window.Height=Math.Min(window.Height,SystemParameters.WorkArea.Height);
        window.Find<TextBox>("NameBox").Text=existing?.Name ?? "새 백업 작업";
        window.Find<TextBox>("SourceBox").Text=existing?.Source ?? "";
        window.Find<TextBox>("DestinationBox").Text=existing?.Destination ?? "";
        var type=window.Find<ComboBox>("DestinationTypeBox");
        type.SelectedIndex=existing?.DestinationType=="Dropbox" ? 1 : existing?.DestinationType=="GoogleDrive" ? 2 : 0;
        string cloudFolder=existing?.CloudFolderId ?? "",cloudAccount=existing?.CloudAccountId ?? "",cloudIdentity=existing?.CloudFolderIdentity ?? "";bool selectedCloudFolder=false;
        string Provider()=>((ComboBoxItem)type.SelectedItem).Tag.ToString()!;
        window.Find<TextBox>("DestinationBox").IsReadOnly=Provider()!="Local";
        type.SelectionChanged+=(_,_)=>{cloudFolder="";cloudAccount="";cloudIdentity="";window.Find<TextBox>("DestinationBox").Clear();window.Find<TextBox>("DestinationBox").IsReadOnly=Provider()!="Local";};
        window.Find<RadioButton>(existing?.TriggerType=="Scheduled" ? "ScheduleRadio" : "RealtimeRadio").IsChecked=true;
        window.Find<TextBox>("TimeBox").Text=existing?.ScheduleTime ?? "23:00";
        window.Find<CheckBox>("MirrorCheck").IsChecked=existing?.MirrorDeletes ?? false;
        var oneWay=window.Find<RadioButton>("OneWayRadio");var twoWay=window.Find<RadioButton>("TwoWayRadio");
        void ModeChanged()
        {
            bool both=twoWay.IsChecked==true;
            window.Find<TextBlock>("ModeHintText").Text=both ? "양방향: 양쪽 변경·삭제를 서로 반영합니다. 삭제 파일은 각 위치의 휴지통에 보관하며, 양쪽이 함께 바뀌면 충돌로 남깁니다." : "단방향: 원본의 변경을 백업 위치에 반영합니다.";
            window.Find<CheckBox>("MirrorCheck").IsEnabled=!both;
            window.Find<CheckBox>("MirrorCheck").Content=both ? "양쪽 삭제 반영 · 삭제 전 각 위치의 SafeSync 휴지통에 보관" : "원본에서 사라진 파일은 백업 위치의 SafeSync 휴지통으로 이동";
        }
        oneWay.Checked+=(_,_)=>ModeChanged();twoWay.Checked+=(_,_)=>ModeChanged();
        (existing?.SyncMode=="TwoWay" ? twoWay : oneWay).IsChecked=true;
        void Browse(string field)
        {
            var dialog=new Microsoft.Win32.OpenFolderDialog {Title=field=="SourceBox" ? "원본 폴더 선택" : "백업 폴더 선택",Multiselect=false};
            if(dialog.ShowDialog(window)==true)window.Find<TextBox>(field).Text=dialog.FolderName;
        }
        Click(window,"SourceBrowse",()=>Browse("SourceBox"));Click(window,"DestinationBrowse",()=>
        {
            if(Provider()=="Local"){Browse("DestinationBox");return;}
            var folder=ChooseCloudFolder(Provider(),window);if(folder==null)return;
            cloudFolder=folder.Reference;cloudAccount=folder.AccountId;cloudIdentity=folder.FolderIdentity;window.Find<TextBox>("DestinationBox").Text=folder.Display;
            selectedCloudFolder=true;
        });
        Click(window,"CancelButton",window.Close);
        Click(window,"SaveButton",() =>
        {
            var job=new BackupJob
            {
                Name=window.Find<TextBox>("NameBox").Text.Trim(),Source=window.Find<TextBox>("SourceBox").Text.Trim(),
                SyncMode=twoWay.IsChecked==true ? "TwoWay" : "OneWay",
                Destination=window.Find<TextBox>("DestinationBox").Text.Trim(),DestinationType=Provider(),CloudFolderId=cloudFolder,CloudAccountId=cloudAccount,CloudFolderIdentity=cloudIdentity,
                TriggerType=window.Find<RadioButton>("ScheduleRadio").IsChecked==true ? "Scheduled" : "Realtime",
                ScheduleTime=window.Find<TextBox>("TimeBox").Text.Trim(),MirrorDeletes=window.Find<CheckBox>("MirrorCheck").IsChecked==true,
                Paused=existing?.Paused ?? false,Stopped=existing?.Stopped ?? false,CloudBindingReviewRequired=(existing?.CloudBindingReviewRequired ?? false) && !selectedCloudFolder
            };
            if(existing!=null && !(existing.CloudBindingReviewRequired && selectedCloudFolder) && existing.SyncMode==job.SyncMode && string.Equals(existing.Source,job.Source,StringComparison.OrdinalIgnoreCase) && string.Equals(existing.Destination,job.Destination,StringComparison.OrdinalIgnoreCase) && existing.DestinationType==job.DestinationType && existing.CloudFolderId==job.CloudFolderId && existing.CloudAccountId==job.CloudAccountId && existing.CloudFolderIdentity==job.CloudFolderIdentity)job.Id=existing.Id;
            try
            {
                ConfigStore.ValidateJob(job);
                if(job.SyncMode=="TwoWay" && existing?.SyncMode!="TwoWay" && !Confirm("양방향 동기화에서는 백업 쪽에서 삭제한 파일도 원본에서 삭제되어 각 위치의 휴지통으로 이동합니다. 첫 실행은 양쪽 파일을 합치고 내용이 다르면 충돌로 남깁니다. 이 방식으로 저장할까요?"))return;
                var revised=config.Jobs.Where(j=>j!=existing).Append(job).ToList();
                var old=config.Jobs;config.Jobs=revised;
                try {store.Save(config);}catch{config.Jobs=old;throw;}
                RefreshJobs();scheduler.SetJobs(jobs);window.Close();Log(job.Name+": 작업 설정 저장");
            }
            catch(Exception ex){Tell(ex.Message,"작업 설정 확인");}
        });
        window.ShowDialog();
    }
    private sealed class JobListDocument
    {
        public string Format {get;set;}="SafeSyncJobList";
        public int Version {get;set;}=1;
        public string ExportedAtUtc {get;set;}=DateTime.UtcNow.ToString("O");
        public List<BackupJob> Jobs {get;set;}=[];
    }
    private void ExportJobs()
    {
        var dialog=new Microsoft.Win32.SaveFileDialog {Filter="SafeSync 작업 목록|*.safesync-jobs.json",FileName="SafeSync-jobs-"+DateTime.Now.ToString("yyyyMMdd")+".safesync-jobs.json"};
        if(dialog.ShowDialog(Main)!=true)return;
        var document=new JobListDocument {Jobs=jobs.Select(j=>new BackupJob {Id=j.Id,Name=j.Name,SyncMode=j.SyncMode,Source=j.Source,Destination=j.Destination,DestinationType=j.DestinationType,CloudFolderId=j.CloudFolderId,CloudFolderIdentity=j.CloudFolderIdentity,CloudAccountId=j.CloudAccountId,TriggerType=j.TriggerType,ScheduleTime=j.ScheduleTime,MirrorDeletes=j.MirrorDeletes,Paused=j.Paused,Stopped=j.Stopped,CloudBindingReviewRequired=j.CloudBindingReviewRequired}).ToList()};
        try {JsonFile.Save(dialog.FileName,document);Log("작업 목록 내보내기 완료 — 계정 정보와 스냅샷 제외");}catch(Exception ex){Tell(ex.Message);}
    }
    private void ImportJobs()
    {
        if(scheduler.RunningCount>0 || LegacyRunning()){Tell("백업이 끝나고 기존 1.x 앱을 종료한 뒤 가져오세요.");return;}
        var dialog=new Microsoft.Win32.OpenFileDialog {Title="1.x 작업 목록 또는 config.json 가져오기",Filter="JSON 작업/설정 파일|*.json"};
        if(dialog.ShowDialog(Main)!=true)return;
        if(!Confirm("기존 목록을 가져온 목록으로 교체할까요? 가져온 작업은 모두 일시정지합니다. config.json과 함께 있는 계정·스냅샷은 복사 승계하고 첫 실행에서 한 번 재확인합니다. 원본 1.x 자료는 수정하지 않습니다. 작업 목록만 가져오면 스냅샷은 포함되지 않습니다."))return;
        try
        {
            if(new FileInfo(dialog.FileName).Length>10*1024*1024)throw new InvalidDataException("파일은 10 MB 이하여야 합니다.");
            var document=JsonFile.Read<JobListDocument>(dialog.FileName);
            // A legacy config has no Format field; inspect the actual JSON marker.
            using var parsed=System.Text.Json.JsonDocument.Parse(File.ReadAllText(dialog.FileName,System.Text.Encoding.UTF8).TrimStart('\uFEFF'));
            if(parsed.RootElement.TryGetProperty("Format",out var marker) && marker.GetString()=="SafeSyncJobList")
            {
                if(document.Version!=1)throw new InvalidDataException("지원하지 않는 작업 목록 버전입니다.");
                var imported=new AppConfig {Jobs=document.Jobs,ThemeMode=config.ThemeMode,TrashRetentionDays=config.TrashRetentionDays};
                ConfigStore.Validate(imported);
                foreach(var job in imported.Jobs){job.Paused=true;job.Stopped=false;job.CloudBindingReviewRequired=job.DestinationType!="Local";}
                if(File.Exists(store.ConfigPath))File.Copy(store.ConfigPath,store.ConfigPath+".before-import-"+Guid.NewGuid().ToString("N"));
                config.Jobs=imported.Jobs;store.Save(config);
            }
            else {config=store.ImportLegacy(dialog.FileName);foreach(var job in config.Jobs.Where(j=>j.DestinationType!="Local"))job.CloudBindingReviewRequired=true;store.Save(config);}
            RefreshJobs();scheduler.SetJobs(jobs);scheduler.RetentionDays=config.TrashRetentionDays;Theme.Apply(Main,config.ThemeMode);Log($"작업 {jobs.Count}개 가져옴 — 모두 일시정지, 원본 설정 보존");
        }
        catch(Exception ex){Tell(ex.Message,"가져오기 실패");}
    }
    private void ShowTrash()
    {
        if(Selected is not {} job)return;
        if(job.DestinationType!="Local"){ShowCloudTrash(job);return;}
        ShowLocalTrash(job,job.Destination);
    }
    private void ShowLocalTrash(BackupJob job,string root)
    {
        if(!PrepareTrashWorkspace(job.Id+"|"+System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(job)+"|local|"+root))return;
        var window=NewDialog("Trash",false);
        var sourceTrash=root.Equals(job.Source,StringComparison.OrdinalIgnoreCase);
        var displayJob=sourceTrash ? new BackupJob {Id=job.Id+"-source-trash",Name=job.Name+" · 원본 휴지통",Source=job.Destination,Destination=root} : job;
        var grid=window.Find<DataGrid>("TrashGrid");
        var items=new ObservableCollection<TrashItem>();var cache=new TrashListCache<TrashItem>(store,displayJob);bool firstLoad=true;
        var presentation=new TrashBrowserPresentation<TrashItem>(window,items,item=>new(item.Name,item.OriginalPath,item.DeletedAt,item.Length),displayJob,config.TrashRetentionDays);
        window.Find<Button>("SourceTrashButton").Visibility=!sourceTrash ? Visibility.Visible : Visibility.Collapsed;
        Click(window,"SourceTrashButton",()=>ShowLocalTrash(job,job.Source));
        var status=window.Find<TextBlock>("StatusText");
        var service=new TrashService();var lifetime=new CancellationTokenSource();bool busy=false;
        auxiliaryTokens.Add(lifetime);
        void Buttons()
        {
            presentation.SetState(busy,jobs.Any(j=>ReferenceEquals(j,job)) && !scheduler.IsRunning(job.Id));
        }
        async Task LoadAsync()
        {
            if(busy)return;busy=true;
            if(firstLoad){firstLoad=false;var cached=await Task.Run(cache.Read);foreach(var row in cached)items.Add(row);status.Text=cached.Count>0 ? $"저장된 목록 {cached.Count:N0}개 · 현재 상태 확인 중…" : "휴지통 목록을 불러오는 중…";}
            else items.Clear();Buttons();
            try
            {
                await Task.Run(async ()=>
                {
                    var collected=new List<TrashItem>();
                    foreach(var row in service.List(root,lifetime.Token))collected.Add(row);
                    await app.Dispatcher.InvokeAsync(()=>items.Clear());
                    var batch=new List<TrashItem>(200);
                    foreach(var item in collected)
                    {
                        batch.Add(item);
                        if(batch.Count<200)continue;
                        var ready=batch.ToArray();batch.Clear();
                        await app.Dispatcher.InvokeAsync(()=>{if(!lifetime.IsCancellationRequested){foreach(var row in ready)items.Add(row);status.Text=$"{items.Count:N0}개 불러오는 중…";}});
                    }
                    var last=batch.ToArray();
                    await app.Dispatcher.InvokeAsync(()=>{if(!lifetime.IsCancellationRequested)foreach(var row in last)items.Add(row);});
                },lifetime.Token);
                var snapshot=items.ToArray();await Task.Run(()=>cache.Save(snapshot),lifetime.Token);status.Text=$"파일 {items.Count:N0}개";
            }
            catch(OperationCanceledException){}
            catch(Exception ex){status.Text="목록 확인 실패: "+ex.Message;}
            finally{busy=false;Buttons();}
        }
        async Task OperateAsync(bool restore)
        {
            var selected=grid.SelectedItems.Cast<TrashItem>().ToArray();
            if(busy || selected.Length==0)return;
            if(!jobs.Any(j=>ReferenceEquals(j,job))){status.Text="작업 설정이 변경되었습니다. 백업 작업 탭에서 휴지통을 다시 여세요.";Buttons();return;}
            if(scheduler.IsRunning(job.Id) || LegacyRunning()){status.Text="백업이 끝나고 기존 1.x 앱을 종료한 뒤 처리하세요.";return;}
            if(!restore && !Confirm($"선택한 {selected.Length}개 파일을 완전히 삭제할까요? 되돌릴 수 없습니다."))return;
            scheduler.SetPaused(job,true);Save();RefreshActions();Jobs.Items.Refresh();
            busy=true;trashWorkspaceOperating=true;Buttons();int done=0,failed=0;
            try
            {
                using var legacyLease=LegacyRunLease.Acquire();
                foreach(var item in selected)
                {
                    lifetime.Token.ThrowIfCancellationRequested();
                    try
                    {
                        if(restore)await Task.Run(()=>service.RestoreAsync(root,item,lifetime.Token),lifetime.Token);
                        else await Task.Run(()=>service.Delete(root,item),lifetime.Token);
                        items.Remove(item);done++;
                    }
                    catch(OperationCanceledException){throw;}
                    catch(Exception ex){failed++;Log(item.Name+": "+ex.Message);}
                    status.Text=$"{done+failed}/{selected.Length} 처리 중…";
                }
                var remaining=items.ToArray();await Task.Run(()=>cache.Save(remaining),lifetime.Token);
                status.Text=$"{(restore ? "복구" : "완전 삭제")} {done}개, 실패 {failed}개. 작업은 확인할 때까지 일시정지 상태입니다.";
            }
            catch(OperationCanceledException){}
            catch(Exception ex){status.Text="휴지통 처리 실패: "+ex.Message;}
            finally{busy=false;trashWorkspaceOperating=false;Buttons();}
        }
        Click(window,"CloseButton",()=>SelectWorkspace("MainTab"));Click(window,"RefreshButton",()=>TrackAuxiliary(LoadAsync()));
        Click(window,"SelectAllButton",()=>grid.SelectAll());Click(window,"RestoreButton",()=>TrackAuxiliary(OperateAsync(true)));Click(window,"DeleteButton",()=>TrackAuxiliary(OperateAsync(false)));
        grid.SelectionChanged+=(_,_)=>Buttons();window.Closed+=(_,_)=>lifetime.Cancel();
        ShowTrashWorkspace(window);TrackAuxiliary(LoadAsync());
    }
    private void ToggleProgress() {if(Main.Find<TabItem>("SyncWorkspaceTab").IsSelected)HideProgress();else ShowProgress();}
    private void ShowProgress()
    {
        if(progressWindow==null)
        {
            progressWindow=NewDialog("Progress",false);
            MountWorkspace(progressWindow,"SyncWorkspaceHost",600);
            progressWindow.Find<RowDefinition>("ProgressHistoryRow").Height=new GridLength(Clamp(config.WindowLayout.ProgressHistoryHeight,90,600,210));
            progressWindow.Find<DataGrid>("HistoryGrid").ItemsSource=sessionHistory.Runs;
            progressWindow.Find<DataGrid>("HistoryGrid").SelectionChanged+=(_,_)=>{if(!selectingHistory){followLatest=false;problemRequestedJob=null;}RefreshProgress();};
            progressWindow.Find<TabControl>("ProgressTabs").SelectionChanged+=(_,e)=>{if(ReferenceEquals(e.OriginalSource,progressWindow.Find<TabControl>("ProgressTabs")))RefreshProgress();};
            Click(progressWindow,"FollowLatestButton",()=>{followLatest=true;SelectRun(sessionHistory.Runs.FirstOrDefault());RefreshProgress();});
            Click(progressWindow,"ProgressPauseButton",ToggleRunPause);
            progressWindow.SizeChanged+=(_,_)=>LimitHistory();progressWindow.Find<Grid>("ProgressRoot").LayoutUpdated+=(_,_)=>LimitHistory();
            Click(progressWindow,"RetryLockedButton",RetrySelectedLocked);
            Click(progressWindow,"ResultResolveButton",()=>{if(RecoveryRunJob() is {} job)ShowJobRecovery(job);});
            Click(progressWindow,"ResultRetryButton",()=>{if(RecoveryRunJob() is {} job)TrackAuxiliary(RetryProblemAsync(job));});
            foreach(var (name,action) in new[]{("ConflictAllOverwriteButton",ConflictAction.Overwrite),("ConflictAllRenameButton",ConflictAction.KeepBoth),("ConflictAllIgnoreButton",ConflictAction.Ignore)})
                Click(progressWindow,name,()=>{foreach(var row in conflictRows.Where(r=>r.CanResolve))row.Action=action;progressWindow.Find<DataGrid>("ProgressConflictGrid").Items.Refresh();});
            progressWindow.Find<DataGrid>("ProgressConflictGrid").AddHandler(ButtonBase.ClickEvent,new RoutedEventHandler((_,e)=>
            {
                if(e.OriginalSource is Button {DataContext:ConflictRow {CanResolve:true} row} button && button.Tag is string tag)
                {
                    row.Action=tag=="Overwrite" ? ConflictAction.Overwrite : tag=="UseBackup" && row.CanUseBackup ? ConflictAction.UseBackup : tag=="RenameThenCopy" ? ConflictAction.KeepBoth : ConflictAction.Ignore;
                    progressWindow.Find<DataGrid>("ProgressConflictGrid").Items.Refresh();e.Handled=true;
                }
            }));
            Click(progressWindow,"ApplyConflictActionsButton",()=>{if(ComparisonRunJob() is {} job)ShowFileComparison(job,SelectedRun,(progressWindow.Find<DataGrid>("ProgressConflictGrid").SelectedItem as ConflictRow)?.Issue.File);});
            progressWindow.Find<DataGrid>("ProgressConflictGrid").MouseDoubleClick+=(_,_)=>{if(ComparisonRunJob() is {} job && progressWindow.Find<DataGrid>("ProgressConflictGrid").SelectedItem is ConflictRow row)ShowFileComparison(job,SelectedRun,row.Issue.File);};
            progressWindow.Find<DataGrid>("ProgressErrorGrid").MouseDoubleClick+=(_,_)=>{if(ComparisonRunJob() is {} job && progressWindow.Find<DataGrid>("ProgressErrorGrid").SelectedItem is FileIssue issue && !NetworkFailures.Automatic(issue))ShowFileComparison(job,SelectedRun,issue.File);};
            Click(progressWindow,"CompareErrorsButton",()=>{if(ComparisonRunJob() is {} job)ShowFileComparison(job,SelectedRun);});
        }
        Theme.Apply(progressWindow,config.ThemeMode);
        if(progressWindow.Find<DataGrid>("HistoryGrid").SelectedItem==null && problemRequestedJob==null)SelectRun(sessionHistory.Runs.FirstOrDefault());
        RefreshProgress();SelectWorkspace("SyncWorkspaceTab");
    }
    private readonly ObservableCollection<ConflictRow> conflictRows=[];
    public sealed class ConflictRow(FileIssue issue,bool canResolve=true,bool twoWay=false)
    {
        public FileIssue Issue {get;}=issue;
        private bool DuplicateName=>Issue.Reason.Contains("같은 이름의 항목이 여러 개",StringComparison.Ordinal) || Issue.Reason.Contains("중복 이름",StringComparison.Ordinal);
        public bool CanResolve=>canResolve && !DuplicateName;
        public bool CanUseBackup=>CanResolve && twoWay;
        public ConflictAction? Action {get;set;}
        public string FileDisplay=>Issue.JobName+"\n"+Issue.File;
        public string SourceInfo=>$"{Issue.SourceSize:N0} B\n{Issue.SourceModified}";
        public string BackupInfo=>$"{Issue.BackupSize:N0} B\n{Issue.BackupModified}";
        public string Reason=>Issue.Reason;
        public string ActionLabel=>DuplicateName ? "문제 해결에서 중복 이름 정리 · 사본 비교" : !CanResolve ? "이전 실행 기록 · 읽기 전용" : Action switch {ConflictAction.Overwrite=>"원본으로 덮어쓰기",ConflictAction.UseBackup=>"백업으로 원본 덮어쓰기",ConflictAction.KeepBoth=>"기존 이름 변경 후 복사",ConflictAction.Ignore=>"이번에는 변경 안 함",_=>"처리 방법을 선택하세요."};
    }
    private static string LocalTime(string value)=>DateTime.TryParse(value,out var time) ? time.ToLocalTime().ToString("MM-dd HH:mm:ss") : "—";
    private void RefreshProgress()
    {
        if(progressWindow is not {} window)return;
        window.Find<Border>("ProgressEndpoints").Visibility=window.Find<TabItem>("ProblemTab").IsSelected ? Visibility.Collapsed : Visibility.Visible;
        var run=SelectedRun;var currentJob=run==null ? problemRequestedJob : jobs.FirstOrDefault(j=>j.Id==run.JobId);
        int active=sessionHistory.Runs.Count(r=>r.IsActive),finished=sessionHistory.Runs.Count-active;
        window.Find<TextBlock>("SessionSummaryText").Text=$"진행 중 {active:N0} · 종료 {finished:N0} · 주의 이력 {sessionHistory.Runs.Count(r=>r.Outcome is SyncRunOutcome.Attention or SyncRunOutcome.Failed):N0}";
        window.Find<TextBlock>("HistoryCountText").Text=$"{sessionHistory.Runs.Count:N0}회 · 이번 프로그램 실행";
        window.Find<TextBlock>("HistoryEmptyText").Visibility=sessionHistory.Runs.Count==0 ? Visibility.Visible : Visibility.Collapsed;
        window.Find<TextBlock>("SourceSummaryPath").Text=run?.Source ?? "작업 이력을 선택하세요.";
        window.Find<TextBlock>("DestinationSummaryPath").Text=run?.Destination ?? "—";
        window.Find<TextBlock>("DirectionText").Text=run?.SyncMode=="TwoWay" ? "↔" : "→";
        window.Find<TextBlock>("SourceSummaryDetail").Text=run==null ? "원본" : run.JobName+" · 원본";
        window.Find<TextBlock>("DestinationSummaryDetail").Text=run?.DestinationType switch {"GoogleDrive"=>"Google Drive · 백업 위치","Dropbox"=>"Dropbox · 백업 위치",_=>"로컬·네트워크 · 백업 위치"};
        window.Find<TextBlock>("ActiveSummaryText").Text=run?.Outcome==SyncRunOutcome.Stopping ? "종료 중…" : run?.Outcome==SyncRunOutcome.Waiting ? "대기 중" : run?.IsActive==true ? "진행 상황" : "실행 결과";
        window.Find<ItemsControl>("ProgressItems").ItemsSource=run?.IsActive==true ? new[]{new {run.JobName,run.ProgressText,run.StageText,FileText=run.CurrentFile,run.Percent,IsIndeterminate=run.TotalFiles<=0}} : null;
        window.Find<StackPanel>("ResultSummaryPanel").Visibility=run?.IsActive==true ? Visibility.Collapsed : Visibility.Visible;
        window.Find<TextBlock>("ResultTitleText").Text=run?.StatusText ?? "작업을 기다리고 있습니다.";
        window.Find<TextBlock>("ResultTitleText").SetResourceReference(TextBlock.ForegroundProperty,run?.Tone switch {"Success"=>"SafeSyncSuccessTextBrush","Danger"=>"SafeSyncDangerBrush","Warning"=>"SafeSyncWarningBrush",_=>"SafeSyncTextBrush"});
        window.Find<TextBlock>("ResultDetailText").Text=run?.Summary ?? "실행한 작업의 진행 상황과 결과를 이 창에서 확인할 수 있습니다.";
        bool recoverable=run!=null && !run.IsActive && currentJob!=null && sessionHistory.IsLatest(run) && (run.Outcome==SyncRunOutcome.Failed || run.Errors.Count+run.Conflicts.Count>0);
        window.Find<WrapPanel>("ResultRecoveryActions").Visibility=recoverable ? Visibility.Visible : Visibility.Collapsed;
        window.Find<Button>("ResultResolveButton").IsEnabled=recoverable;
        window.Find<Button>("ResultRetryButton").IsEnabled=recoverable && !scheduler.IsRunning(run!.JobId);
        window.Find<TextBlock>("HistoryHintText").Text=run==null ? "" : $"시작 {run.StartedUtc.ToLocalTime():yyyy-MM-dd HH:mm:ss} · 종료 {(run.EndedUtc?.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") ?? "진행 중")} · 경과 {run.DurationText}\n선택한 실행 시점의 결과입니다. 이후의 백업 상태는 최신 이력을 확인하세요.";
        window.Find<Button>("ProgressPauseButton").IsEnabled=run?.IsActive==true && currentJob!=null && !currentJob.Stopped;
        window.Find<Button>("ProgressPauseButton").Visibility=run?.IsActive==true && run.Outcome!=SyncRunOutcome.Stopping ? Visibility.Visible : Visibility.Collapsed;
        window.Find<Button>("ProgressPauseButton").Content=currentJob?.Paused==true ? "다시 시작" : "일시정지";
        var locked=run?.IsActive==true ? restoredLocked.GetValueOrDefault(run.JobId,[]) : run?.Locked ?? restoredLocked.Values.SelectMany(v=>v).ToArray();
        window.Find<TextBlock>("LockedSummaryText").Text=$"사용 중 파일 {locked.Count:N0}개 · "+(currentJob?.Stopped==true ? "작업 종료 대기 중에는 자동 재시도하지 않습니다." : "최신 실행의 대기 파일은 자동 재시도됩니다.");
        window.Find<TextBlock>("LockedTabHeader").Text=$"사용 중 {locked.Count:N0}";
        window.Find<DataGrid>("ProgressLockedGrid").ItemsSource=locked.Select(i=>new {FileDisplay=i.JobName+"\n"+i.File,StatusText=i.Reason,WaitingSince=LocalTime(i.WaitingSinceUtc),RetryCount=i.RetryCount.ToString()+"회",LastAttempt=i.LastAttemptUtc.Length>0 ? LocalTime(i.LastAttemptUtc) : run?.EndedText ?? "—"}).ToArray();
        window.Find<Button>("RetryLockedButton").IsEnabled=run!=null ? sessionHistory.IsLatest(run) && !run.IsActive && locked.Count>0 && currentJob?.Paused==false : Selected?.Paused==false && restoredLocked.GetValueOrDefault(Selected.Id,[]).Length>0;
        var errors=(run?.Errors ?? Array.Empty<FileIssue>()).ToList();
        if(run?.FailureReason.Length>0)errors.Add(new(run.JobId,run.JobName,"[작업]",run.FailureReason,0,0,"","",AutomaticNetworkRetry:run.AutomaticNetworkRetry));
        window.Find<DataGrid>("ProgressErrorGrid").ItemsSource=errors;
        window.Find<TextBlock>("ErrorsTabHeader").Text=$"오류 {errors.Count:N0}";
        int networkErrors=errors.Count(NetworkFailures.Automatic);
        window.Find<TextBlock>("ErrorSummaryText").Text=errors.Count==0 ? "이 실행에서 기록된 오류가 없습니다." : networkErrors>0 ? $"오류 {errors.Count:N0}개 · 일시적 네트워크 {networkErrors:N0}개는 자동 재시도됩니다. 과거 이력은 당시 기록입니다." : $"오류 {errors.Count:N0}개 · 원인을 확인한 뒤 해당 작업을 다시 실행하세요.";
        window.Find<Button>("CompareErrorsButton").IsEnabled=ComparisonRunJob()!=null && errors.Any(i=>!NetworkFailures.Automatic(i));
        var choices=conflictRunId==run?.RunId ? conflictRows.ToDictionary(r=>r.Issue.JobId+"|"+r.Issue.File,r=>r.Action) : new Dictionary<string,ConflictAction?>();
        conflictRunId=run?.RunId ?? "";
        bool canResolve=run!=null && !run.IsActive && sessionHistory.IsLatest(run) && currentJob!=null;
        conflictRows.Clear();
        foreach(var issue in run?.Conflicts ?? Array.Empty<FileIssue>())conflictRows.Add(new(issue,canResolve,currentJob?.SyncMode=="TwoWay"){Action=choices.GetValueOrDefault(issue.JobId+"|"+issue.File)});
        window.Find<DataGrid>("ProgressConflictGrid").ItemsSource=conflictRows;
        window.Find<TextBlock>("ConflictSummaryText").Text=$"확인이 필요한 파일 {conflictRows.Count}개";
        window.Find<TextBlock>("ConflictTabHeader").Text=$"충돌 {conflictRows.Count:N0}";
        foreach(var name in new[]{"ConflictAllOverwriteButton","ConflictAllRenameButton","ConflictAllIgnoreButton","ApplyConflictActionsButton"})window.Find<Button>(name).IsEnabled=canResolve && conflictRows.Any(r=>r.CanResolve);
        window.Find<Button>("ApplyConflictActionsButton").IsEnabled=ComparisonRunJob()!=null && conflictRows.Count>0;
        window.Find<TextBlock>("ProblemTabHeader").Text=$"문제 해결 {conflictRows.Count+errors.Count-networkErrors:N0}";
        if(window.Find<TabItem>("ProblemTab").IsSelected)
        {
            if(currentJob!=null)EnsureProblemWorkspace(currentJob,run);
            else ClearProblemWorkspace();
        }
        else if(problemPanel!=null && problemContextKey.Length>0)
        {
            // Release old decisions immediately on history changes, even when
            // the resolution tab is hidden; don't fetch metadata off-screen.
            if(currentJob==null || problemContextKey.Split('|')[1]!=(run?.RunId ?? ""))ClearProblemWorkspace();
        }
    }
    private async Task ApplyConflictsAsync()
    {
        var selectedRun=SelectedRun;
        if(selectedRun==null || selectedRun.IsActive || !sessionHistory.IsLatest(selectedRun)){Tell("이전 실행 기록에서는 충돌 처리를 적용하지 않습니다. 최신 결과를 선택하세요.");return;}
        foreach(var group in conflictRows.Where(r=>r.CanResolve && r.Action!=null).GroupBy(r=>r.Issue.JobId).ToArray())
        {
            var job=jobs.FirstOrDefault(j=>j.Id==group.Key);if(job==null)continue;
            if(scheduler.IsRunning(job.Id)){Tell("현재 백업이 끝난 뒤 적용하세요.");continue;}
            if(job.Paused){Tell("작업의 일시정지를 해제한 뒤 적용하세요.");continue;}
            followLatest=true;await RunAsync(job,false,group.ToDictionary(r=>r.Issue.File,r=>r.Action!.Value,StringComparer.OrdinalIgnoreCase));
        }
    }
    internal async Task<int> SmokeTestAsync(string? previewDirectory)
    {
        int assertions=0;
        void Check(bool condition,string message){if(!condition)throw new InvalidOperationException(message);assertions++;}
        ShowMain();
        Check(Main.Find<TextBlock>("FooterText").Text=="Windows "+AppVersion,"Version footer still contains migration terminology");
        Check(!Main.Find<TextBox>("ActivityBox").Text.Contains("이전 PowerShell 버전과 설정 공간을 분리했습니다"),"Startup log still exposes obsolete migration terminology");
        foreach(var mode in new[]{"Light","Dark"})
        {
            config.ThemeMode=mode;Theme.Apply(Main,mode);Main.UpdateLayout();
            Check(Jobs.Columns.Count==6,"메인 작업 표 구조가 달라졌습니다.");
            Check(!Main.Find<Button>("RunButton").IsEnabled,"빈 작업 목록에서 백업이 활성화되었습니다.");
            foreach(var name in new[]{"Main","Settings","JobEditor","Progress","Trash","CloudAccounts","Updates"})
            {
                Window window;
                if(name=="Updates"){ShowUpdates();window=updateWindow!;}
                else window=name=="Main" ? Main : NewDialog(name,false);
                Theme.Apply(window,mode);window.Show();window.UpdateLayout();
                await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                Check(window.ActualWidth>0 && window.ActualHeight>0,name+" 화면이 표시되지 않습니다.");
                Check(((SolidColorBrush)window.Background).Color==((SolidColorBrush)window.Resources["SafeSyncWindowBrush"]).Color,name+" 배경에 테마가 적용되지 않았습니다.");
                if(name=="CloudAccounts")
                {
                    Check(!window.Find<Expander>("DropboxDeveloperSettings").IsExpanded && !window.Find<TextBox>("DropboxKey").IsVisible,"일반 연결 화면에 Dropbox App Key 입력이 노출됩니다.");
                    Check(window.Find<Button>("DropboxConnect").Content.ToString()=="Dropbox로 로그인" && window.Find<TextBlock>("DropboxLoginHint").Text.Contains("공식 로그인"),"Dropbox 브라우저 로그인 안내가 없습니다.");
                    Check(window.Find<Button>("DropboxValidate").Content.ToString()=="연결 검증" && window.Find<Button>("GoogleValidate").Content.ToString()=="연결 검증","Windows 클라우드 연결 검증 버튼이 없습니다.");
                    Check(window.Find<Border>("ValidationPanel").Visibility==Visibility.Collapsed,"검증 전 결과 영역이 표시됩니다.");
                    Check(window.Find<ScrollViewer>("AccountsScroll").ScrollableHeight<1,"기본 크기에서 클라우드 연결 버튼이 스크롤 아래로 가려집니다.");
                }
                if(previewDirectory!=null)
                {
                    Directory.CreateDirectory(previewDirectory);
                    var bitmap=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(window);
                    var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var stream=File.Create(Path.Combine(previewDirectory,name+"-"+mode+".png"));encoder.Save(stream);
                }
                if(name!="Main")window.Close();
            }
        }
        void CheckModal(Action open,Action<Window> verify)
        {
            Exception? failure=null;bool inspected=false;
            var timer=new System.Windows.Threading.DispatcherTimer {Interval=TimeSpan.FromMilliseconds(80)};
            timer.Tick+=(_,_)=>
            {
                timer.Stop();var dialog=auxiliary.LastOrDefault(w=>w.IsVisible);
                try{if(dialog==null)throw new InvalidOperationException("설정 창이 열리지 않았습니다.");verify(dialog);inspected=true;}
                catch(Exception ex){failure=ex;}
                finally{dialog?.Close();}
            };
            timer.Start();try{open();}finally{timer.Stop();}
            if(failure!=null)throw failure;
            Check(inspected,"설정 버튼 동작이 검사되지 않았습니다.");
        }
        var toolbarAssertions=await TestWorkspaceToolbarAsync(previewDirectory,CheckModal);
        assertions+=toolbarAssertions;
        Check(AutoStart.Command(@"C:\Apps\Safe Sync\SafeSync.exe")=="\"C:\\Apps\\Safe Sync\\SafeSync.exe\"","공백이 있는 자동 시작 경로의 인용이 잘못되었습니다.");
        bool unsafeStartup=false;try{AutoStart.Command("C:\\Apps\\unsafe\".exe");}catch(ArgumentException){unsafeStartup=true;}Check(unsafeStartup,"잘못된 자동 시작 경로가 허용되었습니다.");
        CheckModal(ShowSettings,w=>
        {
            Check(w.Find<Button>("CloudAccountsButton").IsEnabled,"클라우드 연결 화면이 비활성화되었습니다.");
            Check(w.FindName("OpenUpdatesButton")==null && w.Find<Button>("CheckUpdatesButton").Content.ToString()=="업데이트 확인","환경설정에 중복 업데이트 진입 버튼이 있습니다.");
            Check(!w.Find<CheckBox>("AutoStartCheck").IsEnabled,"검증본이 기존 자동 시작 등록을 변경할 수 있습니다.");
            Check(w.Find<TextBox>("RetentionBox").Text==config.TrashRetentionDays.ToString(),"보관 기간이 설정과 다릅니다.");
            Check(w.Find<CheckBox>("AutoUpdateCheck").IsChecked==config.AutomaticallyCheckUpdates && w.Find<CheckBox>("AutoDownloadCheck").IsChecked==config.AutomaticallyDownloadUpdates,"업데이트 환경설정 초기값이 일치하지 않습니다.");
            w.Height=w.MinHeight;w.UpdateLayout();
            var save=w.Find<Button>("SaveButton");
            Check(save.TransformToAncestor(w).Transform(new Point()).Y+save.ActualHeight<w.ActualHeight,"작은 환경설정 창에서 저장 버튼이 가려집니다.");
        });
        ShowUpdates();var update=updateWindow!;
        Check(update.IsVisible && Main.IsEnabled,"업데이트 창이 메인 창 사용을 막습니다.");
        Check(!update.Find<Button>("UpdateInstallButton").IsEnabled && !update.Find<Button>("UpdateDownloadButton").IsEnabled,"검증된 배포 정보 없이 다운로드/설치 버튼이 활성화되었습니다.");
        update.Find<Button>("UpdateCheckButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if(updateTask!=null)await updateTask;
        Check(update.Find<TextBlock>("UpdateStatusText").Text.Contains("화면 검사"),"업데이트 확인 버튼이 동작하지 않거나 UI 검사가 외부 통신을 했습니다.");
        update.Width=update.MinWidth;update.Height=update.MinHeight;update.UpdateLayout();
        foreach(var name in new[]{"UpdateCheckButton","UpdateDownloadButton","UpdateInstallButton","UpdateCancelButton","UpdateCloseButton"})
        {
            var button=update.Find<Button>(name);var position=button.TransformToAncestor(update).Transform(new Point());
            Check(position.X>=0 && position.X+button.ActualWidth<=update.ActualWidth && position.Y+button.ActualHeight<update.ActualHeight,"작은 업데이트 창에서 버튼이 가려집니다: "+name);
        }
        update.Find<Button>("UpdateCloseButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Check(updateWindow==null && !update.IsVisible,"업데이트 창을 닫을 수 없습니다.");
        CheckModal(()=>EditJob(null),w=>
        {
            Check(w.Find<TextBox>("NameBox").Text=="새 백업 작업","작업 초기값을 설정하지 못했습니다.");
            Check(w.Find<RadioButton>("OneWayRadio").IsChecked==true,"기존 작업의 기본 방향이 단방향이 아닙니다.");
            w.Find<RadioButton>("TwoWayRadio").IsChecked=true;
            Check(!w.Find<CheckBox>("MirrorCheck").IsEnabled && w.Find<TextBlock>("ModeHintText").Text.Contains("양방향"),"양방향 삭제 안내 또는 옵션 상태가 잘못되었습니다.");
            w.Find<RadioButton>("OneWayRadio").IsChecked=true;
            Check(w.Find<CheckBox>("MirrorCheck").IsEnabled,"단방향으로 돌아온 뒤 삭제 옵션이 잠겼습니다.");
            w.Height=480;w.UpdateLayout();
            var savePosition=w.Find<Button>("SaveButton").TransformToAncestor(w).Transform(new Point());
            Check(savePosition.Y+w.Find<Button>("SaveButton").ActualHeight<w.ActualHeight,"작은 화면에서 작업 저장 버튼이 가려집니다.");
            Check(w.Find<ComboBox>("DestinationTypeBox").SelectedIndex==0,"기본 백업 방식이 잘못되었습니다.");
            Check(w.Find<ComboBox>("DestinationTypeBox").Items.OfType<ComboBoxItem>().Skip(1).All(i=>i.IsEnabled),"클라우드 백업 방식을 선택할 수 없습니다.");
            w.Find<ComboBox>("DestinationTypeBox").SelectedIndex=2;
            Check(w.Find<TextBox>("DestinationBox").IsReadOnly,"클라우드 폴더에 검증되지 않은 경로를 입력할 수 있습니다.");
        });
        CheckModal(ShowCloudAccounts,w=>
        {
            Check(w.Find<Button>("GoogleConnect").IsEnabled && w.Find<Button>("DropboxConnect").IsEnabled,"계정 연결 버튼이 비활성화되었습니다.");
            Check(!w.Find<Button>("GoogleValidate").IsEnabled && !w.Find<Button>("DropboxValidate").IsEnabled,"연결되지 않은 계정의 검증 버튼이 활성화되었습니다.");
            Check(w.Find<TextBlock>("GoogleStatus").Text=="연결되지 않음","격리 UI 검사가 실제 계정을 읽었습니다.");
            Check(w.Find<TextBox>("DropboxKey").Text==PublicCloudRegistration.DropboxAppKey,"기본 Dropbox 키가 자동 적용되지 않았습니다.");
            w.Find<Expander>("DropboxDeveloperSettings").IsExpanded=true;w.UpdateLayout();
            Check(w.Find<TextBox>("DropboxKey").IsVisible,"필요할 때 개발자 설정을 열 수 없습니다.");
            w.Find<TextBox>("DropboxKey").Clear();w.Find<Button>("SaveCredentials").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(CloudAccounts.Read(config).Dropbox.AppKey==PublicCloudRegistration.DropboxAppKey && w.Find<TextBox>("DropboxKey").Text==PublicCloudRegistration.DropboxAppKey,"빈 Dropbox 키 저장이 기본 연결 설정을 지웠습니다.");
        });
        Check(jobs.Count==0,"취소한 작업이 저장되었습니다.");
        ShowProgress();Check(WorkspaceVisual(progressWindow!).IsVisible && Main.IsEnabled && Window.GetWindow(WorkspaceVisual(progressWindow!))==Main,"동기화 상태가 메인 탭에 표시되지 않습니다.");
        ToggleProgress();Check(!WorkspaceVisual(progressWindow!).IsVisible,"백업 작업 탭으로 돌아갈 수 없습니다.");
        ToggleProgress();Check(WorkspaceVisual(progressWindow!).IsVisible,"동기화 탭을 다시 열 수 없습니다.");
        HideProgress();
        var uiSource=Path.Combine(store.Root,"smoke-source");var uiBackup=Path.Combine(store.Root,"smoke-backup");
        Directory.CreateDirectory(uiSource);Directory.CreateDirectory(uiBackup);
        var uiTrash=TrashService.NewPath(uiBackup,"example.txt","deleted");Directory.CreateDirectory(Path.GetDirectoryName(uiTrash)!);File.WriteAllText(uiTrash,"sample");
        config.Jobs=[new BackupJob {Name="UI smoke job",Source=uiSource,Destination=uiBackup,Paused=true}];RefreshJobs();
        Check(Main.Find<MenuItem>("StopJobMenuItem").IsEnabled,"작업 종료 메뉴가 비활성화되었습니다.");
        Main.Find<MenuItem>("StopJobMenuItem").RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        Check(Selected!.Stopped && !Selected.Paused && Selected.Status=="대기 중" && Main.Find<Button>("RunButton").IsEnabled,"작업 종료가 일시정지가 아닌 대기/작업 시작 상태를 표시하지 않았습니다.");
        Check(!Main.Find<MenuItem>("StopJobMenuItem").IsEnabled && Main.Find<Button>("PauseButton").Content.ToString()=="▶ 작업 시작","종료한 작업의 메뉴 상태가 잘못되었습니다.");
        Check(store.Load().Jobs.Single().Stopped,"종료 대기 설정이 저장되지 않았습니다.");
        Check(scheduler.ResumeJob(Selected),"UI 검사의 종료 대기 해제 실패");scheduler.SetPaused(Selected,true);Save();RefreshActions();
        ShowTrash();var trashWindow=auxiliary.Last(w=>w.FindName("TrashGrid")!=null);
        for(int i=0;i<100 && trashWindow.Find<DataGrid>("TrashGrid").Items.Count==0;i++)await Task.Delay(25);
        Check(trashWindow.Find<DataGrid>("TrashGrid").Items.Count==1,"실제 휴지통 창이 비동기 목록을 표시하지 못했습니다.");
        Check(Main.IsEnabled && !trashWindow.IsVisible && Window.GetWindow(WorkspaceVisual(trashWindow))==Main,"휴지통이 별도 창으로 표시됩니다.");
        var mountedTrash=WorkspaceVisual(trashWindow);SelectWorkspace("MainTab");ShowTrash();
        Check(ReferenceEquals(WorkspaceVisual(trashWindow),mountedTrash) && Main.Find<TabItem>("TrashWorkspaceTab").IsSelected,"탭 전환만으로 휴지통을 다시 읽습니다.");
        SelectWorkspace("MainTab");Main.Height=540;Main.Width=800;Main.UpdateLayout();
        var splitter=Main.Find<GridSplitter>("MainLayoutSplitter");
        Check(splitter.ResizeDirection==GridResizeDirection.Rows && splitter.ResizeBehavior==GridResizeBehavior.PreviousAndNext,"활동 기록 분할 방향이 잘못되었습니다.");
        var activityRow=Main.Find<RowDefinition>("MainActivityRow");activityRow.Height=new GridLength(90);Main.UpdateLayout();CaptureLayout();
        var beforeDrag=activityRow.ActualHeight;splitter.ShowsPreview=false;
        splitter.RaiseEvent(new DragStartedEventArgs(0,0));splitter.RaiseEvent(new DragDeltaEventArgs(0,-24));splitter.RaiseEvent(new DragCompletedEventArgs(0,-24,false));Main.UpdateLayout();splitter.ShowsPreview=true;CaptureLayout();
        Check(activityRow.ActualHeight>beforeDrag+10,"활동 기록 구분선의 실제 드래그가 높이를 바꾸지 않습니다.");
        Check(Math.Abs(store.Load().WindowLayout.MainActivityHeight-activityRow.ActualHeight)<1,"활동 기록 높이가 저장되지 않습니다.");
        var log=Main.Find<TextBox>("ActivityBox");var footer=Main.Find<TextBlock>("FooterText");
        Check(log.ActualHeight>10 && footer.TransformToAncestor(Main).TransformBounds(new Rect(footer.RenderSize)).Bottom<Main.ActualHeight,"작은 메인창에서 활동 기록 또는 상태줄이 가려집니다.");
        Check(Main.FindName("ResolveJobButton")==null,"메인 문제 해결 아이콘이 남아 있습니다.");
        Main.Width=1180;Main.Height=900;Main.UpdateLayout();
        Check(app.Windows.OfType<Window>().Count(w=>w.IsVisible)==1,"동기화·휴지통이 별도 창을 표시합니다.");
        // Keep trash open to exercise cancellation and window cleanup on exit.
        assertions+=await TestProgressRenderingAsync(previewDirectory);
        assertions+=await TestSessionHistoryAsync(previewDirectory);
        assertions+=await TestTrashBrowserAsync(previewDirectory);
        assertions+=await TestCloudPickerAsync(previewDirectory);
        assertions+=await TestReleaseUiAsync();
        assertions+=await TestRecoveryUiAsync(previewDirectory);
        assertions+=await TestFailureRecoveryAsync(previewDirectory);
        assertions+=await TestFileComparisonUiAsync(previewDirectory);
        assertions+=await TestDeferredResolutionUiAsync();
        assertions+=TestNetworkRetryUi();
        config.ThemeMode="Light";
        return assertions;
    }
}
