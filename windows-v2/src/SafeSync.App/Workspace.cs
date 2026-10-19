using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    // Reuse the existing view name scopes and lifetime handlers, but mount only
    // their content in the shell. These view definitions never call Window.Show.
    private readonly Dictionary<Window,FrameworkElement> workspaceViews=[];
    private Window? trashWorkspace;
    private string trashWorkspaceKey="";
    private bool trashWorkspaceOperating;
    private FrameworkElement WorkspaceVisual(Window view)=>workspaceViews.TryGetValue(view,out var content) ? content : view;
    private void MountWorkspace(Window view,string hostName,double minimumHeight)
    {
        var content=(FrameworkElement)view.Content;view.Content=null;
        content.Resources.MergedDictionaries.Add(view.Resources);
        if(content is Panel panel)panel.SetResourceReference(Panel.BackgroundProperty,"SafeSyncWindowBrush");
        var scroll=new ScrollViewer {VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,Content=content};
        void Fit(){content.Height=Math.Max(minimumHeight,scroll.ActualHeight)-content.Margin.Top-content.Margin.Bottom;}
        scroll.SizeChanged+=(_,_)=>Fit();
        workspaceViews.Add(view,content);Main.Find<ContentControl>(hostName).Content=scroll;
        view.Closed+=(_,_)=>{workspaceViews.Remove(view);if(ReferenceEquals(trashWorkspace,view)){trashWorkspace=null;trashWorkspaceKey="";}if(ReferenceEquals(Main.Find<ContentControl>(hostName).Content,scroll))Main.Find<ContentControl>(hostName).Content=null;};
    }
    private void SelectWorkspace(string name)
    {
        Main.Find<TabItem>(name).IsSelected=true;
        if(!Main.IsVisible)ShowMain();
        Main.UpdateLayout();
    }
    private void HideProgress()=>SelectWorkspace("MainTab");
    private bool PrepareTrashWorkspace(string key)
    {
        if(trashWorkspace!=null && trashWorkspaceKey==key){SelectWorkspace("TrashWorkspaceTab");return false;}
        if(trashWorkspaceOperating){Tell("휴지통 파일을 처리하고 있습니다. 처리가 끝난 뒤 다른 휴지통을 선택하세요.");SelectWorkspace("TrashWorkspaceTab");return false;}
        trashWorkspace?.Close();trashWorkspace=null;trashWorkspaceKey=key;return true;
    }
    private void ShowTrashWorkspace(Window view)
    {
        trashWorkspace=view;MountWorkspace(view,"TrashWorkspaceHost",500);
        view.Find<Button>("CloseButton").Content="백업 작업으로";
        SelectWorkspace("TrashWorkspaceTab");
    }
    private void WireWorkspace()
    {
        var tabs=Main.Find<TabControl>("WorkspaceTabs");
        tabs.SelectionChanged+=(_,e)=>
        {
            if(!ReferenceEquals(e.OriginalSource,tabs))return;
            if(Main.Find<TabItem>("SyncWorkspaceTab").IsSelected && progressWindow==null)ShowProgress();
            if(Main.Find<TabItem>("TrashWorkspaceTab").IsSelected && trashWorkspace==null && Selected!=null)ShowTrash();
            Main.Dispatcher.BeginInvoke(()=>{LimitActivity();LimitHistory();});
        };
        Main.Find<GridSplitter>("MainLayoutSplitter").DragCompleted+=(_,_)=>CaptureLayout();
    }
}
