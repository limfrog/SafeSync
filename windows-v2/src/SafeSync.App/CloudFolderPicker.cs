using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed record CloudFolderChoice(string Reference,string Display,string AccountId,string FolderIdentity="");

internal sealed class CloudFolderPicker
{
    public Window Window {get;}
    public CloudFolderChoice? Choice {get;private set;}
    public string Current {get;private set;}="";
    private readonly IRemoteStore remote;
    private readonly string accountName;
    private readonly CancellationTokenSource lifetime;
    private readonly Action<Task> track;
    private bool initialized,busy,ready;
    private T Find<T>(string name) where T:class=>Window.Find<T>(name);
    public CloudFolderPicker(IRemoteStore remote,string accountName,string theme,Window owner,CancellationTokenSource lifetime,Action<Task> track)
    {
        this.remote=remote;this.accountName=accountName;this.lifetime=lifetime;this.track=track;
        Window=Views.Load("CloudFolderPicker");Theme.Apply(Window,theme);Window.Owner=owner;Window.Icon=owner.Icon;
        Window.Title=(remote.Provider=="GoogleDrive" ? "Google Drive" : "Dropbox")+" 백업 폴더 선택";
        Find<Button>("UpButton").Click+=(_,_)=>track(NavigateAsync(RemotePath.Parent(Current)));
        Find<Button>("RefreshButton").Click+=(_,_)=>track(NavigateAsync(Current));
        Find<Button>("NewFolderButton").Click+=(_,_)=>
        {
            if(busy || !ready)return;Find<Border>("NewFolderPanel").Visibility=Visibility.Visible;
            Find<TextBox>("FolderNameBox").Focus();
        };
        Find<Button>("CancelNewFolderButton").Click+=(_,_)=>Find<Border>("NewFolderPanel").Visibility=Visibility.Collapsed;
        Find<Button>("CreateFolderButton").Click+=(_,_)=>track(CreateAsync());
        Find<TextBox>("FolderNameBox").KeyDown+=(_,e)=>{if(e.Key==Key.Enter){e.Handled=true;track(CreateAsync());}else if(e.Key==Key.Escape){e.Handled=true;Find<Border>("NewFolderPanel").Visibility=Visibility.Collapsed;}};
        Find<ListBox>("FolderList").MouseDoubleClick+=(_,_)=>OpenSelected();
        Find<ListBox>("FolderList").KeyDown+=(_,e)=>{if(e.Key==Key.Enter){e.Handled=true;OpenSelected();}};
        Find<Button>("SelectButton").Click+=(_,_)=>track(ChooseAsync());
        Find<Button>("CancelButton").Click+=(_,_)=>Window.Close();
        Window.Loaded+=(_,_)=>track(NavigateAsync(""));Window.Closed+=(_,_)=>lifetime.Cancel();Buttons();
    }
    private void OpenSelected()
    {
        try
        {
            if(!busy && ready && Find<ListBox>("FolderList").SelectedItem is RemoteItem item)
                track(NavigateAsync(CloudFolders.ChildPath(Current,item.Name)));
        }
        catch(Exception ex){Status("폴더를 열 수 없습니다: "+ex.Message,true);}
    }
    private void Buttons()
    {
        Find<Button>("RefreshButton").IsEnabled=!busy;
        Find<Button>("UpButton").IsEnabled=!busy && Current.Length>0;
        foreach(var name in new[]{"NewFolderButton","CreateFolderButton","SelectButton"})Find<Button>(name).IsEnabled=!busy && ready;
        if(remote.Provider=="Dropbox" && Current.Length==0)Find<Button>("SelectButton").IsEnabled=false;
        Find<Button>("CancelNewFolderButton").IsEnabled=!busy;Find<TextBox>("FolderNameBox").IsEnabled=!busy;
        Find<ListBox>("FolderList").IsEnabled=!busy && ready;
        Find<ProgressBar>("BusyProgress").Visibility=busy ? Visibility.Visible : Visibility.Collapsed;
    }
    private void Status(string value,bool error=false)
    {
        var text=Find<TextBlock>("StatusText");text.Text=value;
        text.SetResourceReference(TextBlock.ForegroundProperty,error ? "SafeSyncDangerBrush" : "SafeSyncMutedBrush");
    }
    private async Task LoadCoreAsync(string next)
    {
        ready=false;
        if(!initialized){Status("클라우드 연결 확인 중…");await remote.InitializeAsync(lifetime.Token);initialized=true;}
        Status("폴더 목록을 불러오는 중…");var entries=await remote.ListAsync(next,lifetime.Token);
        Current=next;ready=true;
        Find<ListBox>("FolderList").ItemsSource=entries.Where(i=>i.Folder && !PathPolicy.Internal(i.Name)).OrderBy(i=>i.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();
        Find<TextBlock>("PathText").Text=(remote.Provider=="GoogleDrive" ? "Google Drive" : "Dropbox")+" · "+accountName+" / "+(Current.Length==0 ? "최상위" : Current);
        Status(remote.Provider=="Dropbox" && Current.Length==0 ? "Dropbox 전체에서 폴더를 선택하거나 새로 만드세요. 작업은 선택한 폴더 안에서만 실행됩니다." : "폴더를 더블클릭해 이동한 뒤 현재 폴더를 선택하세요.");
    }
    public async Task NavigateAsync(string next)
    {
        if(busy)return;busy=true;Buttons();
        try{await LoadCoreAsync(next);Find<Border>("NewFolderPanel").Visibility=Visibility.Collapsed;}
        catch(OperationCanceledException){}
        catch(Exception ex){Status("폴더 확인 실패: "+ex.Message,true);}
        finally{busy=false;Buttons();}
    }
    public async Task CreateAsync()
    {
        if(busy || !ready)return;busy=true;Buttons();
        try
        {
            Status("새 폴더를 만드는 중…");var next=await CloudFolders.CreateAsync(remote,Current,Find<TextBox>("FolderNameBox").Text,lifetime.Token);
            await LoadCoreAsync(next);Find<TextBox>("FolderNameBox").Clear();Find<Border>("NewFolderPanel").Visibility=Visibility.Collapsed;
            Status("새 폴더를 만들었습니다. ‘현재 폴더 선택’을 누르면 이 위치를 사용합니다.");
        }
        catch(OperationCanceledException){}
        catch(Exception ex){Status("폴더 만들기 실패: "+ex.Message,true);}
        finally{busy=false;Buttons();}
    }
    private async Task ChooseAsync()
    {
        if(busy || !ready)return;busy=true;Buttons();
        try
        {
            Status("선택한 폴더 확인 중…");var item=await remote.StatAsync(Current,lifetime.Token);
            if(item?.Folder!=true)throw new DirectoryNotFoundException("선택한 폴더에 접근할 수 없습니다.");
            if(remote.Provider=="Dropbox" && Current.Length==0)throw new InvalidOperationException("Dropbox 전체가 아닌 작업 전용 폴더를 선택하세요.");
            Choice=new(remote.Provider=="Dropbox" ? "/"+Current : item.Id,Find<TextBlock>("PathText").Text,remote.AccountId,item.Id);
            Window.DialogResult=true;
        }
        catch(OperationCanceledException){}
        catch(Exception ex){Status(ex.Message,true);}
        finally{busy=false;Buttons();}
    }
}
