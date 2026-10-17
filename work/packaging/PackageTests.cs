using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal static class PackageTests
{
    private static int assertions;
    private static byte[] package;
    private static string manifest, sandbox;
    private static void Check(bool condition, string message) { assertions++; if (!condition) throw new Exception(message); }
    private static void Throws(Action action, string message)
    {
        assertions++; bool failed = false; try { action(); } catch { failed = true; }
        if (!failed) throw new Exception(message);
    }
    private static void InstallAt(string root, byte[] zip, string hashes, Action callback)
    {
        using (var stream = new MemoryStream(zip)) InstallerCore.Install(stream, hashes, root, true, delegate { }, callback);
    }
    private static string Root(string name) { return Path.Combine(sandbox, name); }
    private static Dictionary<string, byte[]> ReadZip(byte[] bytes)
    {
        var files = new Dictionary<string, byte[]>();
        using (var memory = new MemoryStream(bytes))
        using (var archive = new ZipArchive(memory, ZipArchiveMode.Read))
        foreach (var entry in archive.Entries)
        using (var stream = entry.Open())
        using (var output = new MemoryStream()) { stream.CopyTo(output); files.Add(entry.FullName, output.ToArray()); }
        return files;
    }
    private static byte[] MakeZip(Dictionary<string, byte[]> files)
    {
        using (var memory = new MemoryStream())
        {
            using (var archive = new ZipArchive(memory, ZipArchiveMode.Create, true))
            foreach (var pair in files) using (var stream = archive.CreateEntry(pair.Key).Open()) stream.Write(pair.Value, 0, pair.Value.Length);
            return memory.ToArray();
        }
    }
    private static string MakeHashes(Dictionary<string, byte[]> files)
    {
        using (var sha = System.Security.Cryptography.SHA256.Create())
            return String.Join("\r\n", InstallerCore.PayloadNames.Select(name => BitConverter.ToString(sha.ComputeHash(files[name])).Replace("-", "").ToLowerInvariant() + "  " + name));
    }
    private static void Journal(string root, string stage, string previous, string state)
    {
        File.WriteAllLines(Path.Combine(sandbox, "SafeSync.install-transaction.txt"), new[] { InstallerCore.ProductId, root, stage, previous, state }, Encoding.UTF8);
    }
    private static void Render(bool remove, string file)
    {
        using (var form = new InstallerForm(remove, delegate { }))
        {
            // Render each control independently: an intentionally unshown Form suppresses child
            // painting in DrawToBitmap. This previews layout without opening a desktop window.
            using (var bitmap = new Bitmap(form.ClientSize.Width, form.ClientSize.Height))
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.Clear(Color.White);
                foreach (Control control in form.Controls)
                {
                    if (control is ProgressBar || (remove && control is CheckBox)) continue;
                    IntPtr handle = control.Handle;
                    using (var child = new Bitmap(control.Width, control.Height))
                    {
                        control.DrawToBitmap(child, new Rectangle(Point.Empty, control.Size));
                        graphics.DrawImageUnscaled(child, control.Location);
                    }
                }
                bitmap.Save(file, System.Drawing.Imaging.ImageFormat.Png);
            }
            Check(form.Controls.Count >= 10, "Wizard controls not constructed");
            Check(form.ActionButton.Text == (remove ? "제거" : "설치"), "Wizard language incorrect");
        }
    }
    private static void CheckProcess(string exe, string args, int expected)
    {
        using (var process = Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true }))
        {
            if (!process.WaitForExit(30000)) { process.Kill(); throw new Exception("Check process timeout"); }
            Check(process.ExitCode == expected, "Process verification failed: " + exe);
        }
    }
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            string build = Path.GetFullPath(args[0]);
            sandbox = Path.GetFullPath(args[1]); Directory.CreateDirectory(sandbox);
            File.WriteAllText(Path.Combine(sandbox, ".safesync-test-sandbox"), "SafeSync isolated packaging test");
            package = File.ReadAllBytes(Path.Combine(build, "payload.zip")); manifest = File.ReadAllText(Path.Combine(build, "payload.sha256"));
            Check(InstallerCore.ReadHashes(manifest).Count == InstallerCore.PayloadNames.Length, "Hash manifest missing files");
            string settings = Path.Combine(sandbox, "preserved-settings.json"); File.WriteAllText(settings, "{\"secret\":\"test-only\",\"jobs\":[1]}");
            string backups = Path.Combine(sandbox, "preserved-backup.txt"); File.WriteAllText(backups, "DO NOT TOUCH");
            string settingsHash = InstallerCore.Hash(settings), backupHash = InstallerCore.Hash(backups);
            string root = Root("installed app 한국어");
            InstallAt(root, package, manifest, null);
            Check(InstallerCore.IsOwned(root), "Fresh install missing marker");
            foreach (var pair in InstallerCore.ReadHashes(manifest)) Check(InstallerCore.Hash(Path.Combine(root, pair.Key)) == pair.Value, "Installed file mismatch: " + pair.Key);
            Check(File.Exists(Path.Combine(root, InstallerCore.Inventory)), "Installed inventory missing");
            CheckProcess(Path.Combine(root, "SafeSync.exe"), "/check", 0);
            string extras = Path.Combine(root, "user notes"); Directory.CreateDirectory(extras);
            File.WriteAllText(Path.Combine(extras, "keep.txt"), "USER FILE");
            File.WriteAllText(Path.Combine(root, "custom.ini"), "PERSONAL");
            var updated = ReadZip(package); updated["README-ko.md"] = Encoding.UTF8.GetBytes("Updated README test version");
            byte[] updatedZip = MakeZip(updated); string updatedManifest = MakeHashes(updated);
            InstallAt(root, updatedZip, updatedManifest, null);
            Check(File.ReadAllText(Path.Combine(root, "README-ko.md")) == "Updated README test version", "Upgrade not published");
            Check(File.ReadAllText(Path.Combine(extras, "keep.txt")) == "USER FILE", "Upgrade changed additional nested user file");
            Check(File.ReadAllText(Path.Combine(root, "custom.ini")) == "PERSONAL", "Upgrade changed user file");
            string oldHash = InstallerCore.Hash(Path.Combine(root, "README-ko.md"));
            Throws(delegate { InstallAt(root, package, manifest, delegate { throw new IOException("Injected publication failure"); }); }, "Failed update accepted");
            Check(InstallerCore.Hash(Path.Combine(root, "README-ko.md")) == oldHash, "Failed update did not restore old version");
            Check(File.Exists(Path.Combine(extras, "keep.txt")), "Rollback lost user file");
            string freshFailed = Root("fresh-failed");
            Throws(delegate { InstallAt(freshFailed, package, manifest, delegate { throw new IOException("Injected first-install failure"); }); }, "Failed fresh install accepted");
            Check(!Directory.Exists(freshFailed), "Failed fresh install retained files");
            var corrupted = ReadZip(package); corrupted["SafeSync.ps1"][0] ^= 1;
            Throws(delegate { InstallAt(root, MakeZip(corrupted), manifest, null); }, "Corrupt package accepted");
            Check(InstallerCore.Hash(Path.Combine(root, "README-ko.md")) == oldHash, "Corrupt package modified existing app");
            var missing = ReadZip(package); missing.Remove("SafeSync.Cloud.ps1");
            Throws(delegate { InstallAt(root, MakeZip(missing), manifest, null); }, "Missing module accepted");
            var traversal = ReadZip(package); traversal.Add("../escaped.txt", Encoding.UTF8.GetBytes("malicious"));
            Throws(delegate { InstallAt(root, MakeZip(traversal), manifest, null); }, "ZIP traversal accepted");
            Check(!File.Exists(Root("escaped.txt")), "ZIP escaped staging folder");
            Throws(delegate { InstallerCore.ReadHashes(manifest.Replace("SafeSync.ps1", "..\\bad.ps1")); }, "Unsafe inventory accepted");
            Throws(delegate { InstallerCore.ReadHashes(manifest + "\r\n" + manifest.Split('\n')[0].Trim()); }, "Duplicate inventory accepted");
            using (var busy = new Mutex(true, InstallerCore.MainGuardName(root, true)))
            {
                Throws(delegate { InstallAt(root, package, manifest, null); }, "Running app update allowed");
                Throws(delegate { InstallerCore.Remove(root, true); }, "Running app uninstall allowed");
                busy.ReleaseMutex();
            }
            Check(InstallerCore.Hash(Path.Combine(root, "README-ko.md")) == oldHash, "Busy guard modified app");
            using (var worker = new Mutex(false, InstallerCore.WorkerName(root)))
            {
                Throws(delegate { InstallAt(root, package, manifest, null); }, "Active detached worker update allowed");
                Throws(delegate { InstallerCore.Remove(root, true); }, "Active detached worker removal allowed");
            }
            Check(!InstallerCore.MutexExists(InstallerCore.WorkerName(root)), "Worker guard outlived worker handle");
            string foreign = Root("foreign"); Directory.CreateDirectory(foreign); File.WriteAllText(Path.Combine(foreign, "user.txt"), "OWNED BY USER");
            Throws(delegate { InstallAt(foreign, package, manifest, null); }, "Unmarked folder overwritten");
            Throws(delegate { InstallerCore.Remove(foreign, true); }, "Unmarked folder removed");
            Check(File.ReadAllText(Path.Combine(foreign, "user.txt")) == "OWNED BY USER", "Foreign file changed");
            Throws(delegate { InstallerCore.ValidateRoot(Path.GetPathRoot(sandbox), true); }, "Drive root accepted");
            Throws(delegate { InstallerCore.ValidateRoot(InstallerCore.DataRoot, true); }, "Data folder accepted");
            Throws(delegate { InstallerCore.ValidateRoot(root, false); }, "Nondefault real install root accepted");

            string stage = Root("SafeSync.install-" + Guid.NewGuid().ToString("N"));
            string previous = Root("SafeSync.previous-" + Guid.NewGuid().ToString("N"));
            using (var zip = new MemoryStream(package)) InstallerCore.Extract(zip, manifest, stage);
            File.WriteAllLines(Path.Combine(stage, InstallerCore.Marker), new[] { InstallerCore.ProductId, root, InstallerCore.Version });
            Journal(root, stage, previous, "pending"); Directory.Move(root, previous);
            InstallerCore.Recover(root);
            Check(InstallerCore.Hash(Path.Combine(root, "README-ko.md")) == oldHash, "Prepublication crash did not restore original");
            Check(!Directory.Exists(stage) && !Directory.Exists(previous), "Recovery left temporary folders");
            stage = Root("SafeSync.install-" + Guid.NewGuid().ToString("N")); previous = Root("SafeSync.previous-" + Guid.NewGuid().ToString("N"));
            using (var zip = new MemoryStream(package)) InstallerCore.Extract(zip, manifest, stage);
            File.WriteAllLines(Path.Combine(stage, InstallerCore.Marker), new[] { InstallerCore.ProductId, root, InstallerCore.Version });
            Journal(root, stage, previous, "pending"); Directory.Move(root, previous); Directory.Move(stage, root);
            InstallerCore.Recover(root);
            Check(InstallerCore.Hash(Path.Combine(root, "README-ko.md")) == oldHash, "Postpublication crash did not restore original");
            Check(File.Exists(Path.Combine(extras, "keep.txt")), "Crash recovery lost user extra");
            stage = Root("SafeSync.install-" + Guid.NewGuid().ToString("N")); previous = Root("SafeSync.previous-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(previous); File.WriteAllText(Path.Combine(previous, "old-file"), "OLD");
            Journal(root, stage, previous, "committed"); InstallerCore.Recover(root);
            Check(!Directory.Exists(previous) && InstallerCore.IsOwned(root), "Committed cleanup failed");
            Journal(root, stage, foreign, "pending");
            Throws(delegate { InstallerCore.Recover(root); }, "Unsafe journal accepted");
            Check(File.Exists(Path.Combine(foreign, "user.txt")), "Unsafe journal deleted foreign data");
            File.Delete(Path.Combine(sandbox, "SafeSync.install-transaction.txt"));

            string emptyRemove = Root("remove-empty"); InstallAt(emptyRemove, package, manifest, null);
            InstallerCore.Remove(emptyRemove, true); Check(!Directory.Exists(emptyRemove), "Owned empty folder left after remove");
            InstallerCore.Remove(root, true);
            foreach (string name in InstallerCore.OwnedNames) Check(!File.Exists(Path.Combine(root, name)), "Owned file left after remove: " + name);
            Check(File.ReadAllText(Path.Combine(extras, "keep.txt")) == "USER FILE", "Uninstall removed user nested file");
            Check(File.ReadAllText(Path.Combine(root, "custom.ini")) == "PERSONAL", "Uninstall removed user file");
            Check(InstallerCore.Hash(settings) == settingsHash, "Settings changed"); Check(InstallerCore.Hash(backups) == backupHash, "Backups changed");
            Throws(delegate { InstallerCore.Remove(root, true); }, "Second remove accepted unmarked folder");
            string broken = Root("broken-launcher"); Directory.CreateDirectory(broken);
            File.WriteAllBytes(Path.Combine(broken, "SafeSync.exe"), ReadZip(package)["SafeSync.exe"]);
            CheckProcess(Path.Combine(broken, "SafeSync.exe"), "/check", 1);
            Check(Launcher.Quote("C:\\user space\\한국어\\") == "\"C:\\user space\\한국어\\\\\"", "Launcher trailing slash quoting failed");
            Check(Launcher.Quote("quote\"name") == "\"quote\\\"name\"", "Launcher quote escaping failed");
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            Render(false, Path.Combine(build, "setup-preview.png")); Render(true, Path.Combine(build, "uninstall-preview.png"));
            Console.WriteLine("{\"Assertions\":" + assertions + ",\"Status\":\"OK\",\"RealInstallation\":false,\"RegistryChanges\":0,\"Sandbox\":\"" + sandbox.Replace("\\", "\\\\") + "\"}");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex.ToString()); return 1; }
    }
}
