using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("SafeSync Uninstaller")]
[assembly: AssemblyDescription("Removes SafeSync application files; preserves backup data and settings")]
[assembly: AssemblyVersion("1.9.13.0")]
[assembly: AssemblyFileVersion("1.9.13.0")]

internal static class Uninstall
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        try
        {
            string self = Assembly.GetExecutingAssembly().Location;
            if (args.Length == 0 || (args.Length == 1 && args[0] == "/uninstall"))
            {
                string root = Path.GetDirectoryName(self);
                InstallerCore.ValidateRoot(root, false);
                if (!InstallerCore.IsOwned(root)) throw new IOException("SafeSync 설치 폴더에서만 제거할 수 있습니다.");
                // Run outside the install folder so Windows allows removing the original executable.
                string temporary = Path.Combine(Path.GetTempPath(), "SafeSync.uninstall-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temporary);
                string helper = Path.Combine(temporary, "Uninstall.exe"); File.Copy(self, helper, false);
                Process.Start(new ProcessStartInfo(helper, "/remove " + Process.GetCurrentProcess().Id.ToString()) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = temporary });
                return 0;
            }
            if (args.Length != 2 || args[0] != "/remove") return 2;
            int parentId;
            if (!Int32.TryParse(args[1], out parentId)) return 2;
            string helperFolder = Path.GetDirectoryName(self);
            if (!InstallerCore.SamePath(Path.GetDirectoryName(helperFolder), Path.GetTempPath()) || !Path.GetFileName(helperFolder).StartsWith("SafeSync.uninstall-", StringComparison.Ordinal))
                throw new IOException("제거 보조 프로그램 위치를 확인할 수 없습니다.");
            try { using (var parent = Process.GetProcessById(parentId)) if (!parent.WaitForExit(15000)) throw new IOException("제거 프로그램이 종료되기를 기다리는 중입니다. 잠시 후 다시 시도해 주세요."); }
            catch (ArgumentException) { /* Parent already exited. */ }
            bool created;
            using (var guard = new Mutex(true, @"Local\SafeSync.Install", out created))
            {
                if (!created) throw new IOException("SafeSync 설치 또는 제거가 이미 진행 중입니다.");
                try
                {
                    Application.Run(new InstallerForm(true, delegate(InstallerForm form) {
                        form.SetStatus("SafeSync 프로그램 파일을 제거하고 있습니다…");
                        InstallerCore.Remove(InstallerCore.DefaultRoot, false);
                        form.Complete("제거가 완료되었습니다. 백업 파일과 기존 설정은 그대로 남아 있습니다.");
                    }));
                }
                finally { guard.ReleaseMutex(); }
            }
            // Only the executing helper remains in Windows TEMP; no background cleanup process is needed.
            return 0;
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "SafeSync 제거 오류", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
    }
}
