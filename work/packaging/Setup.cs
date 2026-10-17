using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("SafeSync Setup")]
[assembly: AssemblyDescription("SafeSync personal per-user installer")]
[assembly: AssemblyVersion("1.9.12.0")]
[assembly: AssemblyFileVersion("1.9.12.0")]

internal static class Setup
{
    private static Stream Payload { get { return Assembly.GetExecutingAssembly().GetManifestResourceStream("SafeSync.Payload.zip"); } }
    private static string Manifest {
        get { using (var input = new StreamReader(Assembly.GetExecutingAssembly().GetManifestResourceStream("SafeSync.Payload.sha256"), Encoding.UTF8)) return input.ReadToEnd(); }
    }
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "/verify")
        {
            string sandbox = Path.Combine(Path.GetTempPath(), "SafeSync.verify-" + Guid.NewGuid().ToString("N"));
            try
            {
                using (Stream stream = Payload) InstallerCore.Extract(stream, Manifest, sandbox);
                foreach (string name in InstallerCore.PayloadNames.ConcatNames(InstallerCore.Inventory)) File.Delete(Path.Combine(sandbox, name));
                Directory.Delete(sandbox, false); return 0;
            }
            catch { return 1; }
        }
        if (args.Length != 0) return 2;
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        bool created;
        using (var guard = new Mutex(true, @"Local\SafeSync.Install", out created))
        {
            if (!created) { MessageBox.Show("SafeSync 설치 또는 제거가 이미 진행 중입니다.", "SafeSync", MessageBoxButtons.OK, MessageBoxIcon.Information); return 1; }
            try
            {
                Application.Run(new InstallerForm(false, delegate(InstallerForm form) {
                    using (Stream zip = Payload) InstallerCore.Install(zip, Manifest, InstallerCore.DefaultRoot, false, form.SetStatus, null);
                    string warning = "";
                    try { InstallerCore.Register(InstallerCore.DefaultRoot, form.DesktopBox.Checked); }
                    catch (Exception ex) { warning = "\r\n바로 가기/프로그램 등록 오류: " + ex.Message; }
                    form.Complete("설치가 완료되었습니다. 알림 영역 아이콘에서 앱을 열 수 있습니다.");
                    if (form.LaunchBox.Checked)
                    {
                        try { Process.Start(new ProcessStartInfo(Path.Combine(InstallerCore.DefaultRoot, "SafeSync.exe")) { WorkingDirectory = InstallerCore.DefaultRoot, UseShellExecute = false, CreateNoWindow = true }); }
                        catch (Exception ex) { warning += "\r\n앱 실행 오류: " + ex.Message; }
                    }
                    if (warning.Length > 0) MessageBox.Show(form, "프로그램 파일은 설치되었습니다." + warning + "\r\n설치 위치의 SafeSync.exe로 직접 실행하거나 설치를 다시 시도해 주세요.", "SafeSync 설치 안내", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }));
                return 0;
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "SafeSync 설치 오류", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
            finally { guard.ReleaseMutex(); }
        }
    }
    private static string[] ConcatNames(this string[] names, string extra)
    {
        string[] all = new string[names.Length + 1]; Array.Copy(names, all, names.Length); all[names.Length] = extra; return all;
    }
}
