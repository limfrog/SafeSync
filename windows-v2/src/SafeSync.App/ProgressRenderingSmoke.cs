using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media.Imaging;
using System.Windows.Media;
using SafeSync.Core;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task<int> TestProgressRenderingAsync(string? previewDirectory)
    {
        int assertions=0;
        void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        foreach(var mode in new[]{"Light","Dark"})
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            var job=new BackupJob {Name="진행률 회귀 검사 · "+provider,Source=Path.Combine(store.Root,"smoke-source"),Destination=Path.Combine(store.Root,"smoke-backup"),DestinationType=provider,CloudFolderId=provider=="Local" ? "" : "synthetic-folder",CloudAccountId=provider=="Local" ? "" : "synthetic-account",Paused=true};
            config.Jobs=[job];RefreshJobs();ShowProgress();var window=progressWindow!;Theme.Apply(window,mode);
            var items=window.Find<ItemsControl>("ProgressItems");
            foreach(var (completed,total) in new[]{(0,0),(0,12),(1,12),(6,12),(12,12)})
            {
                OnProgress(new(job.Id,job.Name,"파일 비교 및 백업","한글/테스트.txt",completed,total));
                window.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                var bar=VisualChildren<ProgressBar>(items).Single();
                Check(Math.Abs(bar.Value-(total>0 ? 100d*completed/total : 0))<.001,$"{mode}/{provider}: 진행률 값이 잘못되었습니다.");
                Check(BindingOperations.GetBinding(bar,System.Windows.Controls.Primitives.RangeBase.ValueProperty)?.Mode==BindingMode.OneWay,"읽기 전용 진행률이 양방향으로 연결되어 있습니다.");
            }
            if(previewDirectory!=null && provider=="GoogleDrive")
            {
                var bitmap=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(window);
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var output=File.Create(Path.Combine(previewDirectory,"Progress-Active-"+mode+".png"));encoder.Save(output);
            }
            ToggleProgress();OnProgress(new(job.Id,job.Name,"숨겨진 창의 진행 갱신","한글/테스트.txt",1,2));ToggleProgress();window.UpdateLayout();
            await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            Check(window.IsVisible && Math.Abs(VisualChildren<ProgressBar>(items).Single().Value-50)<.001,"진행 창을 숨겼다 다시 열면 값이 유지되지 않습니다.");
            OnCompleted(job,new BackupResult {Copied=12});window.UpdateLayout();
            await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            Check(items.Items.Count==0 && Main.IsEnabled,"완료 후 진행 항목이 남거나 메인창이 잠겼습니다.");
            window.Hide();
        }
        config.Jobs=[];RefreshJobs();return assertions;
    }
}
