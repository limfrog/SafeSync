using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class NativeSetup
{
    private const string UninstallKey=@"Software\Microsoft\Windows\CurrentVersion\Uninstall\SafeSync2";
    private static string Version
    {
        get
        {
            var attributes=Assembly.GetExecutingAssembly().GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute),false);
            return attributes.Length>0 ? ((AssemblyInformationalVersionAttribute)attributes[0]).InformationalVersion : Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
        }
    }
    private static int result=1;
    private static bool launchAfter;
    [STAThread]
    private static int Main(string[] args)
    {
        AppContext.SetSwitch("Switch.System.IO.UseLegacyPathHandling",false);
        AppContext.SetSwitch("Switch.System.IO.BlockLongPaths",false);
        Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);
        try
        {
#if UNINSTALL
            if(args.Length==0 || args.Length==1 && args[0]=="/uninstall")
            {
                string self=Assembly.GetExecutingAssembly().Location;
                if(!NativeSetupCore.Same(Path.GetDirectoryName(self),NativeSetupCore.DefaultRoot)||!NativeSetupCore.Owned(NativeSetupCore.DefaultRoot))throw new IOException("설치 위치를 확인할 수 없습니다.");
                string temporary=Path.Combine(Path.GetTempPath(),"SafeSync2.uninstall-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(temporary);
                string helper=Path.Combine(temporary,"Uninstall.exe");File.Copy(self,helper);
                Process.Start(new ProcessStartInfo(helper,"/remove "+Process.GetCurrentProcess().Id){UseShellExecute=false,CreateNoWindow=true});return 0;
            }
            int parent;
            if(args.Length!=2||args[0]!="/remove"||!Int32.TryParse(args[1],out parent))return 2;
            string folder=Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            if(!NativeSetupCore.Same(Path.GetDirectoryName(folder),Path.GetTempPath())||!Path.GetFileName(folder).StartsWith("SafeSync2.uninstall-",StringComparison.Ordinal))throw new IOException("제거 보조 프로그램 위치 오류입니다.");
            try{using(var process=Process.GetProcessById(parent))if(!process.WaitForExit(15000))throw new IOException("이전 제거 프로그램을 닫은 뒤 다시 시도하세요.");}catch(ArgumentException){}
            bool remove=true;
#else
            if(args.Length==1 && args[0]=="/verify")
            {
                using(var payload=Payload())NativeSetupCore.Verify(payload,Manifest(),Path.GetTempPath());return 0;
            }
            if(args.Length!=0)return 2;bool remove=false;
#endif
            bool created;using(var guard=new Mutex(false,@"Local\SafeSync2.Deployment",out created))
            {
                if(!created)throw new IOException("SafeSync 설치 또는 제거가 진행 중입니다.");
                Application.Run(new SetupWindow(remove));
            }
            if(launchAfter)Process.Start(new ProcessStartInfo(Path.Combine(NativeSetupCore.DefaultRoot,"SafeSync.exe")){UseShellExecute=false});
            return result;
        }
        catch(Exception ex){MessageBox.Show(ex.Message,"SafeSync 설치/제거",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
    }
    private static Stream Payload(){return Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.zip");}
    private static string Manifest(){using(var reader=new StreamReader(Assembly.GetExecutingAssembly().GetManifestResourceStream("Payload.sha256")))return reader.ReadToEnd();}
    private static void StopApplication(Action<string> status)
    {
        if(!NativeSetupCore.Running())return;status("실행 중인 앱에 안전한 종료를 요청하고 있습니다…");
        try
        {
            using(var pipe=new NamedPipeClientStream(".","SafeSync2.Control",PipeDirection.Out))
            {pipe.Connect(2000);using(var writer=new StreamWriter(pipe,new UTF8Encoding(false))){writer.WriteLine("exit");writer.Flush();}}
        }
        catch(IOException){throw new IOException("앱에 종료 요청을 전달하지 못했습니다. 알림 영역에서 프로그램을 종료한 뒤 다시 시도하세요.");}
        catch(TimeoutException){throw new IOException("앱 종료 연결이 지연됩니다. 알림 영역에서 프로그램을 종료한 뒤 다시 시도하세요.");}
        for(int i=0;i<150 && NativeSetupCore.Running();i++)Thread.Sleep(200);
        if(NativeSetupCore.Running())throw new IOException("앱이 아직 백업 정리를 마치지 못했습니다. 강제 종료하지 않고 설치를 중단했습니다.");
    }
    private sealed class SetupWindow : Form
    {
        private readonly Label status;
        private readonly Button action,close;
        private readonly CheckBox launch;
        private readonly ProgressBar progress;
        private bool working,complete;
        internal SetupWindow(bool remove)
        {
            Text=remove ? "SafeSync 제거" : "SafeSync 설치 · "+Version;
            Font=new Font("Malgun Gothic",10);AutoScaleMode=AutoScaleMode.Dpi;ClientSize=new Size(650,370);MinimumSize=Size;StartPosition=FormStartPosition.CenterScreen;
            var title=new Label{Text=remove ? "SafeSync 프로그램 제거" : "SafeSync 설치",Dock=DockStyle.Top,Height=65,Padding=new Padding(22,18,0,0),Font=new Font(Font.FontFamily,17,FontStyle.Bold)};
            var details=new Label{Text="설정·작업 목록·백업 기록과 실제 백업 파일은 보존합니다.\r\n설치 위치: "+NativeSetupCore.DefaultRoot,Dock=DockStyle.Top,Height=100,Padding=new Padding(24,8,20,0)};
            launch=new CheckBox{Text="설치 완료 후 SafeSync 실행",Checked=false,AutoSize=true,Dock=DockStyle.Top,Padding=new Padding(24,8,0,8),Visible=!remove};
            status=new Label{Text=remove ? "프로그램 파일만 제거합니다." : "프리뷰 버전입니다. 중요한 자료는 별도 백업 후 시험하세요.",Dock=DockStyle.Fill,Padding=new Padding(24,16,20,8)};
            progress=new ProgressBar{Dock=DockStyle.Bottom,Height=8,Style=ProgressBarStyle.Marquee,Visible=false};
            var buttons=new FlowLayoutPanel{Dock=DockStyle.Bottom,Height=65,FlowDirection=FlowDirection.RightToLeft,Padding=new Padding(12)};
            close=new Button{Text="취소",Size=new Size(100,34)};action=new Button{Text=remove ? "제거" : "설치 / 업데이트",Size=new Size(140,34)};
            buttons.Controls.Add(close);buttons.Controls.Add(action);close.Click+=delegate{Close();};
            action.Click+=async delegate
            {
                if(complete){Close();return;}working=true;action.Enabled=false;close.Enabled=false;launch.Enabled=false;progress.Visible=true;
                try
                {
                    await Task.Run(delegate
                    {
                        StopApplication(Status);
                        if(remove)NativeSetupCore.Remove(NativeSetupCore.DefaultRoot,false);
                        else using(var payload=Payload())NativeSetupCore.Install(payload,Manifest(),NativeSetupCore.DefaultRoot,false,Version,Status,null);
                    });
                    if(remove)Unregister();else Register();
                    complete=true;result=0;Status(remove ? "제거 완료. 설정과 백업 자료는 보존했습니다." : "설치 완료. 창은 알림 영역 아이콘에서 열 수 있습니다.");
                    action.Text="닫기";close.Visible=false;
                    launchAfter=!remove && launch.Checked;
                }
                catch(Exception ex){Status(ex.Message);}
                finally{working=false;action.Enabled=true;close.Enabled=true;progress.Visible=false;}
            };
            FormClosing+=delegate(object sender,FormClosingEventArgs e){if(working)e.Cancel=true;};
            Controls.Add(status);Controls.Add(launch);Controls.Add(details);Controls.Add(title);Controls.Add(progress);Controls.Add(buttons);
        }
        private void Status(string text){if(InvokeRequired){BeginInvoke(new Action<string>(Status),text);return;}status.Text=text;}
    }
    private static void Register()
    {
        string root=NativeSetupCore.DefaultRoot;
        using(var old=Registry.CurrentUser.OpenSubKey(UninstallKey))if(old!=null&&!NativeSetupCore.Same(Convert.ToString(old.GetValue("InstallLocation")),root))throw new IOException("다른 위치의 프로그램 등록을 덮어쓰지 않았습니다.");
        using(var key=Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName",NativeSetupCore.DisplayName+" (1.0.0 Preview)");key.SetValue("DisplayVersion",Version);key.SetValue("Publisher","Horizon Entertainment");
            key.SetValue("Contact","apps@horizonent.co.kr");key.SetValue("HelpLink","mailto:apps@horizonent.co.kr");
            key.SetValue("URLInfoAbout","https://www.horizonent.co.kr/apps/safesync/");
            key.SetValue("InstallLocation",root);key.SetValue("DisplayIcon",Path.Combine(root,"SafeSync.exe"));
            key.SetValue("UninstallString","\""+Path.Combine(root,"Uninstall.exe")+"\" /uninstall");key.SetValue("NoModify",1);key.SetValue("NoRepair",1);
        }
        Shortcut(false);
    }
    private static void Unregister()
    {
        using(var key=Registry.CurrentUser.OpenSubKey(UninstallKey))if(key!=null&&NativeSetupCore.Same(Convert.ToString(key.GetValue("InstallLocation")),NativeSetupCore.DefaultRoot))Registry.CurrentUser.DeleteSubKeyTree(UninstallKey,false);
        using(var run=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run",true))
            if(run!=null&&String.Equals(run.GetValue("SafeSync2") as string,"\""+Path.Combine(NativeSetupCore.DefaultRoot,"SafeSync.exe")+"\"",StringComparison.OrdinalIgnoreCase))run.DeleteValue("SafeSync2",false);
        Shortcut(true);
    }
    private static void Shortcut(bool remove)
    {
        string programs=Environment.GetFolderPath(Environment.SpecialFolder.Programs),target=Path.Combine(NativeSetupCore.DefaultRoot,"SafeSync.exe");
        string normal=Path.Combine(programs,NativeSetupCore.DisplayName+".lnk"),fallback=Path.Combine(programs,"SafeSync","SafeSync.lnk");
        if(remove){ShortcutAt(normal,target,true);ShortcutAt(fallback,target,true);}
        else if(!ShortcutAt(normal,target,false)){NativeSetupCore.NoLinks(fallback);Directory.CreateDirectory(Path.GetDirectoryName(fallback));if(!ShortcutAt(fallback,target,false))throw new IOException("다른 바로 가기를 덮어쓰지 않았습니다.");}
        // Remove only our own former link; leave unrelated/legacy shortcuts alone.
        ShortcutAt(Path.Combine(programs,"SafeSync 2.lnk"),target,true);
    }
    private static bool ShortcutAt(string path,string target,bool remove)
    {
        if(remove&&!File.Exists(path))return true;
        NativeSetupCore.NoLinks(path);object shell=null,link=null;
        try
        {
            var type=Type.GetTypeFromProgID("WScript.Shell");shell=Activator.CreateInstance(type);
            link=type.InvokeMember("CreateShortcut",BindingFlags.InvokeMethod,null,shell,new object[]{path});var linkType=link.GetType();
            string current=Convert.ToString(linkType.InvokeMember("TargetPath",BindingFlags.GetProperty,null,link,null));
            if(File.Exists(path)&&!NativeSetupCore.Same(current,target))return false;
            if(remove){if(File.Exists(path))File.Delete(path);return true;}
            linkType.InvokeMember("TargetPath",BindingFlags.SetProperty,null,link,new object[]{target});linkType.InvokeMember("WorkingDirectory",BindingFlags.SetProperty,null,link,new object[]{NativeSetupCore.DefaultRoot});linkType.InvokeMember("Save",BindingFlags.InvokeMethod,null,link,null);
            return true;
        }
        finally{if(link!=null)System.Runtime.InteropServices.Marshal.FinalReleaseComObject(link);if(shell!=null)System.Runtime.InteropServices.Marshal.FinalReleaseComObject(shell);}
    }
}
