using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using SafeSync.Core;
using SafeSync.Core.Cloud;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task<int> TestCloudPickerAsync(string? previewDirectory)
    {
        int assertions=0;
        void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        {
            var remote=new FolderPickerTestRemote();var lifetime=new CancellationTokenSource();auxiliaryTokens.Add(lifetime);
            var picker=new CloudFolderPicker(remote,"테스트 계정",mode,Main,lifetime,TrackAuxiliary);var window=picker.Window;
            window.ShowInTaskbar=false;window.WindowStartupLocation=WindowStartupLocation.Manual;window.Left=-32000;window.Top=-32000;
            auxiliary.Add(window);window.Closed+=(_,_)=>auxiliary.Remove(window);window.Show();
            for(int i=0;i<100 && window.Find<ListBox>("FolderList").Items.Count==0;i++)await Task.Delay(10);
            var list=window.Find<ListBox>("FolderList");window.UpdateLayout();
            Check(list.Items.Count==71,"클라우드 폴더 목록에 파일/내부 보관 폴더가 섞였습니다.");
            Check(window.Find<Button>("NewFolderButton").IsEnabled,"새 폴더 버튼이 비활성화되었습니다.");
            var input=(SolidColorBrush)window.Resources["SafeSyncInputBrush"];var text=(SolidColorBrush)window.Resources["SafeSyncTextBrush"];
            Check(((SolidColorBrush)list.Background).Color==input.Color && ((SolidColorBrush)list.Foreground).Color==text.Color,"폴더 목록의 테마 색상이 다릅니다.");
            list.SelectedIndex=0;list.Focus();window.UpdateLayout();
            var row=(ListBoxItem)list.ItemContainerGenerator.ContainerFromIndex(0);
            Check(row.Template!=null && ((SolidColorBrush)row.Foreground).Color==Colors.White,"선택한 폴더의 글자가 읽히지 않습니다.");
            var bar=VisualChildren<System.Windows.Controls.Primitives.ScrollBar>(list).FirstOrDefault(b=>b.IsVisible);
            Check(bar!=null && ((SolidColorBrush)bar.Background).Color==((SolidColorBrush)window.Resources["SafeSyncSubtleBrush"]).Color,"폴더 스크롤바에 테마가 적용되지 않았습니다.");
            window.Find<Button>("NewFolderButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));window.UpdateLayout();
            Check(window.Find<Border>("NewFolderPanel").Visibility==Visibility.Visible,"새 폴더 입력칸이 열리지 않습니다.");
            Check(((SolidColorBrush)window.Find<TextBox>("FolderNameBox").Background).Color==input.Color,"새 폴더 입력칸의 테마가 다릅니다.");
            if(previewDirectory!=null)
            {
                var bitmap=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(window);
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(Path.Combine(previewDirectory,"CloudFolderPicker-"+mode+".png"));encoder.Save(stream);
            }
            window.Find<TextBox>("FolderNameBox").Text="../잘못된 경로";await picker.CreateAsync();
            Check(remote.Created==0 && window.Find<TextBlock>("StatusText").Text.StartsWith("폴더 만들기 실패"),"위험한 폴더 이름을 서버로 전송했습니다.");
            window.Find<TextBox>("FolderNameBox").Text="기존 폴더";await picker.CreateAsync();
            Check(remote.Created==0 && window.Find<Button>("CreateFolderButton").IsEnabled,"중복 이름 오류 후 UI를 사용할 수 없습니다.");
            remote.FailCreate=true;window.Find<TextBox>("FolderNameBox").Text="권한 오류 테스트";await picker.CreateAsync();
            Check(window.Find<TextBlock>("StatusText").Text.Contains("모사 권한 오류") && window.Find<Button>("RefreshButton").IsEnabled,"서버 오류 후 UI가 잠겼습니다.");remote.FailCreate=false;
            remote.BlockCreate=new(TaskCreationOptions.RunContinuationsAsynchronously);window.Find<TextBox>("FolderNameBox").Text="새 백업 폴더";var creating=picker.CreateAsync();
            Check(!window.Find<Button>("SelectButton").IsEnabled && !window.Find<Button>("NewFolderButton").IsEnabled && window.Find<Button>("CancelButton").IsEnabled,"생성 중 중복 요청 또는 취소 버튼 상태가 잘못되었습니다.");
            remote.BlockCreate.SetResult();await creating;
            Check(picker.Current=="새 백업 폴더" && remote.Created==1,"생성한 폴더로 이동하지 않았습니다.");
            Check(window.Find<Button>("SelectButton").IsEnabled && window.Find<Border>("NewFolderPanel").Visibility==Visibility.Collapsed,"생성 후 폴더를 선택할 수 없습니다.");
            Check(window.Find<TextBlock>("PathText").Text.Contains("새 백업 폴더"),"생성한 폴더 경로를 표시하지 않았습니다.");
            await picker.NavigateAsync("");Check(list.Items.Count==72 && picker.Current=="","상위 폴더로 돌아오지 못했습니다.");
            window.Close();Check(lifetime.IsCancellationRequested,"폴더 창 종료 후 요청이 취소되지 않았습니다.");
            var choosingLifetime=new CancellationTokenSource();auxiliaryTokens.Add(choosingLifetime);
            var choosing=new CloudFolderPicker(remote,"테스트 계정",mode,Main,choosingLifetime,TrackAuxiliary);
            choosing.Window.ShowInTaskbar=false;choosing.Window.WindowStartupLocation=WindowStartupLocation.Manual;choosing.Window.Left=-32000;choosing.Window.Top=-32000;
            auxiliary.Add(choosing.Window);choosing.Window.Closed+=(_,_)=>auxiliary.Remove(choosing.Window);
            Exception? selectionFailure=null;
            var timer=new System.Windows.Threading.DispatcherTimer {Interval=TimeSpan.FromMilliseconds(80)};
            timer.Tick+=async (_,_)=>
            {
                timer.Stop();
                try{await choosing.NavigateAsync("새 백업 폴더");choosing.Window.Find<Button>("SelectButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));}
                catch(Exception ex){selectionFailure=ex;choosing.Window.Close();}
            };
            timer.Start();var accepted=choosing.Window.ShowDialog();timer.Stop();if(selectionFailure!=null)throw selectionFailure;
            Check(accepted==true && choosing.Choice?.Reference=="id-새 백업 폴더","새 폴더 선택 버튼이 생성한 폴더 ID를 반환하지 않았습니다.");
            Check(choosing.Choice?.AccountId==remote.AccountId && choosing.Choice.Display.Contains("새 백업 폴더"),"폴더 선택 결과의 계정/표시 경로가 다릅니다.");
        }
        return assertions;
    }
    private static IEnumerable<T> VisualChildren<T>(DependencyObject root) where T:DependencyObject
    {
        for(int i=0;i<VisualTreeHelper.GetChildrenCount(root);i++)
        {var child=VisualTreeHelper.GetChild(root,i);if(child is T match)yield return match;foreach(var nested in VisualChildren<T>(child))yield return nested;}
    }
}

internal sealed class FolderPickerTestRemote : IRemoteStore
{
    public string Provider=>"GoogleDrive";public string Root=>"test-root";public string AccountId=>"synthetic-account";
    private readonly Dictionary<string,RemoteItem> folders=new(StringComparer.OrdinalIgnoreCase);
    public int Created;public bool FailCreate;public TaskCompletionSource? BlockCreate;
    public FolderPickerTestRemote()
    {
        foreach(var path in Enumerable.Range(1,70).Select(i=>"폴더 "+i.ToString("D2")).Concat(new[]{"","기존 폴더",".safesync-trash"}))
            folders[path]=new("id-"+path,path,true,0,DateTime.MinValue,DateTime.MinValue,"","");
        folders["file.txt"]=new("file","file.txt",false,10,DateTime.MinValue,DateTime.MinValue,"hash","");
    }
    public Task InitializeAsync(CancellationToken token)=>Task.CompletedTask;
    public Task<RemoteItem?> StatAsync(string relative,CancellationToken token){token.ThrowIfCancellationRequested();return Task.FromResult(folders.GetValueOrDefault(relative));}
    public Task<IReadOnlyList<RemoteItem>> ListAsync(string directory,CancellationToken token){token.ThrowIfCancellationRequested();return Task.FromResult<IReadOnlyList<RemoteItem>>(folders.Where(p=>p.Key.Length>0 && RemotePath.Parent(p.Key)==directory).Select(p=>p.Value).ToArray());}
    public async Task EnsureFolderAsync(string path,CancellationToken token)
    {
        if(FailCreate)throw new IOException("모사 권한 오류");if(BlockCreate!=null)await BlockCreate.Task.WaitAsync(token);
        Created++;folders[path]=new("id-"+path,RemotePath.Name(path),true,0,DateTime.MinValue,DateTime.MinValue,"","");
    }
    public Task<RemoteItem> UploadAsync(UploadSnapshot snapshot,string path,UploadSession session,Action save,PauseGate pause,CancellationToken token)=>throw new NotSupportedException();
    public Task<RemoteItem> MoveAsync(string from,string to,CancellationToken token)=>throw new NotSupportedException();
    public Task DownloadAsync(string relative,string localPath,CancellationToken token)=>throw new NotSupportedException();
    public Task DeleteAsync(string relative,CancellationToken token)=>throw new NotSupportedException();
}
