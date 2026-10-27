using System;
using System.Collections;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Collections.Generic;
using System.ComponentModel;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed record TrashRowInfo(string Name,string OriginalPath,DateTime DeletedAt,long Length);

internal sealed class TrashBrowserPresentation<T> : IDisposable
{
    private readonly Window window;
    private readonly ObservableCollection<T> items;
    private readonly Func<T,TrashRowInfo> describe;
    private readonly DataGrid grid;
    private readonly ListCollectionView view;
    private readonly DispatcherTimer debounce;
    private readonly DispatcherTimer renderTimer;
    private bool busy,canOperate,disposed;
    private long totalBytes;
    private TrashRowInfo[] selection=[];
    private readonly bool dropbox;
    private bool refreshingBatches;
    private int batchItemCount=-1;
    private string BatchOf(T item)=>item is TrashItem local ? local.BatchId : item is CloudTrashItem cloud ? cloud.BatchId : "";
    public TrashBrowserPresentation(Window window,ObservableCollection<T> items,Func<T,TrashRowInfo> describe,BackupJob job,int retentionDays,bool dropbox=false)
    {
        this.window=window;this.items=items;this.describe=describe;this.dropbox=dropbox;grid=window.Find<DataGrid>("TrashGrid");
        view=new ListCollectionView((IList)items);view.SortDescriptions.Add(new("DeletedAt",ListSortDirection.Descending));grid.ItemsSource=view;
        totalBytes=items.Sum(i=>Math.Max(0,describe(i).Length));
        window.Find<TextBlock>("JobText").Text=job.Name+" · "+(job.DestinationType=="GoogleDrive" ? "Google Drive" : job.DestinationType=="Dropbox" ? "Dropbox" : "로컬 / 네트워크");
        window.Find<TextBlock>("BackupLocationText").Text=job.Destination;
        window.Find<TextBlock>("RetentionText").Text=$"보관 기간 {retentionDays:N0}일 · 파일별 보기";
        window.Find<TextBlock>("DeletionPolicyText").Text=dropbox ? "복구 후 작업은 일시정지됩니다. ‘휴지통에서 제거’ 후에도 Dropbox 자체 복구 정책이 적용될 수 있습니다." : "복구 후 작업은 일시정지됩니다. 완전 삭제는 되돌릴 수 없습니다.";
        renderTimer=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(100)};renderTimer.Tick+=(_,_)=>{renderTimer.Stop();Update();};
        debounce=new DispatcherTimer {Interval=TimeSpan.FromMilliseconds(250)};debounce.Tick+=(_,_)=>{debounce.Stop();ApplyFilter();};
        window.Find<TextBox>("SearchBox").TextChanged+=(_,_)=>
        {
            grid.UnselectAll();debounce.Stop();debounce.Start();
            window.Find<TextBlock>("SearchHint").Visibility=window.Find<TextBox>("SearchBox").Text.Length==0 ? Visibility.Visible : Visibility.Collapsed;
            window.Find<Button>("ClearSearchButton").IsEnabled=window.Find<TextBox>("SearchBox").Text.Length>0;
        };
        window.Find<TextBox>("SearchBox").KeyDown+=(_,e)=>{if(e.Key==Key.Escape){window.Find<TextBox>("SearchBox").Clear();e.Handled=true;}};
        window.Find<Button>("ClearSearchButton").Click+=(_,_)=>window.Find<TextBox>("SearchBox").Clear();
        window.Find<Button>("ClearSelectionButton").Click+=(_,_)=>grid.UnselectAll();
        var batches=window.Find<ComboBox>("BatchBox");batches.DisplayMemberPath="Value";batches.SelectedValuePath="Key";
        batches.SelectionChanged+=(_,_)=>{if(!refreshingBatches)ApplyFilter();};RefreshBatches();
        grid.SelectionChanged+=SelectionChanged;items.CollectionChanged+=ItemsChanged;((INotifyCollectionChanged)view).CollectionChanged+=ViewChanged;
        window.Closed+=(_,_)=>Dispose();Update();
    }
    public void SetState(bool busy,bool canOperate)
    {
        bool changed=this.busy!=busy;this.busy=busy;this.canOperate=canOperate;
        if(changed){view.SortDescriptions.Clear();if(!busy)view.SortDescriptions.Add(new("DeletedAt",ListSortDirection.Descending));}if(!busy && (changed || batchItemCount!=items.Count)){RefreshBatches();batchItemCount=items.Count;}Update();
    }
    private void QueueUpdate(){if(!busy)Update();else if(!renderTimer.IsEnabled)renderTimer.Start();}
    private void ItemsChanged(object? sender,NotifyCollectionChangedEventArgs e)
    {
        if(e.Action==NotifyCollectionChangedAction.Reset)totalBytes=items.Sum(i=>Math.Max(0,describe(i).Length));
        else
        {
            if(e.OldItems!=null)foreach(T item in e.OldItems)totalBytes-=Math.Max(0,describe(item).Length);
            if(e.NewItems!=null)foreach(T item in e.NewItems)totalBytes+=Math.Max(0,describe(item).Length);
        }
        QueueUpdate();
    }
    private void ViewChanged(object? sender,NotifyCollectionChangedEventArgs e)=>QueueUpdate();
    private void SelectionChanged(object sender,SelectionChangedEventArgs e){selection=grid.SelectedItems.Cast<T>().Select(describe).ToArray();Update();}
    private void ApplyFilter()
    {
        if(disposed)return;var query=window.Find<TextBox>("SearchBox").Text.Trim();grid.UnselectAll();
        var batch=window.Find<ComboBox>("BatchBox").SelectedValue as string ?? "";
        using(view.DeferRefresh())view.Filter=query.Length==0 && batch.Length==0 ? null : value=>value is T item && (batch.Length==0 || BatchOf(item)==batch) && (query.Length==0 || describe(item).Name.Contains(query,StringComparison.OrdinalIgnoreCase)||describe(item).OriginalPath.Contains(query,StringComparison.OrdinalIgnoreCase));
        Update();
    }
    private void RefreshBatches()
    {
        var control=window.Find<ComboBox>("BatchBox");var keys=items.Select(BatchOf).Where(s=>s.Length>0).Distinct().OrderDescending(StringComparer.Ordinal).ToArray();
        var choices=new[]{new KeyValuePair<string,string>("","모든 백업 실행 · 이전 보관 파일 포함")}.Concat(keys.Select(key=>new KeyValuePair<string,string>(key,(TrashDates.TryParse(key,out var date) ? date.ToString("yyyy-MM-dd HH:mm:ss") : "이전 보관")+" · "+key[^Math.Min(8,key.Length)..]))).ToArray();
        if(control.ItemsSource is KeyValuePair<string,string>[] old && old.Select(p=>p.Key).SequenceEqual(choices.Select(p=>p.Key)))return;
        var selected=control.SelectedValue as string ?? "";refreshingBatches=true;
        try{control.ItemsSource=choices;control.SelectedValue=choices.Any(p=>p.Key==selected) ? selected : "";}finally{refreshingBatches=false;}
        ApplyFilter();
    }
    private void Update()
    {
        if(disposed)return;
        if(selection.Length!=grid.SelectedItems.Count)selection=grid.SelectedItems.Cast<T>().Select(describe).ToArray();
        var selected=selection;
        window.Find<TextBlock>("TotalsText").Text=$"전체 {items.Count:N0}개 · {TrashSizeConverter.Format(totalBytes)}";
        window.Find<TextBlock>("VisibleCountText").Text=$"표시 {view.Count:N0}개 / 전체 {items.Count:N0}개";
        window.Find<TextBlock>("SelectionText").Text=selected.Length==0 ? "선택한 파일 없음" : $"{selected.Length:N0}개 선택 · {TrashSizeConverter.Format(selected.Sum(i=>Math.Max(0,i.Length)))}";
        window.Find<TextBlock>("SelectedFileText").Text=selected.Length==1 ? selected[0].Name+" · "+selected[0].DeletedAt.ToString("yyyy-MM-dd HH:mm:ss") : selected.Length>1 ? "선택한 파일은 각각의 원래 백업 위치로 복구됩니다." : "목록에서 파일을 선택하면 전체 경로와 삭제 시각을 확인할 수 있습니다.";
        window.Find<TextBox>("SelectedOriginalPath").Text=selected.Length==1 ? selected[0].OriginalPath : "";
        var empty=window.Find<TextBlock>("EmptyText");empty.Visibility=view.Count==0 ? Visibility.Visible : Visibility.Collapsed;
        empty.Text=busy ? "파일 목록을 불러오거나 처리하고 있습니다…" : items.Count==0 ? "휴지통이 비어 있습니다." : "검색 조건에 맞는 파일이 없습니다.";
        window.Find<Button>("RefreshButton").IsEnabled=!busy;
        window.Find<Button>("SelectAllButton").IsEnabled=!busy && view.Count>0;
        window.Find<Button>("ClearSelectionButton").IsEnabled=!busy && selected.Length>0;
        window.Find<Button>("RestoreButton").IsEnabled=!busy && canOperate && selected.Length>0;
        window.Find<Button>("DeleteButton").IsEnabled=!busy && canOperate && selected.Length>0;
        window.Find<Button>("VerifyTrashButton").IsEnabled=!busy && canOperate && selected.Length>0;
        window.Find<ComboBox>("BatchBox").IsEnabled=!busy;
        window.Find<Button>("RestoreButton").Content=selected.Length==0 ? "선택 파일 복구" : $"선택 복구 ({selected.Length:N0})";
        window.Find<Button>("DeleteButton").Content=(dropbox ? "휴지통에서 제거" : "완전 삭제")+(selected.Length==0 ? "" : $" ({selected.Length:N0})");
        window.Find<TextBox>("SearchBox").IsEnabled=!busy;
        window.Find<Button>("ClearSearchButton").IsEnabled=!busy && window.Find<TextBox>("SearchBox").Text.Length>0;
        window.Find<Button>("RestoreButton").ToolTip=!canOperate ? "백업 작업이 끝난 뒤 복구할 수 있습니다." : "선택한 파일을 원래 백업 위치로 복구";
        window.Find<Button>("DeleteButton").ToolTip=!canOperate ? "백업 작업이 끝난 뒤 삭제할 수 있습니다." : dropbox ? "SafeSync 휴지통에서 제거 (Dropbox 복구 정책은 별도)" : "선택한 파일을 완전히 삭제 (되돌릴 수 없음)";
        window.Find<ProgressBar>("BusyProgress").Visibility=busy ? Visibility.Visible : Visibility.Collapsed;
    }
    public void Dispose(){if(disposed)return;disposed=true;debounce.Stop();renderTimer.Stop();items.CollectionChanged-=ItemsChanged;((INotifyCollectionChanged)view).CollectionChanged-=ViewChanged;grid.SelectionChanged-=SelectionChanged;}
}

public sealed class TrashSizeConverter : IValueConverter
{
    internal static string Format(long bytes)
    {double size=Math.Max(0,bytes);string[] units=["B","KB","MB","GB","TB","PB"];int unit=0;while(size>=1024 && unit<units.Length-1){size/=1024;unit++;}return unit==0 ? $"{size:N0} B" : $"{size:N1} {units[unit]}";}
    public object Convert(object value,Type targetType,object parameter,CultureInfo culture)=>value is long bytes ? Format(bytes) : "—";
    public object ConvertBack(object value,Type targetType,object parameter,CultureInfo culture)=>Binding.DoNothing;
}
