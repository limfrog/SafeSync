using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("SafeSync")]
[assembly: AssemblyDescription("SafeSync personal Windows backup launcher")]
[assembly: AssemblyVersion("1.9.12.0")]
[assembly: AssemblyFileVersion("1.9.12.0")]

internal static class Launcher
{
    internal static string Quote(string value)
    {
        // Correct Windows argument quoting, including trailing backslashes.
        var result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1);
            else result.Append('\\', slashes);
            result.Append(c); slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool checkOnly = args.Length == 1 && args[0] == "/check";
        bool visible = false;
        foreach (string arg in args)
        {
            if (arg == "/check" || arg.Equals("-Minimized", StringComparison.OrdinalIgnoreCase)) continue;
            if (arg.Equals("-StartVisible", StringComparison.OrdinalIgnoreCase)) { visible = true; continue; }
            if (!checkOnly) MessageBox.Show("지원하지 않는 실행 옵션입니다.", "SafeSync", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 2;
        }
        try
        {
            string root = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            foreach (string name in new[] { "SafeSync.ps1", "SafeSync.Cloud.ps1", "SafeSync.Integrity.ps1", "SafeSync.TrashWorker.ps1" })
                if (!File.Exists(Path.Combine(root, name))) throw new FileNotFoundException("앱 구성 파일이 없습니다. 설치 프로그램으로 다시 설치해 주세요.", name);
            string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powershell)) throw new FileNotFoundException("Windows PowerShell 5.1을 찾을 수 없습니다.");
            if (checkOnly) return 0;
            bool created;
            using (var guard = new Mutex(true, @"Local\SafeSync.Launch", out created))
            {
                if (!created)
                {
                    MessageBox.Show("SafeSync가 이미 실행 중입니다. 알림 영역 아이콘에서 앱을 열어 주세요.", "SafeSync", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }
                try
                {
                    var errors = new StringBuilder();
                    var info = new ProcessStartInfo(powershell,
                        "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " + Quote(Path.Combine(root, "SafeSync.ps1")) + (visible ? " -StartVisible" : " -Minimized"));
                    info.WorkingDirectory = root;
                    info.UseShellExecute = false; info.CreateNoWindow = true;
                    info.RedirectStandardError = true; info.RedirectStandardOutput = true;
                    using (var process = new Process())
                    {
                        process.StartInfo = info;
                        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) lock (errors) { if (errors.Length < 32000) errors.AppendLine(e.Data); } };
                        process.OutputDataReceived += delegate { };
                        process.Start(); process.BeginErrorReadLine(); process.BeginOutputReadLine();
                        process.WaitForExit();
                        if (process.ExitCode != 0)
                        {
                            string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeSync");
                            Directory.CreateDirectory(logDir);
                            File.AppendAllText(Path.Combine(logDir, "launcher.log"), DateTime.Now.ToString("s") + Environment.NewLine + errors.ToString() + Environment.NewLine, Encoding.UTF8);
                            throw new InvalidOperationException("SafeSync 실행 중 오류가 발생했습니다. 설치 프로그램으로 다시 설치해 주세요.\r\n오류 기록: " + Path.Combine(logDir, "launcher.log"));
                        }
                        return process.ExitCode;
                    }
                }
                finally { guard.ReleaseMutex(); }
            }
        }
        catch (Exception ex)
        {
            if (!checkOnly) MessageBox.Show(ex.Message, "SafeSync 실행 오류", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
