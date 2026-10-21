using System.Collections.Concurrent;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;
using SafeSync.Core;

if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("A real Windows filesystem is required.");
if (args.Length == 4 && args[0] == "--worker")
{
    await Probe.WorkerAsync(args[1], args[2], args[3]);
    return;
}
if (args.Length != 3) throw new ArgumentException("Usage: probe <local-fixture-root> <test-only-UNC-root> <report-root>");
await Probe.RunAsync(args[0], args[1], args[2]);

internal static class Probe
{
    private const string Marker = "SAFESYNC-RESTART-PROBE-ONLY";
    private const int FileCount = 256;
    public sealed record Fixture(string Source, string Backup, string State, string Mode, string Id);
    public sealed record Entry(long Length, string Hash, string Modified, long Identity);
    public sealed record Check(string Name, bool Passed, string Detail);
    public sealed class RunReport
    {
        public string Scenario { get; set; } = "";
        public string Stage { get; set; } = "";
        public int ProcessId { get; set; }
        public double Milliseconds { get; set; }
        public bool SourceFullScan { get; set; }
        public bool BackupFullScan { get; set; }
        public int ComparedPaths { get; set; }
        public int ContentVerificationPaths { get; set; }
        public int Copied { get; set; }
        public int Skipped { get; set; }
        public int Trashed { get; set; }
        public int Errors { get; set; }
        public int Conflicts { get; set; }
        public int Locked { get; set; }
        public int PendingAfter { get; set; }
        public bool CheckpointActiveAfter { get; set; }
        public bool SourceJournalSaved { get; set; }
        public bool BackupJournalSaved { get; set; }
        public bool SourceRequiresScanBefore { get; set; }
        public bool BackupRequiresScanBefore { get; set; }
        public string FullScanConditionsBefore { get; set; } = "";
        public string[] Compared { get; set; } = [];
        public string[] ProblemPaths { get; set; } = [];
        public string[] ErrorMessages { get; set; } = [];
        public string[] IssueDetails { get; set; } = [];
        public bool ContentsMatchAfter { get; set; }
        public int SourceFilesAfter { get; set; }
        public int BackupFilesAfter { get; set; }
    }

    private static BackupJob Job(Fixture f) => new()
    {
        Id = f.Id, Name = "Isolated restart probe", Source = f.Source, Destination = f.Backup,
        SyncMode = f.Mode, MirrorDeletes = true, TriggerType = "Realtime"
    };

    public static async Task WorkerAsync(string home, string stage, string behavior)
    {
        if (!File.Exists(Path.Combine(home, Marker))) throw new IOException("Refusing a non-test fixture.");
        var f = JsonFile.Read<Fixture>(Path.Combine(home, "fixture.json"));
        var store = new ConfigStore(f.State);
        var job = Job(f);
        var state = store.LoadState(job);
        var left = OfflineJournal.Read(f.Source, state.SourceJournal, default, OfflineJournal.TrackedIds(state.Files));
        var right = OfflineJournal.Read(f.Backup, state.DestinationJournal, default, OfflineJournal.TrackedIds(state.Files, true));
        var report = new RunReport
        {
            Scenario = Path.GetFileName(home), Stage = stage, ProcessId = Environment.ProcessId,
            SourceRequiresScanBefore = left.RequiresScan, BackupRequiresScanBefore = right.RequiresScan,
            FullScanConditionsBefore = $"startupReconcile=true; sourceRequiresScan={left.RequiresScan}; backupRequiresScan={right.RequiresScan}; storedFullScanRequired={state.FullScanRequired}; lastFullScanMissing={!DateTime.TryParse(state.LastFullScanUtc, out _)}"
        };
        var compared = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        var verified = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        var completed = new TaskCompletionSource<BackupResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var clock = Stopwatch.StartNew();
        await using (var scheduler = new BackupScheduler(store))
        {
            scheduler.Progress += p =>
            {
                if (p.Stage == "원본 폴더 비교") report.SourceFullScan = true;
                if (p.Stage == "백업 폴더 비교") report.BackupFullScan = true;
                if (p.Stage is "파일 비교 및 백업" or "양쪽 파일 변경 비교") compared.TryAdd(p.CurrentFile, 0);
                if (p.Stage == "파일 내용 동일 여부 검증") verified.TryAdd(p.CurrentFile, 0);
                // Block AFTER the production five-file durable checkpoint, not by timing a fast copy.
                if (behavior == "kill-at-checkpoint" && p.Stage == "파일 비교 및 백업" && p.Completed == 5)
                {
                    File.WriteAllText(Path.Combine(home, "kill-ready"), "five completed files; production checkpoint saved");
                    Thread.Sleep(Timeout.Infinite);
                }
            };
            scheduler.Completed += (_, r) => completed.TrySetResult(r);
            scheduler.Failed += (_, e) => completed.TrySetException(e);
            scheduler.SetJobs([job]);
            scheduler.Start(); // Same SetJobs/Start/automatic reconciliation path as the desktop app.
            var result = await completed.Task.WaitAsync(TimeSpan.FromSeconds(120));
            report.Copied = result.Copied; report.Skipped = result.Skipped; report.Trashed = result.Trashed;
            report.Errors = result.Errors.Count; report.Conflicts = result.Conflicts.Count; report.Locked = result.Locked.Count;
            report.ProblemPaths = result.Errors.Concat(result.Conflicts).Concat(result.Locked).Select(i => i.File).ToArray();
            report.ErrorMessages = result.Errors.Select(i => i.Reason).ToArray();
            report.IssueDetails = result.Errors.Concat(result.Conflicts).Concat(result.Locked).Select(i => i.File + ": " + i.Reason).ToArray();
            if (result.Canceled) throw new IOException("Unexpected cancellation in test worker.");
        }
        report.Milliseconds = clock.Elapsed.TotalMilliseconds;
        state = new ConfigStore(f.State).LoadState(job);
        report.PendingAfter = state.PendingPaths.Count; report.CheckpointActiveAfter = state.CheckpointActive;
        report.SourceJournalSaved = state.SourceJournal != null; report.BackupJournalSaved = state.DestinationJournal != null;
        report.Compared = compared.Keys.Order(StringComparer.OrdinalIgnoreCase).ToArray();
        report.ComparedPaths = compared.Count; report.ContentVerificationPaths = verified.Count;
        JsonFile.Save(Path.Combine(home, stage + ".json"), report);
        Console.WriteLine($"{report.Scenario}/{stage}: scan={report.SourceFullScan}/{report.BackupFullScan}, compared={report.ComparedPaths}, copied={report.Copied}, conflicts={report.Conflicts}, errors={report.Errors}");
    }

    public static async Task RunAsync(string localRoot, string uncRoot, string reports)
    {
        localRoot = Path.GetFullPath(localRoot); reports = Path.GetFullPath(reports);
        if (!uncRoot.StartsWith(@"\\localhost\SafeSyncProbe_", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Only the isolated runner's SafeSyncProbe_ SMB share is permitted.");
        Directory.CreateDirectory(localRoot); Directory.CreateDirectory(reports);
        var checks = new List<Check>(); var runs = new List<RunReport>();
        void Check(bool ok, string name, string detail = "")
        {
            checks.Add(new(name, ok, detail));
            Console.WriteLine($"{(ok ? "PASS" : "FAIL")}: {name} {detail}");
        }
        var plans = new[]
        {
            ("ntfs-oneway", "OneWay", false, false),
            ("ntfs-twoway", "TwoWay", false, false),
            ("smb-source-oneway", "OneWay", true, false),
            ("smb-backup-oneway", "OneWay", false, true),
            ("smb-backup-twoway", "TwoWay", false, true)
        };
        try
        {
            foreach (var (name, mode, sourceSmb, backupSmb) in plans)
            {
                var home = Path.Combine(reports, name); Directory.CreateDirectory(home);
                File.WriteAllText(Path.Combine(home, Marker), "Synthetic data only; no personal config or credentials.");
                string source = Path.Combine(sourceSmb ? uncRoot : localRoot, name, "source");
                string backup = Path.Combine(backupSmb ? uncRoot : localRoot, name, "backup");
                Directory.CreateDirectory(source); Directory.CreateDirectory(backup);
                var fixture = new Fixture(source, backup, Path.Combine(home, "state"), mode, name);
                JsonFile.Save(Path.Combine(home, "fixture.json"), fixture);
                var job = Job(fixture); new ConfigStore(fixture.State).Save(new AppConfig { Jobs = [job] });
                for (int i = 0; i < FileCount; i++)
                {
                    var relative = $"folder-{i % 8:D2}/한글-{i:D4}.bin";
                    var data = Enumerable.Repeat((byte)(i % 251), 8192).ToArray();
                    Write(source, relative, data);
                }
                Write(source, "large.bin", RandomNumberGenerator.GetBytes(4 * 1024 * 1024));
                var initial = await ChildAsync(home, "initial"); runs.Add(initial);
                Check(initial.Copied == FileCount + 1 && Healthy(initial), name + ": initial synchronization", string.Join(";", initial.ErrorMessages));
                Check(await EqualAsync(source, backup), name + ": initial SHA-256 inventory matches");
                var baseline = await InventoryAsync(backup);
                var beforeState = new ConfigStore(fixture.State).LoadState(job);
                JsonFile.Save(Path.Combine(home, "journal-diagnostic.json"), JournalDiagnostic.Read(source, beforeState.SourceJournal));
                for (int repetition = 1; repetition <= 2; repetition++)
                {
                    var restart = await ChildAsync(home, "unchanged-restart-" + repetition); runs.Add(restart);
                    Check(restart.ProcessId != initial.ProcessId, name + ": actual new worker process " + repetition);
                    Check(Healthy(restart) && restart.Copied == 0 && restart.Trashed == 0, name + ": no unchanged retransfer " + repetition);
                    Check(SameInventory(baseline, await InventoryAsync(backup), true), name + ": unchanged backup contents/IDs/timestamps preserved " + repetition);
                    Check(restart.PendingAfter == 0 && !restart.CheckpointActiveAfter, name + ": completed snapshot preserved " + repetition);
                    if(!sourceSmb && !backupSmb)
                    {
                        Check(restart.SourceJournalSaved && restart.BackupJournalSaved, name + ": real NTFS checkpoints persisted " + repetition);
                        if(repetition==2)Check(!restart.SourceFullScan && !restart.BackupFullScan && restart.ComparedPaths==0, name + ": clean second restart does not rescan/hash unchanged files");
                    }
                }
                // All workers are gone. Changes are deliberately NOT passed to RunAsync as known paths.
                Write(source, "offline/new.bin", [1, 2, 3, 4, 5]);
                Write(source, "folder-00/한글-0000.bin", Enumerable.Repeat((byte)222, 9000).ToArray());
                File.SetLastWriteTimeUtc(Path.Combine(source, "folder-00/한글-0000.bin"), DateTime.UtcNow.AddMinutes(2));
                File.Move(Path.Combine(source, "folder-01/한글-0001.bin"), Path.Combine(source, "folder-01/renamed.bin"));
                File.Delete(Path.Combine(source, "folder-02/한글-0002.bin"));
                var offline = await ChildAsync(home, "offline-source-edits"); runs.Add(offline);
                Check(Healthy(offline) && await EqualAsync(source, backup), name + ": offline add/edit/rename/delete detected without supplied paths", string.Join(";", offline.ErrorMessages));
                Check(offline.ContentsMatchAfter, name + ": offline source changes independently verified by complete SHA-256 inventories");
                Check(new TrashService().List(backup, default).Any(i => i.RelativePath == "folder-02/한글-0002.bin"), name + ": offline deletion preserved in trash");
                if (mode == "TwoWay")
                {
                    Write(backup, "backup-side-new.bin", [9, 8, 7]);
                    File.Delete(Path.Combine(backup, "folder-03/한글-0003.bin"));
                    var reverse = await ChildAsync(home, "offline-backup-edits"); runs.Add(reverse);
                    Check(Healthy(reverse) && await EqualAsync(source, backup), name + ": offline backup changes propagated to source");
                    Check(reverse.ContentsMatchAfter, name + ": offline backup changes independently verified by complete SHA-256 inventories");
                    Check(new TrashService().List(source, default).Any(i => i.RelativePath == "folder-03/한글-0003.bin"), name + ": reverse deletion preserved in source trash");
                }
                var quiet = await ChildAsync(home, "unchanged-after-offline-edits"); runs.Add(quiet);
                Check(Healthy(quiet) && quiet.Copied == 0 && quiet.Trashed == 0, name + ": no repeat transfer after recovered changes");
                // Same size AND restored timestamps: hashing/change tracking must not silently miss the edit.
                const string special = "folder-04/한글-0004.bin";
                var specialPath = Path.Combine(source, special); var modified = File.GetLastWriteTimeUtc(specialPath); var created = File.GetCreationTimeUtc(specialPath);
                var bytes = File.ReadAllBytes(specialPath); bytes[0] ^= 0xff; File.WriteAllBytes(specialPath, bytes);
                File.SetCreationTimeUtc(specialPath, created); File.SetLastWriteTimeUtc(specialPath, modified);
                var metadata = await ChildAsync(home, "same-size-same-timestamps-edit"); runs.Add(metadata);
                bool same = await EqualAsync(source, backup);
                Check(metadata.Errors == 0 && metadata.Locked == 0 && (same || metadata.ProblemPaths.Contains(special)), name + ": metadata-preserving edit copied or explicitly conflicted, never silently skipped");
                if (mode == "OneWay" && !same)
                    Check(metadata.Conflicts > 0 && new ConfigStore(fixture.State).LoadState(job).PendingPaths.Contains(special), name + ": unresolved equal-time content difference retained for user review");
            }
            await CrashAsync(localRoot, reports, runs, Check);
        }
        catch (Exception e)
        {
            Check(false, "Probe infrastructure or unexpected runtime failure", e.ToString());
        }
        finally
        {
            JsonFile.Save(Path.Combine(reports, "summary.json"), new
            {
                Status = checks.All(c => c.Passed) ? "PASS" : "FAIL", Runtime = Environment.Version.ToString(),
                OS = Environment.OSVersion.ToString(), Checks = checks, Runs = runs,
                Scope = "Production Core and BackupScheduler in fresh child processes; synthetic NTFS and loopback SMB; no desktop UI, machine reboot, real NAS or real cloud accounts.",
                Performance = "Full scans and comparison/content-verification stages are observed, not asserted to be optimized. Two-way content hash calls and disk/network byte totals are not instrumented. Full scan decisions are inferred from unchanged production conditions and reported stages."
            });
            WriteSummary(reports, checks, runs);
        }
        if (checks.Any(c => !c.Passed)) throw new Exception("Restart reproduction contains failed correctness checks; see summary.json.");
    }

    private static async Task CrashAsync(string root, string reports, List<RunReport> runs, Action<bool, string, string> check)
    {
        var home = Path.Combine(reports, "crash-checkpoint"); Directory.CreateDirectory(home);
        File.WriteAllText(Path.Combine(home, Marker), "isolated crash fixture");
        var source = Path.Combine(root, "crash-checkpoint", "source"); var backup = Path.Combine(root, "crash-checkpoint", "backup");
        Directory.CreateDirectory(source); Directory.CreateDirectory(backup);
        var fixture = new Fixture(source, backup, Path.Combine(home, "state"), "OneWay", "crash-checkpoint");
        JsonFile.Save(Path.Combine(home, "fixture.json"), fixture);
        new ConfigStore(fixture.State).Save(new AppConfig { Jobs = [Job(fixture)] });
        for (int i = 0; i < 40; i++) Write(source, $"file-{i:D3}.bin", RandomNumberGenerator.GetBytes(32768));
        using (var process = StartChild(home, "interrupted", "kill-at-checkpoint"))
        {
            var clock = Stopwatch.StartNew();
            while (!File.Exists(Path.Combine(home, "kill-ready")) && !process.HasExited && clock.Elapsed < TimeSpan.FromSeconds(90)) await Task.Delay(25);
            if (!File.Exists(Path.Combine(home, "kill-ready")))
            {
                if (!process.HasExited) process.Kill(true);
                await process.WaitForExitAsync(); throw new Exception("Crash worker never reached durable checkpoint.");
            }
            process.Kill(true); await process.WaitForExitAsync();
            check(process.HasExited, "Crash: isolated worker really killed", "");
        }
        var state = new ConfigStore(fixture.State).LoadState(Job(fixture));
        check(state.CheckpointActive && state.PendingPaths.Count > 0 && state.Files.Count >= 5, "Crash: durable progress and remaining queue survived", $"files={state.Files.Count};pending={state.PendingPaths.Count}");
        var partial = await InventoryAsync(backup);
        var recovery = await ChildAsync(home, "restart-after-kill"); runs.Add(recovery);
        check(Healthy(recovery) && await EqualAsync(source, backup), "Crash: fresh scheduler recovered all remaining data", "");
        var final = await InventoryAsync(backup);
        check(partial.All(p => final.TryGetValue(p.Key, out var e) && e == p.Value), "Crash: previously completed files not replaced again", "");
        check(recovery.PendingAfter == 0 && !recovery.CheckpointActiveAfter, "Crash: recovered snapshot finalized", "");
    }

    private static Process StartChild(string home, string stage, string behavior)
    {
        var executable = Environment.ProcessPath ?? throw new IOException("No runtime executable.");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true };
        if (Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase)) start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location);
        foreach (var arg in new[] { "--worker", home, stage, behavior }) start.ArgumentList.Add(arg);
        return Process.Start(start) ?? throw new IOException("Cannot launch isolated worker.");
    }

    private static async Task<RunReport> ChildAsync(string home, string stage)
    {
        using var child = StartChild(home, stage, "normal");
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(150));
        try { await child.WaitForExitAsync(timeout.Token); }
        catch { if (!child.HasExited) child.Kill(true); await child.WaitForExitAsync(); throw; }
        if (child.ExitCode != 0) throw new Exception($"Child {Path.GetFileName(home)}/{stage} failed with {child.ExitCode}.");
        var report = JsonFile.Read<RunReport>(Path.Combine(home, stage + ".json"));
        var fixture = JsonFile.Read<Fixture>(Path.Combine(home, "fixture.json"));
        var source = await InventoryAsync(fixture.Source); var backup = await InventoryAsync(fixture.Backup);
        report.SourceFilesAfter = source.Count; report.BackupFilesAfter = backup.Count;
        report.ContentsMatchAfter = SameInventory(source, backup, false);
        JsonFile.Save(Path.Combine(home, stage + ".inventory.json"), new { Source = source, Backup = backup, report.ContentsMatchAfter });
        JsonFile.Save(Path.Combine(home, stage + ".json"), report);
        return report;
    }

    private static bool Healthy(RunReport r) => r.Errors == 0 && r.Conflicts == 0 && r.Locked == 0;
    private static void Write(string root, string relative, byte[] bytes)
    {
        var path = Path.Combine(root, relative); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, bytes); File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(-10));
    }
    private static async Task<Dictionary<string, Entry>> InventoryAsync(string root)
    {
        var result = new Dictionary<string, Entry>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in FileTree.Scan(root, default))
        {
            var relative = Path.GetRelativePath(root, file.FullName).Replace('\\', '/');
            result[relative] = new(file.Length, await VerifiedFiles.HashAsync(file.FullName, default), file.LastWriteTimeUtc.ToString("O"), OfflineJournal.FileIdentity(file.FullName));
        }
        return result;
    }
    private static bool SameInventory(Dictionary<string, Entry> a, Dictionary<string, Entry> b, bool identity) =>
        a.Count == b.Count && a.All(p => b.TryGetValue(p.Key, out var e) && p.Value.Length == e.Length && p.Value.Hash == e.Hash && (!identity || p.Value == e));
    private static async Task<bool> EqualAsync(string source, string backup) => SameInventory(await InventoryAsync(source), await InventoryAsync(backup), false);

    private static void WriteSummary(string reports, List<Check> checks, List<RunReport> runs)
    {
        var lines = new List<string>
        {
            "# Windows restart reproduction — unchanged production runtime", "",
            $"Correctness checks: {checks.Count(c => c.Passed)} passed / {checks.Count(c => !c.Passed)} failed.", "",
            "A correctness PASS is NOT an incremental-performance PASS. Full comparison without copying is reported separately.", "",
            "| Scenario | Stage | Source full scan | Backup full scan | Compared paths | Explicit hash-stage paths¹ | Copied | Conflicts | Errors | Run ms² |",
            "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|"
        };
        foreach (var r in runs) lines.Add($"| {r.Scenario} | {r.Stage} | {r.SourceFullScan} | {r.BackupFullScan} | {r.ComparedPaths} | {r.ContentVerificationPaths} | {r.Copied} | {r.Conflicts} | {r.Errors} | {r.Milliseconds:F0} |");
        lines.AddRange(["", "¹ Only the one-way production content-verification progress stage is counted; zero does NOT prove no hash reads in two-way mode.", "² Includes the scheduler's initial timer wait; not a disk-throughput benchmark.", "", "## Failed checks"]);
        lines.AddRange(checks.Where(c => !c.Passed).Select(c => $"- {c.Name}: {c.Detail}"));
        lines.AddRange(["", "## Limits", "", "- Fresh actual processes run the production BackupScheduler and Core, not the WPF desktop entry point.", "- Loopback Windows SMB is not the user's actual NAS and does not reproduce Samba firmware or internet latency.", "- No Google Drive/Dropbox login, production data, Windows reboot, GUI interaction or full mid-transfer power loss is tested.", "- Worker crash is at a saved five-file checkpoint, not inside an incomplete file transfer.", "- Performance results are observations; correctness failure remains a workflow failure."]);
        File.WriteAllLines(Path.Combine(reports, "summary.md"), lines);
    }
}
