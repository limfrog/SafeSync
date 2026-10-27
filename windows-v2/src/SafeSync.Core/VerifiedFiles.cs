using System.Globalization;
using System.Security.Cryptography;

namespace SafeSync.Core;

internal static class FileMutationGate
{
    private static readonly SemaphoreSlim Gate=new(1,1);
    public static async Task<IDisposable> EnterAsync(CancellationToken token)
    {
        await Gate.WaitAsync(token);return new Lease();
    }
    public static IDisposable Enter() {Gate.Wait();return new Lease();}
    private sealed class Lease : IDisposable
    {
        private bool disposed;
        public void Dispose(){if(!disposed){disposed=true;Gate.Release();}}
    }
}

public sealed class VerifiedFiles
{
    public sealed class Transaction
    {
        public string Destination { get; set; } = "";
        public string Staged { get; set; } = "";
        public string Previous { get; set; } = "";
        public string ExpectedHash { get; set; } = "";
        public string PreviousHash { get; set; } = "";
        public long Length { get; set; }
    }
    public static async Task<string> HashAsync(string path, CancellationToken token)
    {
        using var timing=OperationLog.Measure("file.sha256",path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, token));
    }
    public static async Task<bool> MatchesAsync(string path, long length, string hash, CancellationToken token)
        => File.Exists(path) && new FileInfo(path).Length == length && await HashAsync(path, token) == hash;

    public async Task<string> CopyAsync(string source, string root, string relative, CancellationToken token,
        IProgress<(long Done, long Total)>? progress = null, string? expectedDestinationHash = null)
    {
        IDisposable lease;
        using(OperationLog.Measure("file.mutation_gate_wait",source))lease=await FileMutationGate.EnterAsync(token);
        using var mutation=lease;
        var destination = PathPolicy.Combine(root, relative);
        var parent = Path.GetDirectoryName(destination)!;
        Directory.CreateDirectory(parent);
        var staged = destination + ".safesync-part-" + Guid.NewGuid().ToString("N");
        var journal = Path.Combine(root, ".safesync-txn-v2-" + Guid.NewGuid().ToString("N") + ".json");
        bool recorded = false;
        try
        {
            using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read,
                1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            var created = File.GetCreationTimeUtc(source);
            var modified = File.GetLastWriteTimeUtc(source);
            var length = input.Length;
            using var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            using (var output = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                var buffer = new byte[1024 * 1024];
                long copied = 0;
                double readMs=0,writeMs=0,digestMs=0;
                int read;
                while (true)
                {
                    var tick=System.Diagnostics.Stopwatch.GetTimestamp();read=await input.ReadAsync(buffer,token);readMs+=System.Diagnostics.Stopwatch.GetElapsedTime(tick).TotalMilliseconds;
                    if(read==0)break;
                    token.ThrowIfCancellationRequested();
                    tick=System.Diagnostics.Stopwatch.GetTimestamp();
                    await output.WriteAsync(buffer.AsMemory(0, read), token);
                    writeMs+=System.Diagnostics.Stopwatch.GetElapsedTime(tick).TotalMilliseconds;tick=System.Diagnostics.Stopwatch.GetTimestamp();
                    digest.AppendData(buffer, 0, read);
                    digestMs+=System.Diagnostics.Stopwatch.GetElapsedTime(tick).TotalMilliseconds;
                    copied += read;
                    progress?.Report((copied, length));
                }
                var flushStarted=System.Diagnostics.Stopwatch.GetTimestamp();output.Flush(true);
                OperationLog.Event("copy.io","local",source,bytes:copied,detail:$"readMs={readMs:F3};writeMs={writeMs:F3};digestMs={digestMs:F3};flushMs={System.Diagnostics.Stopwatch.GetElapsedTime(flushStarted).TotalMilliseconds:F3}");
                if (copied != length || input.Length != length || File.GetLastWriteTimeUtc(source) != modified)
                    throw new IOException("복사 중 원본이 변경되어 기존 백업을 유지했습니다.");
            }
            var hash = Convert.ToHexStringLower(digest.GetHashAndReset());
            if (!await MatchesAsync(staged, length, hash, token)) throw new IOException("임시 사본의 SHA-256 검증에 실패했습니다.");
            File.SetCreationTimeUtc(staged, created);
            File.SetLastWriteTimeUtc(staged, modified);
            // Two-way transfers must not overwrite an edit made after comparison.
            using var destinationGuard=File.Exists(destination)
                ? new FileStream(destination,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete) : null;
            if(expectedDestinationHash!=null && (expectedDestinationHash.Length==0 ? File.Exists(destination) :
                !File.Exists(destination) || await HashAsync(destination,token)!=expectedDestinationHash))
                throw new Cloud.CloudConflictException(relative,"비교 후 대상 파일이 변경되어 교체하지 않았습니다.");
            var destinationId=destinationGuard==null ? 0 : OfflineJournal.FileIdentity(destination);
            var previous = File.Exists(destination) ? TrashService.NewPath(root, relative, "replaced") : "";
            if (previous.Length > 0) Directory.CreateDirectory(Path.GetDirectoryName(previous)!);
            var record = new Transaction
            {
                Destination=Path.GetRelativePath(root, destination), Staged=Path.GetRelativePath(root, staged),
                Previous=previous.Length == 0 ? "" : Path.GetRelativePath(root, previous),
                ExpectedHash=hash, Length=length,
                PreviousHash=previous.Length == 0 ? "" : await HashAsync(destination, token)
            };
            JsonFile.Save(journal, record);
            recorded = true;
            token.ThrowIfCancellationRequested();
            PathPolicy.RejectLinks(root, destination);
            if(destinationId!=0 && OfflineJournal.FileIdentity(destination)!=destinationId)
                throw new Cloud.CloudConflictException(relative,"교체 직전에 대상 파일이 바뀌었습니다.");
            // ReplaceFile is atomic on supported Windows filesystems. Unsupported
            // network filesystems fail closed; never truncate a live backup.
            if (previous.Length == 0) File.Move(staged, destination);
            else File.Replace(staged, destination, previous, ignoreMetadataErrors: false);
            // Do not cancel between publication and verification/rollback.
            if (!await MatchesAsync(destination, length, hash, CancellationToken.None))
            {
                var rejected=TrashService.NewPath(root,relative,"rejected-transfer");
                Directory.CreateDirectory(Path.GetDirectoryName(rejected)!);
                if (previous.Length > 0 && File.Exists(previous))
                    File.Replace(previous, destination, rejected);
                else if(previous.Length==0 && File.Exists(destination))File.Move(destination,rejected);
                throw new IOException("교체 후 검증에 실패하여 기존 백업을 복구했습니다.");
            }
            if(previous.Length>0)ArchiveIntegrity.RecordLocal(root,previous,record.PreviousHash);
            ArchiveIntegrity.RecordLocal(root,destination,hash);
            File.Delete(journal);
            recorded = false;
            return hash;
        }
        finally
        {
            // A journal owns its staged file until recovery resolves it.
            if (!recorded && File.Exists(staged)) File.Delete(staged);
        }
    }

    public async Task RecoverAsync(string root, CancellationToken token)
    {
        using var timing=OperationLog.Measure("prepare.local_transaction_recovery");
        using var mutation=await FileMutationGate.EnterAsync(token);
        foreach (var journal in Directory.EnumerateFiles(root, ".safesync-txn-v2-*.json", SearchOption.TopDirectoryOnly))
        {
            token.ThrowIfCancellationRequested();
            var record = JsonFile.Read<Transaction>(journal);
            var destination = PathPolicy.Combine(root, record.Destination);
            var staged = PathPolicy.Combine(root, record.Staged);
            var previous = record.Previous.Length == 0 ? "" : PathPolicy.Combine(root, record.Previous);
            if (!staged.Contains(".safesync-part-",StringComparison.OrdinalIgnoreCase) ||
                (previous.Length > 0 && !PathPolicy.Inside(Path.Combine(root, ".safesync-trash"), previous)))
                throw new InvalidDataException("잘못된 파일 교체 복구 기록입니다.");
            if (await MatchesAsync(destination, record.Length, record.ExpectedHash, token))
            {
                if(previous.Length>0)ArchiveIntegrity.RecordLocal(root,previous,record.PreviousHash);
                ArchiveIntegrity.RecordLocal(root,destination,record.ExpectedHash);
                if (File.Exists(staged)) File.Delete(staged);
                File.Delete(journal);
                continue;
            }
            if (previous.Length > 0 && File.Exists(previous) && await HashAsync(previous, token) == record.PreviousHash)
            {
                if (File.Exists(destination))
                {
                    var rejected = TrashService.NewPath(root, record.Destination, "recovery-rejected");
                    Directory.CreateDirectory(Path.GetDirectoryName(rejected)!);
                    File.Replace(previous, destination, rejected);
                }
                else File.Move(previous, destination);
            }
            else if (record.PreviousHash.Length > 0 && File.Exists(destination) && await HashAsync(destination, token) == record.PreviousHash)
            {
                // Crash/cancellation before ReplaceFile: original is intact.
            }
            else if (record.PreviousHash.Length == 0 && !File.Exists(destination)) { }
            else throw new IOException("중단된 교체 파일을 자동으로 판정할 수 없습니다. 원본과 백업을 보존하고 중단합니다: " + destination);
            if (File.Exists(staged)) File.Delete(staged);
            File.Delete(journal);
        }
    }
}

public sealed class TrashService
{
    public static string NewPath(string root, string relative, string reason)
    {
        var folder = RecoveryBatch.Folder(reason);
        return PathPolicy.Combine(root, ".safesync-trash/" + folder + "/" + PathPolicy.Relative(relative));
    }
    public static string Move(string root, string relative, string reason)
    {
        using var mutation=FileMutationGate.Enter();
        var source = PathPolicy.Combine(root, relative);
        var target = NewPath(root, relative, reason);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        using(var guard=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read|FileShare.Delete))
        {
        var hash=Convert.ToHexStringLower(SHA256.HashData(guard));
        File.Move(source, target);
        ArchiveIntegrity.RecordLocal(root,target,hash);
        }
        return target;
    }
    public IEnumerable<TrashItem> List(string root, CancellationToken token,Action? boundary=null)
    {
        var trashRoot = Path.Combine(root, ".safesync-trash");
        if (!Directory.Exists(trashRoot)) yield break;
        PathPolicy.RejectLinks(root, trashRoot);
        foreach (var batch in new DirectoryInfo(trashRoot).EnumerateDirectories())
        {
            boundary?.Invoke();
            token.ThrowIfCancellationRequested();
            if ((batch.Attributes & FileAttributes.ReparsePoint) != 0) continue;
            var deleted = TrashDates.TryParse(batch.Name,out var date) ? date : batch.CreationTime;
            foreach (var file in FileTree.Scan(batch.FullName, token,_=>boundary?.Invoke()))
            {
                boundary?.Invoke();
                var relative = PathPolicy.Relative(Path.GetRelativePath(batch.FullName, file.FullName));
                yield return new(file.FullName,file.Name,deleted,PathPolicy.Combine(root,relative),relative,file.Length);
            }
        }
    }
    public async Task RestoreAsync(string root, TrashItem item, CancellationToken token)
    {
        ValidateItem(root, item);
        using(var guard=new FileStream(item.StoragePath,FileMode.Open,FileAccess.Read,FileShare.Read))
        {
        await ArchiveIntegrity.VerifyLocalAsync(root,item,token);
        var expected=File.Exists(item.OriginalPath) ? await VerifiedFiles.HashAsync(item.OriginalPath,token) : "";
        await new VerifiedFiles().CopyAsync(item.StoragePath, root, item.RelativePath, token,expectedDestinationHash:expected);
        }
        File.Delete(item.StoragePath);
        ArchiveIntegrity.ForgetLocal(root,item.StoragePath);
    }
    public void Delete(string root, TrashItem item)
    {
        using var mutation=FileMutationGate.Enter();
        ValidateItem(root, item);
        File.Delete(item.StoragePath);
        ArchiveIntegrity.ForgetLocal(root,item.StoragePath);
    }
    public int RemoveExpired(string root, int days, CancellationToken token,Action? boundary=null)
    {
        if (days is < 1 or > 3650) throw new ArgumentOutOfRangeException(nameof(days));
        int count = 0;
        foreach (var item in List(root, token,boundary))
        {
            token.ThrowIfCancellationRequested();
            if (item.DeletedAt < DateTime.Now.AddDays(-days)) { Delete(root, item); count++; }
        }
        // Empty directory tombstones are kept for the same retention period.
        // Remove only directories proven empty; never recursively delete data.
        var trashRoot=Path.Combine(root,".safesync-trash");
        if(Directory.Exists(trashRoot))
        foreach(var batch in new DirectoryInfo(trashRoot).EnumerateDirectories())
        {
            boundary?.Invoke();
            token.ThrowIfCancellationRequested();
            if((batch.Attributes&FileAttributes.ReparsePoint)!=0 || !TrashDates.TryParse(batch.Name,out var deleted) || deleted>=DateTime.Now.AddDays(-days))continue;
            foreach(var folder in FileTree.Entries(batch.FullName,token,_=>boundary?.Invoke()).OfType<DirectoryInfo>().OrderByDescending(f=>f.FullName.Length))
                if(!folder.EnumerateFileSystemInfos().Any())Directory.Delete(folder.FullName);
            if(!batch.EnumerateFileSystemInfos().Any())Directory.Delete(batch.FullName);
        }
        return count;
    }
    private static void ValidateItem(string root, TrashItem item)
    {
        if (!PathPolicy.Inside(Path.Combine(root,".safesync-trash"), item.StoragePath)) throw new InvalidDataException("휴지통 밖의 파일입니다.");
        PathPolicy.RejectLinks(root,item.StoragePath);
        if (!string.Equals(PathPolicy.Combine(root,item.RelativePath),item.OriginalPath,StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("복구 경로가 일치하지 않습니다.");
    }
}

public static class FileTree
{
    public static IEnumerable<FileSystemInfo> Entries(string root,CancellationToken token,Action<string>? progress=null)
    {
        PathPolicy.RejectLinks(root,root);var folders=new Stack<DirectoryInfo>();folders.Push(new(root));
        while(folders.TryPop(out var folder))
        {
            token.ThrowIfCancellationRequested();progress?.Invoke(folder.FullName);
            foreach(var entry in folder.EnumerateFileSystemInfos())
            {
                token.ThrowIfCancellationRequested();
                if((entry.Attributes&FileAttributes.ReparsePoint)!=0 || PathPolicy.Internal(entry.Name))continue;
                yield return entry;if(entry is DirectoryInfo child)folders.Push(child);
            }
        }
    }
    public static IEnumerable<FileInfo> Scan(string root, CancellationToken token, Action<string>? progress = null)
    {
        using var timing=OperationLog.Measure("prepare.source_scan");
        PathPolicy.RejectLinks(root, root);
        var stack = new Stack<DirectoryInfo>();
        stack.Push(new DirectoryInfo(root));
        while (stack.Count > 0)
        {
            token.ThrowIfCancellationRequested();
            var folder = stack.Pop();
            progress?.Invoke(folder.FullName);
            foreach (var file in folder.EnumerateFiles())
            {
                token.ThrowIfCancellationRequested();
                if ((file.Attributes & FileAttributes.ReparsePoint) == 0 && !PathPolicy.Internal(file.Name)) yield return file;
            }
            foreach (var child in folder.EnumerateDirectories())
                if ((child.Attributes & FileAttributes.ReparsePoint) == 0 && !PathPolicy.Internal(child.Name)) stack.Push(child);
        }
    }
}
