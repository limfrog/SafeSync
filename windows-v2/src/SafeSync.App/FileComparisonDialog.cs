using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
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
    private sealed class ComparisonRow(FileIssue issue,string kind):INotifyPropertyChanged
    {
        public FileIssue Issue {get;}=issue;
        public string Kind {get;}=kind;
        public string Name=>IsFile ? Path.GetFileName(Issue.File) : "작업 연결 · 오류 해결";
        public FileComparison? Snapshot {get;set;}
        private ConflictAction? action;
        public ConflictAction? Action {get=>action;set{action=value;PropertyChanged?.Invoke(this,new(nameof(ActionText)));}}
        public string ActionText=>!IsFile ? "연결·권한·실행 안내" : Action switch{ConflictAction.Overwrite=>"→ 원본으로 백업 덮어쓰기",ConflictAction.UseBackup=>"← 백업으로 원본 덮어쓰기",ConflictAction.KeepBoth=>"두 사본 모두 보관",ConflictAction.Ignore=>"이번 동기화에서 제외",ConflictAction.NormalizeDuplicates=>"중복 이름만 정리 · 사본 보존",_=>"처리 방법 미선택"};
        public event PropertyChangedEventHandler? PropertyChanged;
        public bool IsFile {get{try{return Kind!="작업 안내" && Issue.File is not ("[작업]" or "[휴지통 정리]") && !PathPolicy.Internal(PathPolicy.Relative(Issue.File));}catch(Exception ex) when(ex is ArgumentException or InvalidDataException){return false;}}}
    }

    private FrameworkElement? problemPanel;
    private BackupJob? problemRequestedJob;
    private string problemContextKey="";
    private Action? releaseProblemPanel;
    private void ClearProblemWorkspace()
    {
        releaseProblemPanel?.Invoke();releaseProblemPanel=null;problemPanel=null;problemContextKey="";
        if(progressWindow!=null)progressWindow.Find<ContentControl>("ProblemWorkspaceHost").Content=null;
    }
    private FrameworkElement EnsureProblemWorkspace(BackupJob job,SyncRun? run,string? selectedFile=null)
    {
        string key=$"{job.Id}|{run?.RunId}|{System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(job)}|{job.Source}|{job.Destination}|{job.DestinationType}|{job.CloudAccountId}|{job.CloudFolderId}|{run?.IsActive}|{run?.Conflicts.Count}|{run?.Errors.Count}|{run?.FailureReason}|{problemStore.Get(job.Id)?.Message}";
        if(problemPanel==null || problemContextKey!=key)
        {
            ClearProblemWorkspace();problemContextKey=key;
            problemPanel=CreateComparisonPanel(job,run);
            progressWindow!.Find<ContentControl>("ProblemWorkspaceHost").Content=problemPanel;
        }
        var list=problemPanel.Find<ListBox>("ComparisonFiles");
        if(selectedFile!=null)list.SelectedItem=list.Items.OfType<ComparisonRow>().FirstOrDefault(r=>r.Issue.File==selectedFile) ?? list.Items.OfType<ComparisonRow>().FirstOrDefault();
        else if(list.SelectedItem==null)list.SelectedItem=list.Items.OfType<ComparisonRow>().FirstOrDefault();
        return problemPanel;
    }
    private FrameworkElement ShowFileComparison(BackupJob job,SyncRun? run=null,string? selectedFile=null)
    {
        run ??= sessionHistory.Runs.FirstOrDefault(r=>r.JobId==job.Id);
        ShowProgress();problemRequestedJob=job;followLatest=false;SelectRun(run);RefreshProgress();
        progressWindow!.Find<TabItem>("ProblemTab").IsSelected=true;
        return EnsureProblemWorkspace(job,run,selectedFile);
    }
    private FrameworkElement CreateComparisonPanel(BackupJob job,SyncRun? run)
    {
        var window=Views.LoadElement("FileComparison");
        var rows=new ObservableCollection<ComparisonRow>();
        foreach(var issue in run?.Conflicts ?? Array.Empty<FileIssue>())rows.Add(new(issue,"충돌"));
        foreach(var issue in run?.Errors ?? Array.Empty<FileIssue>())if(!rows.Any(r=>r.Issue.File==issue.File))rows.Add(new(issue,"오류"));
        if(rows.Count==0 && problemStore.Get(job.Id) is {File.Length:>0} problem)rows.Add(new(new(job.Id,job.Name,problem.File,problem.Message,0,0,"",""),"오류"));
        rows.Add(new(new(job.Id,job.Name,"[작업]",run?.FailureReason.Length>0 ? run.FailureReason : problemStore.Get(job.Id)?.Message ?? "작업 연결과 실행 상태를 확인합니다.",0,0,"",""),"작업 안내"));
        var list=window.Find<ListBox>("ComparisonFiles");list.ItemsSource=rows;
        var lifetime=new CancellationTokenSource();auxiliaryTokens.Add(lifetime);CancellationTokenSource? selectionToken=null;
        bool busy=false,applying=false,closed=false;
        bool IsLatest()=>run!=null && sessionHistory.IsLatest(run) && !run.IsActive && jobs.Any(j=>ReferenceEquals(j,job)) &&
            run.Source==job.Source && run.Destination==job.Destination && run.DestinationType==job.DestinationType && run.SyncMode==job.SyncMode;
        bool Writable()=>IsLatest() && !scheduler.IsRunning(job.Id) && !closed;
        bool CanRepair()=>!closed && jobs.Any(j=>ReferenceEquals(j,job)) && (run==null || (sessionHistory.IsLatest(run) && run.Source==job.Source && run.Destination==job.Destination && run.DestinationType==job.DestinationType && run.SyncMode==job.SyncMode));
        var recoveryPanel=CreateRecoveryPanel(job,run,CanRepair);
        window.Find<ContentControl>("RecoveryDetailsHost").Content=recoveryPanel;
        ComparisonRow[] SelectedRows()=>list.SelectedItems.OfType<ComparisonRow>().ToArray();
        void Text(string name,string value)=>window.Find<TextBlock>(name).Text=value;
        void Buttons()
        {
            var selected=SelectedRows();bool ready=Writable() && !busy && selected.Length>0 && selected.All(r=>r.IsFile && r.Snapshot!=null);
            window.Find<Button>("CompareForwardButton").IsEnabled=ready && selected.All(r=>r.Snapshot!.CanForward);
            window.Find<Button>("CompareReverseButton").IsEnabled=ready && selected.All(r=>r.Snapshot!.CanReverse);
            window.Find<Button>("CompareKeepBothButton").IsEnabled=ready && selected.All(r=>r.Snapshot!.CanForward && r.Snapshot.Backup is {Exists:true,Folder:false});
            window.Find<Button>("CompareIgnoreButton").IsEnabled=Writable() && !applying && selected.Length>0 && selected.All(r=>r.IsFile);
            window.Find<Button>("CompareDuplicatesButton").IsEnabled=ready && selected.All(r=>r.Snapshot!.Readable && r.Snapshot.Duplicates is {Groups.Length:>0});
            window.Find<Button>("CompareApplyButton").IsEnabled=Writable() && !busy && rows.Any(r=>r.Action!=null);
            window.Find<Button>("CompareRefreshButton").IsEnabled=!busy && selected.Length>0;
            Text("ComparisonSummary",$"{job.Name} · 충돌 {rows.Count(r=>r.Kind=="충돌")} · 오류 {rows.Count(r=>r.Kind=="오류")+(run?.FailureReason.Length>0 ? 1 : 0)} · 선택한 처리 {rows.Count(r=>r.Action!=null)}개"+(run==null ? " · 작업 연결 안내" : run.IsActive ? " · 실행 중 / 파일 처리는 완료 후 선택" : IsLatest() ? "" : " · 이전 실행 기록 / 읽기 전용"));
        }
        static string Date(string? value)=>DateTime.TryParse(value,out var date) && date.Year>1601 ? date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "제공되지 않음";
        void Side(string prefix,ComparedFile? file,string error,bool historical,FileIssue issue)
        {
            bool source=prefix=="Source";
            bool? exists=historical ? source ? issue.SourceExists : issue.BackupExists : file!=null;
            Text("Compare"+prefix+"Size",error.Length>0 ? "확인 불가" : exists==false ? "없음" : historical && exists==null && (source ? issue.SourceSize : issue.BackupSize)==0 ? "기록 없음" : file?.Folder==true ? "폴더" : $"{(historical ? source ? issue.SourceSize : issue.BackupSize : file?.Length ?? 0):N0} B");
            Text("Compare"+prefix+"Created",exists==false ? "—" : !source && job.DestinationType=="Dropbox" ? "생성일시 정보 없음" : Date(historical ? source ? issue.SourceCreated : issue.BackupCreated : file?.Created));
            Text("Compare"+prefix+"Modified",exists==false ? "—" : Date(historical ? source ? issue.SourceModified : issue.BackupModified : file?.Modified));
            Text("Compare"+prefix+"State",error.Length>0 ? "확인 불가 · "+error : historical ? "선택한 실행 당시 기록" : file==null ? "파일이 없습니다." : file.Folder ? "폴더 · 파일 덮어쓰기 불가" : !file.Binary ? "일반 파일이 아님 · 덮어쓰기 불가" : "파일 정보를 확인했습니다.");
        }
        void Display(ComparisonRow row)
        {
            string sourceRoot=run?.Source ?? job.Source,backupRoot=run?.Destination ?? job.Destination;
            window.Find<ContentControl>("RecoveryDetailsHost").Visibility=row.IsFile ? Visibility.Collapsed : Visibility.Visible;
            window.Find<StackPanel>("FileDetailsPanel").Visibility=row.IsFile ? Visibility.Visible : Visibility.Collapsed;
            window.Find<StackPanel>("ComparisonActionsPanel").Visibility=row.IsFile ? Visibility.Visible : Visibility.Collapsed;
            Text("ComparisonReason",row.Issue.Reason);
            // Display paths without querying the network or resolving links on
            // the UI thread. Actual reads/mutations use the strict PathPolicy.
            Text("CompareSourcePath",row.IsFile ? Path.Combine(sourceRoot,row.Issue.File.Replace('/',Path.DirectorySeparatorChar)) : sourceRoot);
            Text("CompareBackupPath",row.IsFile ? job.DestinationType=="Local" ? Path.Combine(backupRoot,row.Issue.File.Replace('/',Path.DirectorySeparatorChar)) : backupRoot.TrimEnd('/','\\')+" / "+row.Issue.File : backupRoot);
            bool historical=!IsLatest();
            Side("Source",row.Snapshot?.Source,row.Snapshot?.SourceError ?? "",historical,row.Issue);
            Side("Backup",row.Snapshot?.Backup,row.Snapshot?.BackupError ?? "",historical,row.Issue);
            if(!historical && row.Snapshot==null)foreach(var side in new[]{"Source","Backup"})foreach(var field in new[]{"Size","Created","Modified","State"})Text("Compare"+side+field,row.IsFile ? "확인 중…" : "파일별 정보 없음");
            if(!historical && row.Snapshot==null && row.Action==ConflictAction.Ignore)foreach(var side in new[]{"Source","Backup"})foreach(var field in new[]{"Size","Created","Modified","State"})Text("Compare"+side+field,"이번 실행 제외 · 정보 확인 생략");
            Text("ComparisonStatus",historical ? "과거 결과는 현재 파일에 적용할 수 없습니다. 최신 작업 결과를 선택하세요." : !row.IsFile ? "계정·연결·권한 오류는 아래 ‘연결 · 권한 문제 해결’에서 처리하세요." : row.Snapshot==null ? "파일 정보를 확인하는 중입니다…" : "표시된 생성·수정일시는 이 컴퓨터의 현지 시각입니다. 적용 직전에 파일 정보를 다시 검사합니다.");
            Text("ComparisonChoiceHint",SelectedRows().Length>1 ? $"선택한 {SelectedRows().Length}개 파일에 같은 방법을 지정합니다." : row.ActionText+" · 처리 방법을 고른 뒤 적용하세요.");
            var plan=row.Snapshot?.Duplicates;
            Text("ComparisonDuplicatesText",plan==null ? "" : "중복 경로가 있습니다. 아래 ID 순서의 첫 사본을 현재 백업으로 표시합니다. 처리 적용 시 나머지 사본(폴더는 내부 파일 전체)은 같은 위치의 .SafeSync-conflict- 이름으로 보존합니다. 삭제하지 않습니다.\n"+string.Join("\n",plan.Groups.Select(g=>g.Relative+"\n"+string.Join("\n",g.Items.Select((i,index)=>$"  {(index==0 ? "사용" : "이름 보존")} · ID {i.Id} · {(i.Folder ? "폴더" : i.Length.ToString("N0")+" B")} · 생성 {Date(i.CreatedUtc.ToString("O"))} · 수정 {Date(i.ModifiedUtc.ToString("O"))}")))));
        }
        async Task LoadSelectedAsync(bool refresh=false)
        {
            selectionToken?.Cancel();selectionToken=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);var token=selectionToken.Token;
            var selected=SelectedRows();if(selected.Length==0){busy=false;Buttons();return;}
            Display(selected[0]);busy=true;Buttons();
            if(!window.IsVisible){busy=false;Buttons();return;}
            try
            {
                foreach(var row in selected)
                {
                    if(!IsLatest() || !row.IsFile || (!refresh && row.Snapshot!=null))continue;
                    // Network and filesystem metadata must never block the UI thread.
                    var snapshot=await Task.Run(async()=>await FileComparisons.ReadAsync(job,row.Issue.File,job.DestinationType=="Local" ? null : cloud.ForJob(job),token),token);
                    token.ThrowIfCancellationRequested();
                    row.Snapshot=snapshot;if(refresh)row.Action=null;
                }
                if(!closed && SelectedRows().FirstOrDefault() is {} current)Display(current);
            }
            catch(OperationCanceledException){}
            catch(Exception ex){if(!closed && !token.IsCancellationRequested)Text("ComparisonStatus","파일 정보를 불러오지 못했습니다: "+ex.Message+" · 연결·권한 문제 해결을 확인하세요.");}
            finally{if(!token.IsCancellationRequested && !closed){busy=false;Buttons();}}
        }
        void Choose(ConflictAction action)
        {
            if(!Writable() || applying || (busy && action!=ConflictAction.Ignore))return;
            if(busy){selectionToken?.Cancel();busy=false;}
            foreach(var row in SelectedRows())if(row.IsFile && (action==ConflictAction.Ignore || row.Snapshot!=null))row.Action=action;
            if(SelectedRows().FirstOrDefault() is {} currentRow)Display(currentRow);Buttons();
        }
        async Task ApplyAsync()
        {
            if(!Writable() || busy){Text("ComparisonStatus","현재 작업이 실행 중이거나 최신 결과가 아닙니다. 최신 결과에서 다시 선택하세요.");Buttons();return;}
            var selected=rows.Where(r=>r.Action!=null).ToArray();if(selected.Length==0)return;
            string summary=string.Join("\n",selected.GroupBy(r=>r.Action).Select(g=>$"{g.First().ActionText}: {g.Count()}개"));
            var duplicateGroups=selected.Where(r=>r.Action!=ConflictAction.Ignore).SelectMany(r=>r.Snapshot?.Duplicates?.Groups ?? []).DistinctBy(g=>g.Relative).ToArray();
            string duplicateNotice=duplicateGroups.Length==0 ? "" : "\n\n중복 이름 보존 대상:\n"+string.Join("\n",duplicateGroups.Select(g=>$"{g.Relative}: {g.Items.Length-1}개 사본의 이름 변경"))+"\n폴더인 경우 내부 파일 전체가 바뀐 폴더 이름 아래 보존됩니다. 삭제하지 않습니다. 이후 새 이름도 일반 파일·폴더로 동기화될 수 있습니다.";
            if(!Confirm(summary+"\n\n덮어쓰기 전 사본은 SafeSync 휴지통에 보관합니다.\n‘둘 다 보관’은 기존 백업을 같은 폴더의 다른 이름으로 남기고 원본을 복사합니다.\n‘이번 동기화에서 제외’는 영구 제외가 아니며 다음 실행에서 다시 확인합니다."+duplicateNotice+"\n\n이 처리를 적용할까요?"))return;
            if(!Writable()){Text("ComparisonStatus","확인하는 동안 새 작업이 시작되었습니다. 최신 결과에서 다시 선택하세요.");Buttons();return;}
            var decisions=new ComparedResolutions();
            foreach(var row in selected)
            {
                if(row.Action!=ConflictAction.Ignore && row.Snapshot==null)return;
                if(row.Snapshot!=null)decisions.Choose(row.Snapshot,row.Action!.Value);
                else decisions.Add(row.Issue.File,ConflictAction.Ignore);
            }
            busy=true;applying=true;Buttons();Text("ComparisonStatus","선택한 파일을 안전하게 처리하고 있습니다. 결과는 동기화 상태 창에서 확인할 수 있습니다.");
            try
            {
                await RunAsync(job,false,decisions);
                if(!closed)Text("ComparisonStatus","처리를 마쳤습니다. 최신 동기화 결과를 확인하세요. 남아 있는 문제는 최신 결과에서 다시 비교할 수 있습니다.");
            }
            finally{busy=false;applying=false;if(!closed)Buttons();}
        }
        list.SelectionChanged+=(_,_)=>TrackAuxiliary(LoadSelectedAsync());
        foreach(var (name,action) in new[]{("CompareForwardButton",ConflictAction.Overwrite),("CompareReverseButton",ConflictAction.UseBackup),("CompareKeepBothButton",ConflictAction.KeepBoth),("CompareIgnoreButton",ConflictAction.Ignore)})Click(window,name,()=>Choose(action));
        Click(window,"CompareDuplicatesButton",()=>Choose(ConflictAction.NormalizeDuplicates));
        Click(window,"CompareRefreshButton",()=>TrackAuxiliary(LoadSelectedAsync(true)));
        Click(window,"CompareApplyButton",()=>TrackAuxiliary(ApplyAsync()));
        Click(window,"CompareRecoveryButton",()=>{list.SelectedItem=rows.First(r=>r.Issue.File=="[작업]");RefreshRecoveryWindows();});
        Click(window,"CompareSourceTrashButton",()=>ShowLocalTrash(job,job.Source));
        System.Collections.Specialized.NotifyCollectionChangedEventHandler historyChanged=(_,_)=>
        {
            if(closed)return;Buttons();
            if(!IsLatest() && SelectedRows().FirstOrDefault() is {} row)Display(row);
        };
        sessionHistory.Runs.CollectionChanged+=historyChanged;
        window.IsVisibleChanged+=(_,_)=>{if(window.IsVisible && !closed)TrackAuxiliary(LoadSelectedAsync());};
        releaseProblemPanel=()=>{closed=true;window.IsEnabled=false;lifetime.Cancel();selectionToken?.Cancel();sessionHistory.Runs.CollectionChanged-=historyChanged;recoveryPanels.Remove(recoveryPanel);auxiliaryTokens.Remove(lifetime);selectionToken?.Dispose();lifetime.Dispose();};
        Buttons();
        return window;
    }
}
