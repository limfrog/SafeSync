using System;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace SafeSync.App;

internal sealed partial class DesktopController
{
    private async Task<int> TestReleaseUiAsync()
    {
        int assertions=0;
        void Check(bool value,string message){if(!value)throw new InvalidOperationException(message);assertions++;}
        string name="SafeSync2.Test.Control."+Guid.NewGuid().ToString("N");int exits=0;
        using(var control=new ControlChannel(()=>{exits++;return Task.CompletedTask;},name))
        using(var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(4)))
        {
            async Task Send(string text)
            {
                await using var client=new NamedPipeClientStream(".",name,PipeDirection.Out,PipeOptions.Asynchronous);
                await client.ConnectAsync(timeout.Token);await client.WriteAsync(Encoding.UTF8.GetBytes(text),timeout.Token);await client.FlushAsync(timeout.Token);
            }
            await Send("nope\n");await Task.Delay(40);Check(exits==0,"Invalid IPC command requested exit");
            await Send("exit\r\n");
            for(int i=0;i<100 && exits==0;i++)await Task.Delay(10);
            Check(exits==1,"Installer CRLF shutdown command was ignored");
        }
        foreach(string mode in new[]{"Light","Dark"})
        {
            var window=NewDialog("Settings",false);Theme.Apply(window,mode);window.Show();
            var diagnostic=window.Find<CheckBox>("OperationLogCheck");
            Check(diagnostic.ToolTip?.ToString()?.Contains("검증") == true,"Diagnostic option lacks guidance");
            foreach(var size in new[]{new Size(window.MinWidth,window.MinHeight),new Size(850,700)})
            {
                window.Width=size.Width;window.Height=size.Height;window.UpdateLayout();
                await window.Dispatcher.InvokeAsync(()=>{},System.Windows.Threading.DispatcherPriority.ApplicationIdle);
                var button=window.Find<Button>("SaveButton");var point=button.TranslatePoint(new Point(),window);
                Check(point.Y>=0 && point.Y+button.ActualHeight<=window.ActualHeight,"Settings save button clipped at minimum size");
                Check(button.ActualWidth>60 && button.IsVisible,"Settings buttons are unusable");
            }
            window.Close();
        }
        return assertions;
    }
}
