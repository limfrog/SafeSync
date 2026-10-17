using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32;

internal static class InstallerCore
{
    internal const string ProductId = "SafeSync.Personal.5ee5918b-7649-4ab0-ae49-35e598017f90";
    internal const string Version = "1.9.11";
    internal const string Marker = ".safesync-install";
    internal const string Inventory = "installed-files.sha256";
    internal const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\SafeSync";
    internal static readonly string[] PayloadNames = {
        "SafeSync.exe", "SafeSync.exe.config", "SafeSync.ps1", "SafeSync.Cloud.ps1",
        "SafeSync.Integrity.ps1", "SafeSync.TrashWorker.ps1", "SafeSync.ico", "SafeSync-Progress-0.ico", "SafeSync-Progress-1.ico", "SafeSync-Progress-2.ico", "SafeSync-Progress-3.ico", "Start SafeSync.cmd", "README-ko.md", "Uninstall.exe"
    };
    internal static readonly string[] OwnedNames = PayloadNames.Concat(new[] { Marker, Inventory }).ToArray();
    internal static string DefaultRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "SafeSync"); } }
    internal static string DataRoot { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SafeSync"); } }
    internal static string Canonical(string path) { return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
    internal static bool SamePath(string a, string b)
    {
        if (String.IsNullOrWhiteSpace(a) || String.IsNullOrWhiteSpace(b)) return false;
        try { return String.Equals(Canonical(a), Canonical(b), StringComparison.OrdinalIgnoreCase); }
        catch (ArgumentException) { return false; }
        catch (NotSupportedException) { return false; }
        catch (PathTooLongException) { return false; }
    }
    internal static string Hash(string path) { using (var input = File.OpenRead(path)) using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(input)).Replace("-", "").ToLowerInvariant(); }
    internal static void NoLinks(string path)
    {
        for (string current = Canonical(path); !String.IsNullOrEmpty(current); current = Path.GetDirectoryName(current))
            if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("설치 경로에 연결 폴더가 있어 안전하게 진행할 수 없습니다: " + current);
    }
    internal static void ValidateRoot(string root, bool testMode)
    {
        root = Canonical(root);
        if (!testMode && !SamePath(root, DefaultRoot)) throw new IOException("허용되지 않은 설치 경로입니다.");
        if (String.IsNullOrEmpty(Path.GetDirectoryName(root)) || SamePath(root, Path.GetPathRoot(root)) || SamePath(root, DataRoot))
            throw new IOException("설치 경로가 안전하지 않습니다.");
        if (testMode && !File.Exists(Path.Combine(Path.GetDirectoryName(root), ".safesync-test-sandbox")))
            throw new IOException("테스트 전용 폴더 표시가 없습니다.");
        NoLinks(root);
    }
    internal static void WriteMarker(string root)
    {
        File.WriteAllLines(Path.Combine(root, Marker), new[] { ProductId, Canonical(root), Version }, Encoding.UTF8);
    }
    internal static bool IsOwned(string root)
    {
        if (!Directory.Exists(root) || !File.Exists(Path.Combine(root, Marker))) return false;
        NoLinks(root); NoLinks(Path.Combine(root, Marker));
        string[] lines = File.ReadAllLines(Path.Combine(root, Marker), Encoding.UTF8);
        return lines.Length == 3 && lines[0] == ProductId && SamePath(lines[1], root);
    }
    internal static bool MutexExists(string name)
    {
        Mutex value;
        if (!Mutex.TryOpenExisting(name, out value)) return false;
        value.Dispose(); return true;
    }
    internal static string MainGuardName(string root, bool testMode)
    {
        if (!testMode) return @"Local\SafeSync.Main";
        using (var sha = SHA256.Create())
            return @"Local\SafeSync.Test.Main." + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Canonical(root).ToLowerInvariant()))).Replace("-", "");
    }
    internal static string LaunchGuardName(string root, bool testMode)
    {
        if (!testMode) return @"Local\SafeSync.Launch";
        using (var sha = SHA256.Create())
            return @"Local\SafeSync.Test.Launch." + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(Canonical(root).ToLowerInvariant()))).Replace("-", "");
    }
    internal static void EnsureStopped(string root, bool testMode)
    {
        int attempts = testMode ? 1 : 16;
        bool busy = false;
        for (int i = 0; i < attempts; i++)
        {
            busy = MutexExists(MainGuardName(root, testMode)) || MutexExists(LaunchGuardName(root, testMode)) || MutexExists(WorkerName(root));
            if (!busy) break;
            if (i + 1 < attempts) Thread.Sleep(125);
        }
        if (busy)
            throw new IOException("SafeSync가 실행 중입니다. 알림 영역 아이콘에서 ‘프로그램 종료’를 선택한 뒤 다시 시도해 주세요.");
    }
    internal static string WorkerName(string root)
    {
        string script = Path.GetFullPath(Path.Combine(root, "SafeSync.ps1")).ToLowerInvariant();
        using (var sha = SHA256.Create())
            return @"Local\SafeSync.Workers." + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(script))).Replace("-", "").ToLowerInvariant();
    }

    internal static Dictionary<string, string> ReadHashes(string manifest)
    {
        var hashes = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string line in manifest.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.Length < 67 || line.Substring(64, 2) != "  ") throw new InvalidDataException("잘못된 패키지 검증 정보입니다.");
            string name = line.Substring(66);
            if (!PayloadNames.Contains(name) || line.Take(64).Any(c => !Uri.IsHexDigit(c)) || hashes.ContainsKey(name))
                throw new InvalidDataException("허용되지 않은 패키지 파일입니다.");
            hashes.Add(name, line.Substring(0, 64).ToLowerInvariant());
        }
        if (hashes.Count != PayloadNames.Length) throw new InvalidDataException("패키지 구성 파일이 부족합니다.");
        return hashes;
    }
    internal static void Extract(Stream zip, string manifest, string stage)
    {
        Dictionary<string, string> hashes = ReadHashes(manifest);
        Directory.CreateDirectory(stage);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var archive = new ZipArchive(zip, ZipArchiveMode.Read, true))
        {
            long total = 0;
            foreach (var entry in archive.Entries)
            {
                string name = entry.FullName;
                if (!hashes.ContainsKey(name) || !seen.Add(name) || entry.Length > 25000000 || (total += entry.Length) > 50000000)
                    throw new InvalidDataException("패키지 파일명 또는 크기가 잘못되었습니다.");
                string destination = Path.Combine(stage, name);
                using (var input = entry.Open())
                using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    byte[] buffer = new byte[65536]; int count; long copied = 0;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        copied += count;
                        if (copied > entry.Length) throw new InvalidDataException("압축 파일 길이가 잘못되었습니다.");
                        output.Write(buffer, 0, count);
                    }
                    if (copied != entry.Length) throw new InvalidDataException("압축 파일 전송이 중단되었습니다.");
                    output.Flush(true);
                }
                if (Hash(destination) != hashes[name]) throw new InvalidDataException("설치 파일 검증에 실패했습니다: " + name);
            }
        }
        if (seen.Count != PayloadNames.Length) throw new InvalidDataException("설치 파일이 누락되었습니다.");
        File.WriteAllText(Path.Combine(stage, Inventory), manifest, Encoding.UTF8);
    }
    private static void CopyUnknown(string original, string stage)
    {
        foreach (string path in Directory.GetFileSystemEntries(original))
        {
            if (OwnedNames.Contains(Path.GetFileName(path), StringComparer.OrdinalIgnoreCase)) continue;
            CopyVerified(path, Path.Combine(stage, Path.GetFileName(path)));
        }
    }
    private static void CopyVerified(string source, string destination)
    {
        NoLinks(source);
        if (Directory.Exists(source))
        {
            Directory.CreateDirectory(destination);
            foreach (string path in Directory.GetFileSystemEntries(source)) CopyVerified(path, Path.Combine(destination, Path.GetFileName(path)));
        }
        else
        {
            File.Copy(source, destination, false);
            if (Hash(source) != Hash(destination)) throw new IOException("추가 파일 보존 중 검증에 실패했습니다.");
        }
    }
    private static string JournalPath(string root) { return Path.Combine(Path.GetDirectoryName(root), "SafeSync.install-transaction.txt"); }
    private static void SafeDeleteWorkFolder(string folder, string root, string suffix)
    {
        string parent = Path.GetDirectoryName(Canonical(root));
        if (!SamePath(Path.GetDirectoryName(Canonical(folder)), parent) || !Path.GetFileName(folder).StartsWith("SafeSync." + suffix + "-", StringComparison.Ordinal))
            throw new IOException("임시 폴더 경로가 안전하지 않습니다.");
        if (!Directory.Exists(folder)) return;
        // Verify every descendant before a recursive cleanup; never follow junctions or symlinks.
        CheckTree(folder); Directory.Delete(folder, true);
    }
    private static void CheckTree(string folder)
    {
        NoLinks(folder);
        foreach (string child in Directory.GetFileSystemEntries(folder))
        {
            NoLinks(child);
            if (Directory.Exists(child)) CheckTree(child);
        }
    }
    internal static void Recover(string root)
    {
        string journal = JournalPath(root);
        if (!File.Exists(journal)) return;
        NoLinks(journal);
        string[] lines = File.ReadAllLines(journal, Encoding.UTF8);
        if (lines.Length != 5 || lines[0] != ProductId || !SamePath(lines[1], root) || (lines[4] != "pending" && lines[4] != "committed"))
            throw new IOException("기존 설치 복구 기록을 확인할 수 없습니다. 설치를 중단합니다.");
        string stage = lines[2], previous = lines[3], parent = Path.GetDirectoryName(root);
        if (!SamePath(Path.GetDirectoryName(stage), parent) || !SamePath(Path.GetDirectoryName(previous), parent) ||
            !Path.GetFileName(stage).StartsWith("SafeSync.install-", StringComparison.Ordinal) || !Path.GetFileName(previous).StartsWith("SafeSync.previous-", StringComparison.Ordinal))
            throw new IOException("설치 복구 경로가 잘못되었습니다.");
        NoLinks(stage); NoLinks(previous);
        if (lines[4] == "pending")
        {
            if (Directory.Exists(previous))
            {
                if (Directory.Exists(root))
                {
                    if (!IsOwned(root)) throw new IOException("설치 폴더가 변경되어 자동 복구할 수 없습니다.");
                    if (Directory.Exists(stage)) throw new IOException("복구 중인 임시 폴더가 이미 존재합니다.");
                    Directory.Move(root, stage);
                }
                Directory.Move(previous, root);
            }
            else if (!Directory.Exists(stage) && IsOwned(root))
            {
                // New installation was published; no prior version existed to restore.
                Directory.Move(root, stage);
            }
            SafeDeleteWorkFolder(stage, root, "install");
        }
        else SafeDeleteWorkFolder(previous, root, "previous");
        File.Delete(journal);
    }
    internal static void Install(Stream zip, string manifest, string root, bool testMode, Action<string> status, Action afterPublish)
    {
        root = Canonical(root); ValidateRoot(root, testMode); EnsureStopped(root, testMode);
        Directory.CreateDirectory(Path.GetDirectoryName(root)); Recover(root);
        if (Directory.Exists(root) && Directory.GetFileSystemEntries(root).Length != 0 && !IsOwned(root))
            throw new IOException("설치 위치에 다른 파일이 있습니다. 기존 폴더를 확인한 뒤 다시 시도해 주세요.");
        string stage = Path.Combine(Path.GetDirectoryName(root), "SafeSync.install-" + Guid.NewGuid().ToString("N"));
        string previous = Path.Combine(Path.GetDirectoryName(root), "SafeSync.previous-" + Guid.NewGuid().ToString("N"));
        string journal = JournalPath(root);
        bool journalWritten = false;
        try
        {
            status("설치 파일의 내용과 체크섬을 확인하고 있습니다…"); Extract(zip, manifest, stage);
            if (Directory.Exists(root)) CopyUnknown(root, stage);
            // Marker binds the final location, not the staging location.
            File.WriteAllLines(Path.Combine(stage, Marker), new[] { ProductId, root, Version }, Encoding.UTF8);
            EnsureStopped(root, testMode);
            using (var stream = new FileStream(journal, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var writer = new StreamWriter(stream, Encoding.UTF8))
            {
                writer.Write(String.Join(Environment.NewLine, new[] { ProductId, root, stage, previous, "pending" }));
                writer.Flush(); stream.Flush(true);
            }
            journalWritten = true;
            status("SafeSync를 설치하고 있습니다…");
            if (Directory.Exists(root)) Directory.Move(root, previous);
            Directory.Move(stage, root);
            if (afterPublish != null) afterPublish();
            File.WriteAllLines(journal, new[] { ProductId, root, stage, previous, "committed" }, Encoding.UTF8);
        }
        catch
        {
            if (journalWritten) Recover(root);
            else SafeDeleteWorkFolder(stage, root, "install");
            throw;
        }
        // The new app is installed. A locked old file can delay cleanup, not undo a successful installation.
        try { Recover(root); } catch { status("설치는 완료됐습니다. 이전 설치 임시 파일은 다음 설치 때 정리됩니다."); }
    }
    internal static void Remove(string root, bool testMode)
    {
        root = Canonical(root); ValidateRoot(root, testMode); EnsureStopped(root, testMode); Recover(root);
        if (!IsOwned(root)) throw new IOException("SafeSync 설치 표시를 찾을 수 없어 삭제하지 않았습니다.");
        foreach (string name in OwnedNames) NoLinks(Path.Combine(root, name));
        // Delete only our own files. User-added files and all backup/configuration locations stay untouched.
        foreach (string name in OwnedNames.Where(n => n != Marker))
        {
            string path = Path.Combine(root, name);
            if (File.Exists(path)) File.Delete(path);
        }
        if (!testMode) Unregister(root);
        File.Delete(Path.Combine(root, Marker));
        if (Directory.GetFileSystemEntries(root).Length == 0) Directory.Delete(root, false);
    }
    private static string ShortcutFolder { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "SafeSync"); } }
    internal static void Register(string root, bool desktop)
    {
        using (RegistryKey old = Registry.CurrentUser.OpenSubKey(UninstallKey))
            if (old != null && !SamePath(Convert.ToString(old.GetValue("InstallLocation", "")), root))
                throw new IOException("기존 프로그램 등록 위치가 달라 덮어쓸 수 없습니다.");
        using (RegistryKey key = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            key.SetValue("DisplayName", "SafeSync"); key.SetValue("DisplayVersion", Version);
            key.SetValue("InstallLocation", root); key.SetValue("DisplayIcon", Path.Combine(root, "SafeSync.exe"));
            key.SetValue("UninstallString", "\"" + Path.Combine(root, "Uninstall.exe") + "\" /uninstall");
            key.SetValue("NoModify", 1, RegistryValueKind.DWord); key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd")); key.SetValue("EstimatedSize", 512, RegistryValueKind.DWord);
        }
        Directory.CreateDirectory(ShortcutFolder);
        SaveShortcut(Path.Combine(ShortcutFolder, "SafeSync.lnk"), Path.Combine(root, "SafeSync.exe"), root);
        SaveShortcut(Path.Combine(ShortcutFolder, "SafeSync 제거.lnk"), Path.Combine(root, "Uninstall.exe"), root);
        if (desktop) SaveShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SafeSync.lnk"), Path.Combine(root, "SafeSync.exe"), root);
        // Update only an existing SafeSync auto-start entry; the app manages the user's preference.
        using (RegistryKey run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
            if (run != null && run.GetValue("SafeSync") != null) run.SetValue("SafeSync", "\"" + Path.Combine(root, "SafeSync.exe") + "\" -Minimized");
    }
    private static void SaveShortcut(string path, string target, string root)
    {
        object shell = null, link = null;
        try
        {
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            string existing = Convert.ToString(link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null));
            if (File.Exists(path) && !String.IsNullOrEmpty(existing) && !SamePath(existing, target)) throw new IOException("같은 이름의 다른 바로 가기가 있습니다: " + path);
            link.GetType().InvokeMember("TargetPath", BindingFlags.SetProperty, null, link, new object[] { target });
            link.GetType().InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, link, new object[] { root });
            link.GetType().InvokeMember("Description", BindingFlags.SetProperty, null, link, new object[] { "SafeSync 자동 백업" });
            link.GetType().InvokeMember("IconLocation", BindingFlags.SetProperty, null, link, new object[] { target + ",0" });
            link.GetType().InvokeMember("Save", BindingFlags.InvokeMethod, null, link, null);
        }
        finally { if (link != null) Marshal.FinalReleaseComObject(link); if (shell != null) Marshal.FinalReleaseComObject(shell); }
    }
    private static void DeleteShortcut(string path, string root)
    {
        if (!File.Exists(path)) return;
        NoLinks(path);
        object shell = null, link = null;
        try
        {
            shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            link = shell.GetType().InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { path });
            string target = Convert.ToString(link.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, link, null));
            if (SamePath(target, Path.Combine(root, "SafeSync.exe")) || SamePath(target, Path.Combine(root, "Uninstall.exe"))) File.Delete(path);
        }
        finally { if (link != null) Marshal.FinalReleaseComObject(link); if (shell != null) Marshal.FinalReleaseComObject(shell); }
    }
    private static void Unregister(string root)
    {
        using (RegistryKey key = Registry.CurrentUser.OpenSubKey(UninstallKey))
        {
            if (key != null && SamePath(Convert.ToString(key.GetValue("InstallLocation", "")), root)) Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false);
        }
        using (RegistryKey run = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true))
        {
            string command = run == null ? null : run.GetValue("SafeSync") as string;
            if (command != null && (command.IndexOf(Path.Combine(root, "SafeSync.exe"), StringComparison.OrdinalIgnoreCase) >= 0 || command.IndexOf(Path.Combine(root, "SafeSync.ps1"), StringComparison.OrdinalIgnoreCase) >= 0)) run.DeleteValue("SafeSync", false);
        }
        DeleteShortcut(Path.Combine(ShortcutFolder, "SafeSync.lnk"), root);
        DeleteShortcut(Path.Combine(ShortcutFolder, "SafeSync 제거.lnk"), root);
        DeleteShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "SafeSync.lnk"), root);
        if (Directory.Exists(ShortcutFolder) && Directory.GetFileSystemEntries(ShortcutFolder).Length == 0) Directory.Delete(ShortcutFolder, false);
    }
}
