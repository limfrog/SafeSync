using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task<int> TestWorkspaceToolbarAsync(string? previewDirectory,Action<Action,Action<Window>> checkModal)
    {
        int assertions=0;
        void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        Check(Main.Find<ContentControl>("TrashWorkspaceHost").Content is TextBlock hint && hint.Text.Contains("이 탭") && !hint.Text.Contains("버튼"),"Empty trash guidance still points to a removed toolbar button");
        var previousTheme=config.ThemeMode;var previousWidth=Main.Width;var previousHeight=Main.Height;
        Rect Bounds(FrameworkElement element)=>element.TransformToAncestor(Main).TransformBounds(new Rect(element.RenderSize));
        try
        {
            foreach(var mode in new[]{"Light","Dark"})
            {
                config.ThemeMode=mode;Theme.Apply(Main,mode);
                foreach(var tabName in new[]{"MainTab","SyncWorkspaceTab","TrashWorkspaceTab"})
                {
                    SelectWorkspace(tabName);
                    foreach(var size in new[]{new Size(800,540),new Size(1180,720)})
                    {
                        Main.Width=size.Width;Main.Height=size.Height;Main.UpdateLayout();
                        await Main.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                        var settings=Main.Find<Button>("SettingsShortcutButton");var settingsBounds=Bounds(settings);
                        var tabs=new[]{"MainTab","SyncWorkspaceTab","TrashWorkspaceTab"}.Select(name=>Bounds(Main.Find<TabItem>(name))).ToArray();
                        Check(settings.IsVisible && settings.IsEnabled && Window.GetWindow(settings)==Main,"Settings disappeared or became disabled after tab change");
                        Check(tabs.All(tab=>Math.Abs((tab.Top+tab.Bottom-settingsBounds.Top-settingsBounds.Bottom)/2)<2),"Settings is not aligned with the tab header row");
                        Check(tabs.Max(tab=>tab.Right)+8<=settingsBounds.Left && settingsBounds.Right<=Main.ActualWidth,"Settings overlaps tab headers at compact size");
                        Check(Main.FindName("TrashShortcutButton")==null && Main.FindName("ProgressButton")==null,"Redundant trash/status buttons remain in the toolbar");
                        Check(Main.Find<WrapPanel>("JobCommandBar").IsVisible==(tabName=="MainTab"),"Job commands leaked into a non-job tab");
                        if(tabName=="MainTab")
                        {
                            var add=Bounds(Main.Find<Button>("AddButton"));var manage=Bounds(Main.Find<Button>("JobActionsButton"));var run=Bounds(Main.Find<Button>("RunButton"));
                            Check(manage.Left>=add.Right && manage.Right<run.Left && Math.Abs(manage.Top-add.Top)<1,"Job management is not in the left command group");
                            Check(manage.Left-Bounds(Main.Find<WrapPanel>("JobCommandBar")).Left<200,"Job management remains right-aligned");
                        }
                    }
                    checkModal(()=>Main.Find<Button>("SettingsShortcutButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)),dialog=>
                    {
                        Check(dialog.Find<Button>("SaveButton").IsVisible,"Shared settings shortcut did not open the settings dialog");
                        Check(Main.Find<TabItem>(tabName).IsSelected,"Opening settings changed the selected workspace tab");
                    });
                    Check(Main.Find<Button>("SettingsShortcutButton").IsVisible && Main.IsEnabled,"Closing settings did not restore the active workspace");
                    if(previewDirectory!=null)
                    {
                        Main.UpdateLayout();var bitmap=new RenderTargetBitmap((int)Math.Ceiling(Main.ActualWidth),(int)Math.Ceiling(Main.ActualHeight),96,96,System.Windows.Media.PixelFormats.Pbgra32);bitmap.Render(Main);
                        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
                        using var output=File.Create(Path.Combine(previewDirectory,"WorkspaceToolbar-"+tabName+"-"+mode+".png"));encoder.Save(output);
                    }
                }
            }
        }
        finally
        {
            SelectWorkspace("MainTab");config.ThemeMode=previousTheme;Theme.Apply(Main,previousTheme);Main.Width=previousWidth;Main.Height=previousHeight;Main.UpdateLayout();
        }
        return assertions;
    }
}
