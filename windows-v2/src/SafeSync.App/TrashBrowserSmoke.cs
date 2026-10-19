using System;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
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
    private async Task<int> TestTrashBrowserAsync(string? previewDirectory)
    {
        int assertions=0;
        void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        async Task RunCase<T>(string provider,string mode,ObservableCollection<T> items,Func<T,TrashRowInfo> describe)
        {
            var job=new BackupJob {Name="스튜디오 백업",Source="Z:\\Source",Destination=provider=="Local" ? "Z:\\Backup\\Studio" : provider+" / Backup / Studio",DestinationType=provider};
            var window=NewDialog("Trash",false);Theme.Apply(window,mode);
            using var presentation=new TrashBrowserPresentation<T>(window,items,describe,job,100,provider=="Dropbox");
            var grid=window.Find<DataGrid>("TrashGrid");Click(window,"SelectAllButton",grid.SelectAll);
            presentation.SetState(false,true);window.Find<TextBlock>("StatusText").Text="파일 목록 확인 완료";window.Show();window.UpdateLayout();
            await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            Check(grid.Items.Count==63 && window.Find<TextBlock>("TotalsText").Text.Contains("63"),provider+" file totals missing");
            Check(grid.IsReadOnly && !grid.CanUserDeleteRows && Main.IsEnabled && window.Owner==null,"Trash blocks main window or allows row deletion");
            grid.SelectedItem=grid.Items[0];var selected=describe((T)grid.Items[0]);
            Check(window.Find<TextBox>("SelectedOriginalPath").Text==selected.OriginalPath && window.Find<TextBox>("SelectedOriginalPath").IsReadOnly,"Full original path is missing or editable");
            Check(window.Find<TextBlock>("SelectionText").Text.Contains("1개") && window.Find<Button>("RestoreButton").IsEnabled,"Selected summary or restore state missing");
            Check(window.Find<TextBlock>("DeletionPolicyText").Text.Contains(provider=="Dropbox" ? "Dropbox" : "되돌릴 수"),"Provider deletion policy missing");
            window.Find<TextBox>("SearchBox").Text="TAKE.WAV";
            Check(grid.SelectedItems.Count==0 && !window.Find<Button>("DeleteButton").IsEnabled,"Typing a filter retained hidden destructive selection");
            await Task.Delay(350);
            Check(grid.Items.Count==1 && describe((T)grid.Items[0]).Name=="Session take.wav","Case-insensitive file search failed");
            window.Find<TextBox>("SearchBox").Text="ARCHIVE-2025";await Task.Delay(350);
            Check(grid.Items.Count==1 && describe((T)grid.Items[0]).Name=="notes.txt","Original-path search failed");
            window.Find<Button>("SelectAllButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(grid.SelectedItems.Count==1,"Select-all includes files hidden by search");
            window.Find<Button>("ClearSearchButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await Task.Delay(350);
            window.Find<Button>("SelectAllButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(grid.SelectedItems.Count==63 && window.Find<TextBlock>("SelectionText").Text.Contains("63"),"Multi-selection summary failed");
            presentation.SetState(true,true);
            Check(!window.Find<Button>("DeleteButton").IsEnabled && !window.Find<Button>("RestoreButton").IsEnabled && window.Find<Button>("CloseButton").IsEnabled && window.IsEnabled,"Busy state blocks close or permits destructive action");
            presentation.SetState(false,false);
            Check(!window.Find<Button>("RestoreButton").IsEnabled && !window.Find<Button>("DeleteButton").IsEnabled,"Backup-running guard lost");
            presentation.SetState(false,true);window.Find<Button>("ClearSelectionButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Check(grid.SelectedItems.Count==0 && !window.Find<Button>("RestoreButton").IsEnabled,"Clear selection failed");
            grid.SelectedItems.Add(grid.Items[0]);grid.SelectedItems.Add(grid.Items[1]);window.UpdateLayout();
            Check(window.Find<TextBlock>("SelectionText").Text.Contains("2개") && window.Find<Button>("DeleteButton").Content.ToString()!.Contains("2"),"Multiple-file operation count missing");
            var scroll=VisualChildren<System.Windows.Controls.Primitives.ScrollBar>(grid).First(b=>b.IsVisible);
            Check(((SolidColorBrush)scroll.Background).Color==((SolidColorBrush)window.Resources["SafeSyncSubtleBrush"]).Color,"Trash scrollbar does not use theme colors");
            void Render(string name)
            {
                if(previewDirectory==null)return;window.UpdateLayout();var bitmap=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(window);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var output=File.Create(Path.Combine(previewDirectory,name+"-"+provider+"-"+mode+".png"));png.Save(output);
            }
            Render("TrashBrowser");window.Width=740;window.Height=560;window.UpdateLayout();await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            var root=window.Find<Grid>("TrashRoot");var viewport=(FrameworkElement)VisualTreeHelper.GetParent(root);
            var footer=window.Find<TextBlock>("DeletionPolicyText");
            Check(footer.TransformToAncestor(viewport).TransformBounds(new Rect(footer.RenderSize)).Bottom<=viewport.ActualHeight+1,"Compact trash hides footer");
            Check(grid.Columns.All(c=>c.ActualWidth>=c.MinWidth-.5) && grid.ActualHeight>70,"Compact trash hides columns or file list");
            Render("TrashBrowser-Compact");
            window.Find<TextBox>("SearchBox").Text="no-such-file";await Task.Delay(350);
            Check(grid.Items.Count==0 && window.Find<TextBlock>("EmptyText").Text.Contains("검색"),"Empty search state missing");
            window.Close();
        }
        foreach(var mode in new[]{"Light","Dark"})
        foreach(var provider in new[]{"Local","GoogleDrive","Dropbox"})
        {
            var rows=Enumerable.Range(0,63).Select(i=>new TrashItem("synthetic-only-"+i,i==0 ? "Session take.wav" : i==1 ? "notes.txt" : "Audio track "+i.ToString("D2")+".wav",DateTime.Now.AddDays(-i),"Z:\\Backup\\Studio\\"+(i==1 ? "Archive-2025" : "Audio")+"\\"+(i==0 ? "Session take.wav" : "track-"+i+".wav"),"track-"+i+".wav",2048+i*1024L)).ToArray();
            if(provider=="Local")await RunCase(provider,mode,new ObservableCollection<TrashItem>(rows),r=>new(r.Name,r.OriginalPath,r.DeletedAt,r.Length));
            else
            {
                var cloudRows=new ObservableCollection<CloudTrashItem>(rows.Select(r=>new CloudTrashItem(r.StoragePath,r.RelativePath,r.DeletedAt,new("id-"+r.RelativePath,r.Name,false,r.Length,DateTime.UtcNow,DateTime.UtcNow,"hash","rev"),r.OriginalPath)));
                // CloudTrashItem derives Name from RelativePath rather than Item.Name.
                for(int i=0;i<cloudRows.Count;i++)cloudRows[i]=cloudRows[i] with{RelativePath=rows[i].Name};
                await RunCase(provider,mode,cloudRows,r=>new(r.Name,r.OriginalPath,r.DeletedAt,r.Length));
            }
        }
        return assertions;
    }
}
