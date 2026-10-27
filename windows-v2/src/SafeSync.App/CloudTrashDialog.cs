using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private void ShowCloudTrash(BackupJob job)
    {
        IRemoteStore remote;
        try{remote=cloud.ForJob(job);}catch(Exception ex){Tell(ex.Message);return;}
        if(!PrepareTrashWorkspace(job.Id+"|"+System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(job)+"|"+job.DestinationType+"|"+job.CloudAccountId+"|"+job.CloudFolderId))return;
        var window=NewDialog("Trash",false);var grid=window.Find<DataGrid>("TrashGrid");
        window.Find<Button>("SourceTrashButton").Visibility=Visibility.Visible;
        Click(window,"SourceTrashButton",()=>ShowLocalTrash(job,job.Source));
        var items=new ObservableCollection<CloudTrashItem>();var cache=new TrashListCache<CloudTrashItem>(store,job);bool firstLoad=true;
        var presentation=new TrashBrowserPresentation<CloudTrashItem>(window,items,item=>new(item.Name,item.OriginalPath,item.DeletedAt,item.Length),job,config.TrashRetentionDays,job.DestinationType=="Dropbox");
        var status=window.Find<TextBlock>("StatusText");var lifetime=new CancellationTokenSource();auxiliaryTokens.Add(lifetime);
        var publisher=new CloudPublisher(store,job,remote);var service=new CloudTrash(remote,publisher,store);bool busy=false,initialized=false;
        void Buttons()
        {
            presentation.SetState(busy,jobs.Any(j=>ReferenceEquals(j,job)) && scheduler.RunningCount==0 && !verifyingJobs.Contains(job.Id));
        }
        async Task LoadAsync()
        {
            if(busy)return;busy=true;Buttons();
            if(firstLoad){firstLoad=false;foreach(var row in await Task.Run(cache.Read))items.Add(row);status.Text="저장된 목록 표시 · 클라우드 변경 확인 중…";}
            else {items.Clear();status.Text="클라우드 휴지통 연결 중…";}
            try
            {
                if(!initialized){await remote.InitializeAsync(lifetime.Token);initialized=true;}
                var loaded=await Task.Run(async ()=>{var rows=new System.Collections.Generic.List<CloudTrashItem>();await foreach(var row in service.ListAsync(lifetime.Token))rows.Add(row);return rows;},lifetime.Token);
                items.Clear();foreach(var item in loaded)
                {
                    items.Add(item with{OriginalPath=job.Destination+" / "+item.RelativePath});status.Text=$"{items.Count:N0}개 불러오는 중…";
                    if(items.Count%100==0)await Task.Yield();
                }
                var snapshot=items.ToArray();await Task.Run(()=>cache.Save(snapshot),lifetime.Token);
                status.Text=$"파일 {items.Count:N0}개"+(job.DestinationType=="Dropbox" ? " · 제거 후에도 Dropbox 자체 복구 정책이 적용됩니다." : "");
            }
            catch(OperationCanceledException){}
            catch(Exception ex){status.Text="목록 확인 실패: "+ex.Message;}
            finally{busy=false;Buttons();}
        }
        async Task OperateAsync(bool restore)
        {
            var selected=grid.SelectedItems.Cast<CloudTrashItem>().ToArray();
            if(restore && selected.Select(i=>i.RelativePath).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=selected.Length){status.Text="같은 경로는 한 버전만 선택하세요.";return;}
            using var batch=new RecoveryBatch();if(busy || selected.Length==0)return;
            if(!jobs.Any(j=>ReferenceEquals(j,job))){status.Text="작업 설정이 변경되었습니다. 백업 작업 탭에서 휴지통을 다시 여세요.";Buttons();return;}
            if(scheduler.RunningCount>0 || verifyingJobs.Contains(job.Id) || LegacyRunning()){status.Text="모든 백업·복원 검증이 끝나고 기존 앱을 종료한 뒤 처리하세요.";return;}
            var notice=job.DestinationType=="Dropbox" ? "SafeSync 휴지통에서 제거합니다. Dropbox 자체 복구 정책은 별도로 적용됩니다." : "클라우드에서 완전히 삭제합니다. 되돌릴 수 없습니다.";
            if(!restore && !Confirm($"선택한 {selected.Length}개 파일을 삭제할까요?\n"+notice))return;
            scheduler.SetPaused(job,true);Save();RefreshActions();Jobs.Items.Refresh();busy=true;trashWorkspaceOperating=true;Buttons();
            var gate=CloudBackupEngine.ScopeGate(remote);bool entered=false;int done=0,failed=0;
            try
            {
                using var lease=LegacyRunLease.Acquire();await gate.WaitAsync(lifetime.Token);entered=true;
                foreach(var item in selected)
                {
                    lifetime.Token.ThrowIfCancellationRequested();
                    try{await service.OperateAsync(item,restore,lifetime.Token);items.Remove(item);done++;}
                    catch(OperationCanceledException){throw;}
                    catch(Exception ex){failed++;Log(item.Name+": "+ex.Message);}
                    status.Text=$"{done+failed}/{selected.Length} 처리 중…";
                }
                var remaining=items.ToArray();await Task.Run(()=>cache.Save(remaining),lifetime.Token);
                status.Text=$"완료 {done}개 · 실패 {failed}개 · 작업은 확인할 때까지 일시정지합니다.";
            }
            catch(OperationCanceledException){}
            catch(Exception ex){status.Text=ex.Message;}
            finally{if(entered)gate.Release();busy=false;trashWorkspaceOperating=false;Buttons();}
        }
        Click(window,"CloseButton",()=>SelectWorkspace("MainTab"));Click(window,"RefreshButton",()=>TrackAuxiliary(LoadAsync()));
        Click(window,"SelectAllButton",grid.SelectAll);Click(window,"RestoreButton",()=>TrackAuxiliary(OperateAsync(true)));Click(window,"DeleteButton",()=>TrackAuxiliary(OperateAsync(false)));
        Click(window,"VerifyTrashButton",()=>TrackAuxiliary(VerifyAsync()));
        async Task VerifyAsync()
        {
            var selected=grid.SelectedItems.Cast<CloudTrashItem>().ToArray();if(busy || selected.Length==0 || !initialized)return;
            busy=true;Buttons();var gate=CloudBackupEngine.ScopeGate(remote);bool entered=false;
            try{await gate.WaitAsync(lifetime.Token);entered=true;await VerifyTrashSelectionAsync(window,selected,(item,ct)=>ArchiveIntegrity.VerifyRemoteAsync(store,remote,item,ct),lifetime.Token);}
            catch(OperationCanceledException){}finally{if(entered)gate.Release();busy=false;Buttons();}
        }
        grid.SelectionChanged+=(_,_)=>Buttons();window.Closed+=(_,_)=>lifetime.Cancel();ShowTrashWorkspace(window);TrackAuxiliary(LoadAsync());
    }
}
