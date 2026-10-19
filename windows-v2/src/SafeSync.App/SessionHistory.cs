using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private SyncRun? SelectedRun=>progressWindow?.Find<DataGrid>("HistoryGrid").SelectedItem as SyncRun ?? sessionHistory.Runs.FirstOrDefault();
    private SyncRun RecordRun(Func<SyncRun> record)
    {
        var prior=selectingHistory;selectingHistory=true;SyncRun run;
        try{run=record();}finally{selectingHistory=prior;}
        FollowRun(run);return run;
    }
    private void OnStarted(BackupJob job){RecordRun(()=>sessionHistory.Begin(job));RefreshProgress();}
    private void FollowRun(SyncRun run)
    {
        if(progressWindow!=null && followLatest && ReferenceEquals(run,sessionHistory.Runs.FirstOrDefault()))SelectRun(run);
    }
    private void SelectRun(SyncRun? run)
    {
        if(progressWindow==null)return;
        selectingHistory=true;
        try{progressWindow.Find<DataGrid>("HistoryGrid").SelectedItem=run;}
        finally{selectingHistory=false;}
    }
    private void LimitHistory()
    {
        if(progressWindow is not {} window)return;
        var root=window.Find<Grid>("ProgressRoot");
        if(VisualTreeHelper.GetParent(root) is not FrameworkElement viewport || viewport.ActualHeight<=0)return;
        var available=viewport.ActualHeight-root.Margin.Top-root.Margin.Bottom;
        var limit=Math.Max(90,available-root.RowDefinitions[0].ActualHeight-root.RowDefinitions[4].ActualHeight-8-280);
        var row=window.Find<RowDefinition>("ProgressHistoryRow");if(Math.Abs(row.MaxHeight-limit)>.5)row.MaxHeight=limit;
    }
    private void ToggleRunPause()
    {
        if(SelectedRun is not {IsActive:true} run || jobs.FirstOrDefault(j=>j.Id==run.JobId) is not {} job)return;
        scheduler.SetPaused(job,!job.Paused);sessionHistory.SetPaused(job.Id,job.Paused);Save();RefreshActions();Jobs.Items.Refresh();RefreshProgress();
    }
    private void RetrySelectedLocked()
    {
        if(SelectedRun==null && Selected is {Paused:false} selected && restoredLocked.GetValueOrDefault(selected.Id,[]).Length>0){followLatest=true;_=RunAsync(selected);return;}
        if(SelectedRun is not {} run || !sessionHistory.IsLatest(run) || run.IsActive || jobs.FirstOrDefault(j=>j.Id==run.JobId) is not {} job || job.Paused)return;
        followLatest=true;_=RunAsync(job);
    }
}
