using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using SafeSync.Core;
namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private readonly HashSet<string> verifyingJobs=new();
    private void ShowRestoreCheck()
    {
        if(Selected is not {} job || scheduler.IsRunning(job.Id) || verifyingJobs.Contains(job.Id))return;
        var window=NewDialog("RestoreCheck",false);var rows=new ObservableCollection<RestoreCheckRow>();window.Find<DataGrid>("ResultsGrid").ItemsSource=rows;
        var lifetime=new CancellationTokenSource();auxiliaryTokens.Add(lifetime);bool busy=false;
        window.Find<TextBlock>("LocationText").Text=job.Name+"\n백업: "+job.Destination;
        async Task Start()
        {
            if(busy || scheduler.IsRunning(job.Id) || verifyingJobs.Contains(job.Id))return;
            bool paused=job.Paused;busy=true;verifyingJobs.Add(job.Id);scheduler.SetPaused(job,true);Save();RefreshActions();rows.Clear();
            window.Find<Button>("StartButton").IsEnabled=false;window.Find<Button>("CancelButton").IsEnabled=true;window.Find<ProgressBar>("WorkProgress").Visibility=Visibility.Visible;
            int okay=0,unknown=0,failed=0;
            try
            {
                var remote=job.DestinationType=="Local" ? null : cloud.ForJob(job);
                await Task.Run(async ()=>
                {
                    await foreach(var row in new RestoreChecks(store).CheckAsync(job,remote,lifetime.Token))
                    {
                        await window.Dispatcher.InvokeAsync(()=>
                        {
                            rows.Add(row);if(row.Status=="정상")okay++;else if(row.Status=="기준 없음")unknown++;else failed++;
                            window.Find<TextBlock>("StatusText").Text=$"검증 {rows.Count:N0}개 · 정상 {okay:N0} · 기준 없음 {unknown:N0} · 실패 {failed:N0}\n현재 파일: {row.Path}";
                        });
                    }
                },lifetime.Token);
                window.Find<TextBlock>("StatusText").Text=rows.Count==0 ? "성공 백업 기록이 없어 검증할 파일이 없습니다. 먼저 백업을 실행하세요." : $"검증 완료 · 정상 {okay:N0} · 기준 없음 {unknown:N0} · 실패 {failed:N0}";
            }
            catch(OperationCanceledException){window.Find<TextBlock>("StatusText").Text="검증을 취소했습니다. 백업 파일은 변경하지 않았습니다.";}
            catch(Exception ex){window.Find<TextBlock>("StatusText").Text="검증 중단: "+ex.Message;}
            finally
            {
                verifyingJobs.Remove(job.Id);if(jobs.Any(j=>ReferenceEquals(j,job)))scheduler.SetPaused(job,paused);Save();RefreshActions();Jobs.Items.Refresh();busy=false;
                window.Find<Button>("StartButton").IsEnabled=!lifetime.IsCancellationRequested;window.Find<Button>("CancelButton").IsEnabled=false;window.Find<ProgressBar>("WorkProgress").Visibility=Visibility.Collapsed;
            }
        }
        Click(window,"StartButton",()=>TrackAuxiliary(Start()));Click(window,"CancelButton",lifetime.Cancel);Click(window,"CloseButton",window.Close);window.Closed+=(_,_)=>lifetime.Cancel();window.Show();
    }
    private void ApplyVerificationActions()
    {
        bool active=Selected is {} job && verifyingJobs.Contains(job.Id);
        Main.Find<MenuItem>("VerifyRestoreMenuItem").IsEnabled=Selected!=null && !active && !scheduler.IsRunning(Selected.Id);
        if(!active)return;
        foreach(var name in new[]{"EditButton","DeleteButton","FullScanButton","StopJobMenuItem","RebindCloudJobMenuItem","MassChangesMenuItem"})Main.Find<MenuItem>(name).IsEnabled=false;
        foreach(var name in new[]{"RunButton","PauseButton","JobActionsButton"})Main.Find<Button>(name).IsEnabled=false;
    }
}
