using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Markup;
using SafeSync.Core;

namespace SafeSync.App;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var smoke = args.Contains("--smoke-test");
        if(!smoke && Mutex.TryOpenExisting("Local\\SafeSync2.Deployment",out var deployment)){deployment.Dispose();return 1;}
        using var mutex = new Mutex(true,smoke ? "Local\\SafeSync2.Smoke." + Guid.NewGuid().ToString("N") : "Local\\SafeSync2.Preview",out var created);
        if (!created) return 0;
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        try
        {
            var root = Argument(args,"--data-root") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"SafeSync2-Preview");
            var legacy = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"SafeSync");
            if (string.Equals(PathPolicy.Root(root),PathPolicy.Root(legacy),StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("전환 검증본은 기존 1.x 데이터 폴더를 직접 사용할 수 없습니다.");
            if (smoke && Argument(args,"--data-root") == null) throw new ArgumentException("검사는 격리된 데이터 폴더가 필요합니다.");
            var controller = new DesktopController(application,new ConfigStore(root),smoke);
            using var control=smoke ? null : new ControlChannel(()=>application.Dispatcher.InvokeAsync(controller.ExitAsync).Task.Unwrap());
            application.MainWindow = controller.Main;
            if (smoke)
            {
                application.Dispatcher.InvokeAsync(async () =>
                {
                    try
                    {
                        var assertions=await controller.SmokeTestAsync(Argument(args,"--preview-dir"));
                        JsonFile.Save(Path.Combine(root,"smoke-result.json"),new {Status="OK",Assertions=assertions,NativeRuntime=true,PowerShellLoaded=AppDomain.CurrentDomain.GetAssemblies().Any(a => a.GetName().Name == "System.Management.Automation"),RuntimeLocation=typeof(object).Assembly.Location,DesktopRuntimeLocation=typeof(Window).Assembly.Location});
                        await controller.ExitAsync();
                    }
                    catch (Exception ex)
                    {
                        JsonFile.Save(Path.Combine(root,"smoke-result.json"),new {Status="FAILED",Error=ex.ToString()});
                        application.Shutdown(1);
                    }
                });
            }
            else if (args.Contains("--show")) controller.ShowMain();
            return application.Run();
        }
        catch (Exception ex)
        {
            if(smoke)
            {
                var root=Argument(args,"--data-root");
                if(root!=null)JsonFile.Save(Path.Combine(root,"smoke-result.json"),new {Status="FAILED",Error=ex.ToString()});
                return 1;
            }
            // Never silently replace unreadable settings with an empty config.
            var error = new Window { Title="SafeSync 시작 오류",Width=580,SizeToContent=SizeToContent.Height,WindowStartupLocation=WindowStartupLocation.CenterScreen };
            var panel = new System.Windows.Controls.StackPanel { Margin=new Thickness(24) };
            panel.Children.Add(new System.Windows.Controls.TextBlock { Text=ex.Message,TextWrapping=TextWrapping.Wrap });
            var close = new System.Windows.Controls.Button { Content="닫기",Margin=new Thickness(0,16,0,0),Padding=new Thickness(14,7,14,7) };
            close.Click += (_,_) => error.Close();panel.Children.Add(close);error.Content=panel;error.ShowDialog();
            return 1;
        }
        finally { mutex.ReleaseMutex(); }
    }
    private static string? Argument(string[] args,string name)
    {
        var index = Array.IndexOf(args,name);
        if (index < 0) return null;
        if (index + 1 >= args.Length) throw new ArgumentException(name + " 값이 없습니다.");
        return args[index+1];
    }
}

internal static class Views
{
    public static Window Load(string name)
        => (Window)LoadElement(name);
    public static FrameworkElement LoadElement(string name)
    {
        var resource = Application.GetResourceStream(new Uri("pack://application:,,,/SafeSync;component/Views/" + name + ".xaml"))
            ?? throw new InvalidOperationException("화면 리소스가 없습니다: " + name);
        using var stream = resource.Stream;
        return (FrameworkElement)XamlReader.Load(stream);
    }
    public static T Find<T>(this FrameworkElement window,string name) where T : class => window.FindName(name) as T
        ?? throw new InvalidOperationException("화면 요소가 없습니다: " + name);
}
