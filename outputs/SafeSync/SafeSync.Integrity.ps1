# Shared verified-copy and transaction helpers. ASCII for Windows PowerShell 5.1.
if (-not ('SafeSyncFileIntegrity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Diagnostics;

public sealed class SafeSyncSnapshot
{
    public string Path;
    public long Length;
    public string Sha256;
    public DateTime CreationTimeUtc;
    public DateTime LastWriteTimeUtc;
}

public static class SafeSyncFileIntegrity
{
    private static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }

    public static string Hash(string path, string algorithm)
    {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (HashAlgorithm hash = HashAlgorithm.Create(algorithm))
        {
            if (hash == null) throw new IOException("Unsupported checksum algorithm.");
            return Hex(hash.ComputeHash(stream));
        }
    }

    public static string DropboxHash(string path)
    {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (SHA256 blocks = SHA256.Create())
        using (SHA256 total = SHA256.Create())
        {
            byte[] buffer = new byte[4 * 1024 * 1024];
            while (true)
            {
                int count = 0;
                int read;
                while (count < buffer.Length && (read = stream.Read(buffer, count, buffer.Length - count)) > 0) count += read;
                if (count == 0) break;
                byte[] digest = blocks.ComputeHash(buffer, 0, count);
                total.TransformBlock(digest, 0, digest.Length, digest, 0);
            }
            total.TransformFinalBlock(new byte[0], 0, 0);
            return Hex(total.Hash);
        }
    }

    public static SafeSyncSnapshot CopyVerified(string source, string target)
    {
        SafeSyncSnapshot snapshot = new SafeSyncSnapshot();
        using (FileStream input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
        using (SHA256 sha = SHA256.Create())
        {
            snapshot.Length = input.Length;
            snapshot.CreationTimeUtc = File.GetCreationTimeUtc(source);
            snapshot.LastWriteTimeUtc = File.GetLastWriteTimeUtc(source);
            using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                byte[] buffer = new byte[1024 * 1024];
                int read;
                long copied = 0;
                while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    output.Write(buffer, 0, read);
                    sha.TransformBlock(buffer, 0, read, buffer, 0);
                    copied += read;
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                output.Flush(true);
                if (copied != snapshot.Length || input.Length != snapshot.Length || File.GetLastWriteTimeUtc(source) != snapshot.LastWriteTimeUtc)
                    throw new IOException("Source changed while copying. The previous backup was preserved.");
            }
            snapshot.Sha256 = Hex(sha.Hash);
            Assert(target, snapshot.Length, snapshot.Sha256);
        }
        File.SetCreationTimeUtc(target, snapshot.CreationTimeUtc);
        File.SetLastWriteTimeUtc(target, snapshot.LastWriteTimeUtc);
        snapshot.Path = target;
        return snapshot;
    }

    public static void Assert(string path, long length, string expectedHash)
    {
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
        using (SHA256 sha = SHA256.Create())
        {
            if (stream.Length != length || !String.Equals(Hex(sha.ComputeHash(stream)), expectedHash, StringComparison.OrdinalIgnoreCase))
                throw new IOException("Backup verification failed: file size or SHA-256 differs. The file was not accepted as a backup.");
        }
    }

    public static void Publish(string staged, string destination, string previous, long length, string hash)
    {
        Assert(staged, length, hash);
        // ReplaceFile on Windows needs its own write-capable handle. All verification
        // handles are closed before this atomic operation and content is checked again after it.
        if (String.IsNullOrEmpty(previous)) File.Move(staged, destination);
        else File.Replace(staged, destination, previous, false);
        try { Assert(destination, length, hash); }
        catch
        {
            // Retain the rejected copy as well as restoring the previous version.
            if (String.IsNullOrEmpty(previous)) File.Move(destination, staged);
            else File.Replace(previous, destination, previous + ".failed-transfer", false);
            throw;
        }
    }
}

// Bounded background staging uploads. Only the main backup thread publishes
// verified IDs or updates the snapshot, so concurrent uploads cannot overwrite
// another file's state or interfere with transaction recovery.
public sealed class SafeSyncGoogleTransfer : IDisposable
{
    public SafeSyncSnapshot Snapshot;
    public string Json;
    public Exception Error;
    public volatile string Stage = "Preparing";
    public volatile bool Completed;
    public double PreparationSeconds;
    public double UploadSeconds;
    private long bytesSent;
    private volatile bool cancelled;
    private HttpWebRequest request;
    private readonly object gate = new object();
    private Task task;
    public long BytesSent { get { return Interlocked.Read(ref bytesSent); } }

    public static SafeSyncGoogleTransfer Begin(string source, string staged, long length, DateTime modified,
                                              string metadata, string token, string endpoint)
    {
        var transfer = new SafeSyncGoogleTransfer();
        transfer.task = Task.Factory.StartNew(delegate {
            try {
                var timer = Stopwatch.StartNew();
                transfer.Snapshot = SafeSyncFileIntegrity.CopyVerified(source, staged);
                if (transfer.Snapshot.Length != length || transfer.Snapshot.LastWriteTimeUtc != modified)
                    throw new IOException("Source changed after scanning. Retry this file on the next backup.");
                transfer.PreparationSeconds = timer.Elapsed.TotalSeconds;
                if (transfer.cancelled) throw new OperationCanceledException();
                transfer.Stage = "Uploading";
                timer.Restart();
                transfer.Json = transfer.Upload(staged, metadata, token, endpoint);
                transfer.UploadSeconds = timer.Elapsed.TotalSeconds;
                transfer.Stage = "Completed";
            }
            catch (Exception error) { transfer.Error = error; transfer.Stage = "Failed"; }
            finally {
                if (transfer.cancelled || transfer.Error != null) {
                    try { if (File.Exists(staged)) File.Delete(staged); } catch { }
                }
                transfer.Completed = true;
            }
        });
        return transfer;
    }

    public static string UploadFile(string path, string metadata, string token, string endpoint)
    {
        using (var transfer = new SafeSyncGoogleTransfer()) { return transfer.Upload(path, metadata, token, endpoint); }
    }

    public static SafeSyncGoogleSession QuerySession(string url, long length)
    {
        var web = (HttpWebRequest)WebRequest.Create(url);
        web.Method = "PUT";
        web.ContentLength = 0;
        web.Headers["Content-Range"] = "bytes */" + length;
        web.AllowAutoRedirect = false;
        web.Timeout = 30000;
        try {
            using (var response = (HttpWebResponse)web.GetResponse()) {
                var state = new SafeSyncGoogleSession();
                if ((int)response.StatusCode == 308) {
                    string range = response.Headers["Range"];
                    if (!String.IsNullOrEmpty(range)) {
                        int dash = range.LastIndexOf('-'); long last;
                        if (dash < 0 || !Int64.TryParse(range.Substring(dash + 1), out last) || last < 0 || last >= length)
                            throw new IOException("Google Drive returned an invalid upload offset.");
                        state.Offset = last + 1;
                    }
                } else if ((int)response.StatusCode >= 200 && (int)response.StatusCode < 300) {
                    state.Complete = true;
                    using (var reader = new System.IO.StreamReader(response.GetResponseStream(), Encoding.UTF8)) state.Json = reader.ReadToEnd();
                } else throw new IOException("Google Drive returned an unexpected upload status.");
                return state;
            }
        } catch (WebException error) {
            var response = error.Response as HttpWebResponse;
            if (response != null) {
                int status = (int)response.StatusCode;
                response.Dispose();
                if (status == 404 || status == 410) return new SafeSyncGoogleSession { Expired = true };
            }
            throw;
        }
    }

    public static string ResumeFile(string path, string url, long offset)
    {
        using (var transfer = new SafeSyncGoogleTransfer()) { return transfer.Resume(path, url, offset); }
    }

    public static SafeSyncGoogleTransfer BeginResume(string path, string url, long offset)
    {
        var transfer = new SafeSyncGoogleTransfer();
        transfer.Stage = "Uploading";
        transfer.task = Task.Factory.StartNew(delegate {
            try {
                var timer = Stopwatch.StartNew();
                transfer.Json = transfer.Resume(path, url, offset);
                transfer.UploadSeconds = timer.Elapsed.TotalSeconds;
                transfer.Stage = "Completed";
            } catch (Exception error) { transfer.Error = error; transfer.Stage = "Failed"; }
            finally { transfer.Completed = true; }
        });
        return transfer;
    }

    private string Resume(string path, string url, long offset)
    {
        using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            if (offset < 0 || offset >= input.Length) throw new IOException("Invalid Google Drive resume offset.");
            var web = (HttpWebRequest)WebRequest.Create(url);
            web.Method = "PUT";
            web.AllowAutoRedirect = false;
            web.AllowWriteStreamBuffering = false;
            web.ContentType = "application/octet-stream";
            web.ContentLength = input.Length - offset;
            web.Headers["Content-Range"] = "bytes " + offset + "-" + (input.Length - 1) + "/" + input.Length;
            web.Timeout = 600000;
            web.ReadWriteTimeout = 120000;
            web.ServicePoint.Expect100Continue = false;
            lock (gate) {
                if (cancelled) throw new OperationCanceledException();
                request = web;
            }
            input.Seek(offset, SeekOrigin.Begin);
            Interlocked.Exchange(ref bytesSent, offset);
            try {
                using (var output = web.GetRequestStream()) {
                    var buffer = new byte[65536]; int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                        if (cancelled) throw new OperationCanceledException();
                        output.Write(buffer, 0, count);
                        Interlocked.Add(ref bytesSent, count);
                    }
                }
                using (var response = (HttpWebResponse)web.GetResponse())
                using (var reader = new System.IO.StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
                    if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300)
                        throw new IOException("Google Drive upload did not finish. The session was retained for retry.");
                    return reader.ReadToEnd();
                }
            }
            finally { lock (gate) { request = null; } }
        }
    }

    private string Upload(string path, string metadata, string token, string endpoint)
    {
        var boundary = "safesync_" + Guid.NewGuid().ToString("N");
        byte[] prefix = Encoding.UTF8.GetBytes("--" + boundary + "\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n" + metadata +
            "\r\n--" + boundary + "\r\nContent-Type: application/octet-stream\r\n\r\n");
        byte[] suffix = Encoding.ASCII.GetBytes("\r\n--" + boundary + "--\r\n");
        var web = (HttpWebRequest)WebRequest.Create(endpoint);
        web.Method = "POST";
        web.Headers[HttpRequestHeader.Authorization] = "Bearer " + token;
        web.ContentType = "multipart/related; boundary=" + boundary;
        web.AllowWriteStreamBuffering = false;
        web.AllowAutoRedirect = false;
        web.Timeout = 120000;
        web.ReadWriteTimeout = 120000;
        web.ServicePoint.ConnectionLimit = Math.Max(4, web.ServicePoint.ConnectionLimit);
        web.ServicePoint.Expect100Continue = false;
        lock (gate) {
            if (cancelled) throw new OperationCanceledException();
            request = web;
        }
        try {
            using (var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                web.ContentLength = prefix.LongLength + input.Length + suffix.LongLength;
                using (var output = web.GetRequestStream()) {
                    output.Write(prefix, 0, prefix.Length);
                    byte[] buffer = new byte[65536];
                    int count;
                    while ((count = input.Read(buffer, 0, buffer.Length)) > 0) {
                        if (cancelled) throw new OperationCanceledException();
                        output.Write(buffer, 0, count);
                        Interlocked.Add(ref bytesSent, count);
                    }
                    output.Write(suffix, 0, suffix.Length);
                }
            }
            using (var response = (HttpWebResponse)web.GetResponse())
            using (var reader = new System.IO.StreamReader(response.GetResponseStream(), Encoding.UTF8)) {
                if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300)
                    throw new IOException("Google Drive upload returned HTTP " + (int)response.StatusCode + ".");
                return reader.ReadToEnd();
            }
        }
        finally { lock (gate) { request = null; } }
    }

    public void Dispose()
    {
        lock (gate) {
            cancelled = true;
            if (request != null) request.Abort();
        }
        if (task != null) { try { task.Wait(3000); } catch { } }
        if (Completed && Snapshot != null) { try { File.Delete(Snapshot.Path); } catch { } }
    }
}

public sealed class SafeSyncGoogleSession
{
    public bool Complete;
    public bool Expired;
    public long Offset;
    public string Json;
}

public static class SafeSyncFastScanner
{
    private static bool IsInternalName(string name, bool directory)
    {
        if (directory)
            return name.Equals(".safesync-trash", StringComparison.OrdinalIgnoreCase) ||
                   name.Equals(".safesync-staging", StringComparison.OrdinalIgnoreCase);
        return name.IndexOf(".safesync-part-", StringComparison.OrdinalIgnoreCase) >= 0 ||
               name.IndexOf(".safesync-txn-", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    public static FileInfo[] EnumerateFiles(string root, Action<string> progress)
    {
        var files = new List<FileInfo>();
        var folders = new Stack<DirectoryInfo>();
        folders.Push(new DirectoryInfo(Path.GetFullPath(root)));
        while (folders.Count > 0)
        {
            DirectoryInfo folder = folders.Pop();
            if (progress != null) progress(folder.FullName);
            foreach (FileInfo file in folder.GetFiles())
                if (!IsInternalName(file.Name, false)) files.Add(file);
            foreach (DirectoryInfo child in folder.GetDirectories())
            {
                if (IsInternalName(child.Name, true)) continue;
                if ((child.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                folders.Push(child);
            }
        }
        return files.ToArray();
    }
}
'@
}

function Test-SafeSyncInternalPath([string]$Path) {
    return $Path -match '(^|[\\/])\.safesync-(trash|staging)([\\/]|$)|\.safesync-(part|txn)-'
}

function Test-SafeSyncFileInUseError([object]$ErrorValue) {
    $allMessages = New-Object System.Collections.Generic.List[string]
    if ($null -ne $ErrorValue) { $allMessages.Add([string]$ErrorValue) }
    $exception = if ($ErrorValue -is [System.Management.Automation.ErrorRecord]) { $ErrorValue.Exception } elseif ($ErrorValue -is [System.Exception]) { $ErrorValue } else { $null }
    while ($null -ne $exception) {
        if ($exception -is [System.IO.IOException]) {
            $nativeCode = $exception.HResult -band 0xFFFF
            if ($nativeCode -eq 32 -or $nativeCode -eq 33) { return $true }
        }
        $message = [string]$exception.Message
        if (-not [string]::IsNullOrWhiteSpace($message)) { $allMessages.Add($message) }
        $exception = $exception.InnerException
    }
    $combinedMessage = ($allMessages -join "`n")
    # Do not treat access-denied errors as locks: permission failures must remain visible.
    # These phrases cover .NET, PowerShell, Win32, and localized sharing-violation messages.
    if ($combinedMessage -match '(?i)being used by another process|used by another process|file is being used|cannot access .* because it is being used|sharing violation|lock violation|다른 프로세스(에서|가) 사용|사용 중이므로|공유 위반|잠금 위반') {
        return $true
    }
    return $false
}

function Add-SafeSyncLockedFile([System.Collections.IDictionary]$Result, [string]$RelativePath, [object]$ErrorValue) {
    $message = if ($ErrorValue -is [System.Management.Automation.ErrorRecord]) { [string]$ErrorValue.Exception.Message } elseif ($ErrorValue -is [System.Exception]) { [string]$ErrorValue.Message } else { [string]$ErrorValue }
    $Result.LockedFiles += [pscustomobject]@{
        File = $RelativePath
        Reason = 'File is in use; waiting for automatic retry.'
        Detail = $message
        LastAttemptUtc = [datetime]::UtcNow.ToString('o')
    }
}

function Assert-SafeSyncPathWithin([string]$Root, [string]$Path) {
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Recovery path is outside the configured backup folder.'
    }
}

function New-SafeSyncSnapshot([System.IO.FileInfo]$File, [string]$StagedPath) {
    if ([string]::IsNullOrWhiteSpace($StagedPath)) {
        $folder = Join-Path $script:DataRoot 'staging'
        [void][System.IO.Directory]::CreateDirectory($folder)
        $StagedPath = Join-Path $folder ("$([guid]::NewGuid().ToString('N')).safesync-part")
    }
    try {
        $snapshot = [SafeSyncFileIntegrity]::CopyVerified($File.FullName, $StagedPath)
        if ($snapshot.Length -ne $File.Length -or $snapshot.LastWriteTimeUtc -ne $File.LastWriteTimeUtc) {
            throw 'Source changed after scanning. Retry this file on the next backup.'
        }
        return $snapshot
    }
    catch {
        if (Test-Path -LiteralPath $StagedPath -PathType Leaf) { Remove-Item -LiteralPath $StagedPath -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Write-SafeSyncTransaction([string]$Path, [object]$Record) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 8 -Compress))
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-SafeSyncCloudTransactionPath {
    return Join-Path (Join-Path $script:DataRoot 'transactions') ("$([guid]::NewGuid().ToString('N')).json")
}

function Restore-SafeSyncLocalTransaction([string]$Root, [object]$Record) {
    foreach ($path in @($Record.Destination, $Record.Staged)) { Assert-SafeSyncPathWithin $Root ([string]$path) }
    if ($Record.Previous) { Assert-SafeSyncPathWithin (Join-Path $Root '.safesync-trash') ([string]$Record.Previous) }
    $destination = [string]$Record.Destination
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $hash = [SafeSyncFileIntegrity]::Hash($destination, 'SHA256')
        if ($hash -eq [string]$Record.Sha256) { return $true }
        if ($Record.PreviousSha256 -and $hash -eq [string]$Record.PreviousSha256) { return $false }
        # Never erase an unknown file, including a concurrently edited backup.
        throw "Recovery needs review; an unexpected file exists at $destination. The previous copy remains in SafeSync trash."
    }
    if ($Record.Previous -and (Test-Path -LiteralPath $Record.Previous -PathType Leaf)) {
        [SafeSyncFileIntegrity]::Assert([string]$Record.Previous, [long]$Record.PreviousLength, [string]$Record.PreviousSha256)
        [System.IO.File]::Move([string]$Record.Previous, $destination)
        return $false
    }
    if (-not $Record.Previous) { return $false }
    throw "Previous backup is not accessible. Recovery will retry: $destination"
}

function Repair-SafeSyncLocalTransactions([string]$Root) {
    foreach ($journal in @(Get-ChildItem -LiteralPath $Root -Filter '*.safesync-txn-*.json' -File -Recurse -Force -ErrorAction Stop)) {
        if ($journal.FullName -match '(^|\\)\.safesync-trash\\') { continue }
        $record = Get-Content -LiteralPath $journal.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        [void](Restore-SafeSyncLocalTransaction $Root $record)
        if (Test-Path -LiteralPath $record.Staged -PathType Leaf) { Remove-Item -LiteralPath $record.Staged -Force }
        Remove-Item -LiteralPath $journal.FullName -Force
    }
}

function Publish-SafeSyncLocalSnapshot([object]$Snapshot, [string]$Destination, [string]$Root, [string]$Relative) {
    Assert-SafeSyncPathWithin $Root $Destination
    Assert-SafeSyncPathWithin $Root ([string]$Snapshot.Path)
    $previous = ''
    $previousHash = ''
    [long]$previousLength = 0
    $previousLock = $null
    $journal = "$Destination.safesync-txn-$([guid]::NewGuid().ToString('N')).json"
    try {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            # File.Replace must be able to rename this handle; deny Write but allow Delete.
            $previousLock = [System.IO.File]::Open($Destination, 'Open', 'Read', ([System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete))
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { $previousHash = [BitConverter]::ToString($sha.ComputeHash($previousLock)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
            $previousLength = $previousLock.Length
            $bundle = Join-Path (Join-Path $Root '.safesync-trash') ((Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-replaced-' + [guid]::NewGuid().ToString('N'))
            $previous = Join-Path $bundle $Relative
            Assert-SafeSyncPathWithin $bundle $previous
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($previous))
        }
        $record = [pscustomobject]@{ Destination=$Destination; Staged=[string]$Snapshot.Path; Previous=$previous; PreviousSha256=$previousHash; PreviousLength=$previousLength; Sha256=[string]$Snapshot.Sha256; Length=[long]$Snapshot.Length }
        Write-SafeSyncTransaction $journal $record
        if ($null -ne $previousLock) { $previousLock.Dispose(); $previousLock = $null }
        [SafeSyncFileIntegrity]::Publish([string]$Snapshot.Path, $Destination, $previous, [long]$Snapshot.Length, [string]$Snapshot.Sha256)
        Remove-Item -LiteralPath $journal -Force
    }
    catch {
        $failure = $_
        if ($null -ne $previousLock) { $previousLock.Dispose(); $previousLock = $null }
        if (Test-Path -LiteralPath $journal -PathType Leaf) {
            try {
                [void](Restore-SafeSyncLocalTransaction $Root $record)
                Remove-Item -LiteralPath $journal -Force
            } catch { throw "$($failure.Exception.Message) Recovery pending: $($_.Exception.Message)" }
        }
        throw $failure
    }
    finally {
        if ($null -ne $previousLock) { $previousLock.Dispose() }
        # On a failed/unreachable recovery keep both the journal and staged data.
        if (-not (Test-Path -LiteralPath $journal) -and (Test-Path -LiteralPath $Snapshot.Path -PathType Leaf)) {
            Remove-Item -LiteralPath $Snapshot.Path -Force -ErrorAction SilentlyContinue
        }
    }
}
