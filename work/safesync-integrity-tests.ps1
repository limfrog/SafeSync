$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
$script:TestRoot = Join-Path (Resolve-Path '.\work').Path ('integrity-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($script:TestRoot)
$script:DataRoot = Join-Path $script:TestRoot 'data'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:ManifestRoot = Join-Path $script:DataRoot 'manifests'
$script:ResultRoot = Join-Path $script:DataRoot 'results'
$script:ProgressRoot = Join-Path $script:DataRoot 'progress'
$script:LastProgressWrite = @{}
. '.\outputs\SafeSync\SafeSync.Cloud.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
$localFunctions = @('Write-SafeSyncProgress','Initialize-DataFolders','Write-AppLog','Get-NormalizedPath','Test-PathRelationship','Get-RelativePath','Get-SafeSyncFilesWithProgress','Move-ToSafeTrash','Remove-ExpiredTrash','Copy-FileToSafeTrash','Get-LocalManifestPath','Get-LocalBackupManifest','Save-LocalBackupManifest','Get-SafeSyncStatePath','New-SafeSyncState','Get-SafeSyncState','Save-SafeSyncState','ConvertTo-SafeSyncRelativePath','Set-SafeSyncStateEntry','Remove-SafeSyncStateEntry','Get-SafeSyncBackupPlan','Copy-FileSafely','Invoke-LocalBackupJob')
foreach ($node in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $localFunctions) { Invoke-Expression $node.Extent.Text }
}

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Assert-Fails([scriptblock]$Action, [string]$Message) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    Assert-Test $failed $Message
}
# Process locks are deferred and never treated as ordinary backup errors.
Assert-Test (Test-SafeSyncFileInUseError ([System.IO.IOException]::new('The process cannot access the file because it is being used by another process.'))) 'English process-use error was not classified as locked.'
Assert-Test (Test-SafeSyncFileInUseError '다른 프로세스에서 사용 중이므로 파일을 열 수 없습니다.') 'Localized process-use error was not classified as locked.'
Assert-Test (-not (Test-SafeSyncFileInUseError 'Access to the path is denied.')) 'Permission error was incorrectly hidden as a locked file.'

function New-Fixture([string]$Path, [string]$Text) {
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Path))
    [System.IO.File]::WriteAllText($Path, $Text)
    return Get-Item -LiteralPath $Path
}

# Local verified publication and preservation of the old byte content.
$localRoot = Join-Path $script:TestRoot 'local'
$sourceFile = New-Fixture (Join-Path $script:TestRoot 'source\sample.txt') 'new verified backup data'
$target = Join-Path $localRoot 'sample.txt'
$oldFile = New-Fixture $target 'old backup data'
$oldHash = [SafeSyncFileIntegrity]::Hash($target, 'SHA256')
$newHash = [SafeSyncFileIntegrity]::Hash($sourceFile.FullName, 'SHA256')
Copy-FileSafely $sourceFile $target $localRoot 'sample.txt'
Assert-Test ([SafeSyncFileIntegrity]::Hash($target, 'SHA256') -eq $newHash) 'Local publication does not contain the new data.'
$previousCopies = @(Get-ChildItem -LiteralPath (Join-Path $localRoot '.safesync-trash') -File -Recurse)
Assert-Test (@($previousCopies | Where-Object { [SafeSyncFileIntegrity]::Hash($_.FullName, 'SHA256') -eq $oldHash }).Count -eq 1) 'Previous local version was not retained.'

foreach ($failure in @('corrupt','truncate','locked-target')) {
    $root = Join-Path $script:TestRoot $failure
    $target = Join-Path $root 'sample.txt'
    [void](New-Fixture $target 'original intact version')
    $expected = [SafeSyncFileIntegrity]::Hash($target, 'SHA256')
    $stage = "$target.safesync-part-test"
    $snapshot = New-SafeSyncSnapshot $sourceFile $stage
    $held = $null
    if ($failure -eq 'corrupt') {
        $bytes = [System.IO.File]::ReadAllBytes($stage); $bytes[0] = $bytes[0] -bxor 1
        [System.IO.File]::WriteAllBytes($stage, $bytes)
    } elseif ($failure -eq 'truncate') {
        [System.IO.File]::WriteAllBytes($stage, [byte[]]@(1,2))
    } else {
        $held = [System.IO.File]::Open($target, 'Open', 'Read', [System.IO.FileShare]::Read)
    }
    try { Assert-Fails { Publish-SafeSyncLocalSnapshot $snapshot $target $root 'sample.txt' } "$failure was accepted as a successful backup." }
    finally { if ($null -ne $held) { $held.Dispose() } }
    Assert-Test ([SafeSyncFileIntegrity]::Hash($target, 'SHA256') -eq $expected) "$failure damaged the previous backup."
}

$writer = [System.IO.File]::Open($sourceFile.FullName, 'Open', 'Write', [System.IO.FileShare]::ReadWrite)
try { Assert-Fails { New-SafeSyncSnapshot $sourceFile (Join-Path $localRoot 'busy.safesync-part-test') } 'A source file opened for writing was accepted.' }
finally { $writer.Dispose() }

# Simulate an interrupted replacement: original already preserved, target absent.
$recoveryRoot = Join-Path $script:TestRoot 'recovery'
$target = Join-Path $recoveryRoot 'sample.txt'
$old = New-Fixture (Join-Path $recoveryRoot '.safesync-trash\bundle\sample.txt') 'recoverable old bytes'
$stage = "$target.safesync-part-recovery"
$snapshot = New-SafeSyncSnapshot $sourceFile $stage
$record = [pscustomobject]@{ Destination=$target; Staged=$stage; Previous=$old.FullName; PreviousLength=$old.Length; PreviousSha256=[SafeSyncFileIntegrity]::Hash($old.FullName,'SHA256'); Sha256=$snapshot.Sha256; Length=$snapshot.Length }
$journal = "$target.safesync-txn-test.json"
Write-SafeSyncTransaction $journal $record
Repair-SafeSyncLocalTransactions $recoveryRoot
Assert-Test ((Get-Content -LiteralPath $target -Raw) -eq 'recoverable old bytes') 'Interrupted local replacement did not restore the old version.'
Assert-Test (-not (Test-Path -LiteralPath $journal)) 'Recovered local journal remained pending.'

# Zero-length and multi-block Dropbox hash use independent known block digests.
$empty = New-Fixture (Join-Path $script:TestRoot 'empty.bin') ''
Assert-Test ([SafeSyncFileIntegrity]::DropboxHash($empty.FullName) -eq 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855') 'Empty Dropbox hash is incorrect.'
$blockFile = Join-Path $script:TestRoot 'blocks.bin'
$block = New-Object byte[] (4MB); $tail = [byte[]]@(1,2,3,4,5,6,7)
$stream = [System.IO.File]::Create($blockFile)
try { $stream.Write($block,0,$block.Length); $stream.Write($block,0,$block.Length); $stream.Write($tail,0,$tail.Length) } finally { $stream.Dispose() }
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $digest = $sha.ComputeHash($block)
    [byte[]]$combined = @($digest) + @($digest) + @($sha.ComputeHash($tail))
    $expected = [BitConverter]::ToString($sha.ComputeHash($combined)).Replace('-','').ToLowerInvariant()
} finally { $sha.Dispose() }
Assert-Test ([SafeSyncFileIntegrity]::DropboxHash($blockFile) -eq $expected) 'Multi-block Dropbox hash is incorrect.'
$header = ConvertTo-SafeSyncDropboxHeaderJson @{path='/한글 폴더/파일.txt'}
Assert-Test ($header -notmatch '[^\x20-\x7e]' -and ($header | ConvertFrom-Json).path -eq '/한글 폴더/파일.txt') 'Dropbox Unicode header encoding failed.'

# A failed file must not prevent the remaining files in the actual local job from copying.
$copyDefinition = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-FileSafely' }, $true))[0].Extent.Text
Invoke-Expression ($copyDefinition -replace '^function Copy-FileSafely', 'function Copy-FileSafely-TestOriginal')
function Copy-FileSafely {
    param($SourceFile,$DestinationPath,$DestinationRoot,$RelativePath)
    if ($SourceFile.Name -eq 'bad.txt') { throw 'simulated copy interruption' }
    Copy-FileSafely-TestOriginal $SourceFile $DestinationPath $DestinationRoot $RelativePath
}
$continueSource = Join-Path $script:TestRoot 'continue-source'
$continueDestination = Join-Path $script:TestRoot 'continue-destination'
[void](New-Fixture (Join-Path $continueSource 'bad.txt') 'new bad content')
[void](New-Fixture (Join-Path $continueSource 'good.txt') 'good content')
$old = New-Fixture (Join-Path $continueDestination 'bad.txt') 'previous intact content'
[System.IO.File]::SetLastWriteTimeUtc($old.FullName, [datetime]::UtcNow.AddMinutes(-10))
$job=[pscustomobject]@{Id='continue';Name='continuation';Source=$continueSource;Destination=$continueDestination;MirrorDeletes=$false}
$result=Invoke-LocalBackupJob $job 100
Assert-Test ($result.Status -eq 'CompletedWithErrors' -and $result.Copied -eq 1 -and @($result.Errors).Count -eq 1) 'One failed file prevented the remaining local job from completing.'
Assert-Test ((Get-Content -LiteralPath $old.FullName -Raw) -eq 'previous intact content') 'Interrupted file copy damaged the previous backup.'
$progress = Get-Content -LiteralPath (Join-Path $script:ProgressRoot 'continue.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$progress.Stage) -and $progress.CompletedFiles -eq 2 -and $progress.TotalFiles -eq 2 -and $progress.Percent -eq 100) 'Local progress did not report the full workload.'
Write-SafeSyncProgress -Job $job -Stage 'Backing up file' -CurrentFile 'folder\sample.bin' -CurrentFileSize 2048 -CompletedFiles 3 -TotalFiles 10 -Force
$progress = Get-Content -LiteralPath (Join-Path $script:ProgressRoot 'continue.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Test ($progress.CurrentFile -eq 'folder\sample.bin' -and $progress.CurrentFileSize -eq 2048 -and $progress.Percent -eq 30) 'Current-file progress details are incorrect.'
Invoke-Expression $copyDefinition

# Faults below affect only an in-memory mock cloud; no external API is called.
$script:CloudFiles = @{}
$script:Fault = ''
$script:LastUploadedId = ''
$script:Outage = $false
$script:OldPublished = $false
$script:OriginalGoogleHash = ''
function Reset-Mock([string]$Provider, [string]$Fault) {
    $script:DataRoot = Join-Path $script:TestRoot ("cloud-$Provider-$Fault-" + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($script:DataRoot)
    $script:CloudFiles = @{}; $script:Fault=$Fault; $script:Outage=$false; $script:LastUploadedId=''
    if ($Provider -eq 'Dropbox') {
        $script:CloudFiles['old'] = [pscustomobject]@{id='old';path_display='/Backups/sample.txt';rev='initial';size=3;content_hash='old-hash'}
    } else {
        $script:CloudFiles['old'] = [pscustomobject]@{id='old';name='sample.txt';parents=@('root');version='1';size=3;sha256Checksum='old-hash';md5Checksum='old-md5';trashed=$false}
    }
}
function Ensure-SafeSyncDropboxFolder {}
function Get-SafeSyncDropboxMetadata([string]$Token, [string]$Path) {
    if ($script:Outage) { throw 'simulated disconnected network' }
    if ($script:CloudFiles.ContainsKey($Path)) { return $script:CloudFiles[$Path] }
    return $script:CloudFiles.Values | Where-Object { $_.path_display -eq $Path } | Select-Object -First 1
}
function Send-SafeSyncDropboxFile([string]$Token, [System.IO.FileInfo]$File, [string]$RemotePath) {
    if ($script:Fault -eq 'upload') { throw 'simulated upload failure' }
    $id = [guid]::NewGuid().ToString('N'); $script:LastUploadedId=$id
    $hash = [SafeSyncFileIntegrity]::DropboxHash($File.FullName)
    if ($script:Fault -eq 'checksum') { $hash='wrong' }
    $metadata = [pscustomobject]@{id=$id;path_display=$RemotePath;rev='new';size=$File.Length;content_hash=$hash}
    if ($script:Fault -eq 'missing-checksum') { $metadata.PSObject.Properties.Remove('content_hash') }
    $script:CloudFiles[$id]=$metadata
    return $metadata
}
function Move-SafeSyncDropboxItem([string]$Token,[string]$FromPath,[string]$ToPath,[bool]$AutoRename=$true) {
    $item = Get-SafeSyncDropboxMetadata $Token $FromPath
    if ($null -eq $item) { throw 'mock missing item' }
    $promoting = $item.id -eq $script:LastUploadedId -and $ToPath -eq '/Backups/sample.txt'
    if ($promoting -and $script:Fault -in @('publish','recovery')) {
        if ($script:Fault -eq 'recovery') { $script:Outage=$true }
        throw 'simulated failed rename'
    }
    $occupied = Get-SafeSyncDropboxMetadata $Token $ToPath
    if ($null -ne $occupied -and $occupied.id -ne $item.id) { throw 'mock target conflict' }
    $item.path_display=$ToPath
    if ($promoting -and $script:Fault -eq 'timeout-after-publish') { throw 'simulated response lost after rename' }
    if ($promoting -and $script:Fault -eq 'corrupt-after-publish') { $item.content_hash='wrong' }
}
function Ensure-SafeSyncGoogleFolderPath([string]$Token,[string]$RootId,[string]$RelativePath,[hashtable]$FolderMap) {
    if (-not $RelativePath) { return $RootId }
    return $RelativePath
}
function Send-SafeSyncGoogleFile([string]$Token,[System.IO.FileInfo]$File,[string]$ParentId,[string]$RemoteName) {
    if ($script:Fault -eq 'upload') { throw 'simulated upload failure' }
    $id=[guid]::NewGuid().ToString('N'); $script:LastUploadedId=$id
    $hash=[SafeSyncFileIntegrity]::Hash($File.FullName,'SHA256')
    if ($script:Fault -eq 'checksum') { $hash='wrong' }
    $metadata=[pscustomobject]@{id=$id;name=$RemoteName;parents=@($ParentId);size=$File.Length;sha256Checksum=$hash;md5Checksum=[SafeSyncFileIntegrity]::Hash($File.FullName,'MD5');version='1';trashed=$false}
    if ($script:Fault -eq 'md5-fallback') { $metadata.PSObject.Properties.Remove('sha256Checksum') }
    if ($script:Fault -eq 'missing-checksum') { $metadata.PSObject.Properties.Remove('sha256Checksum'); $metadata.PSObject.Properties.Remove('md5Checksum') }
    $script:CloudFiles[$id]=$metadata
    return $metadata
}
function Get-SafeSyncGoogleMetadata([string]$Token,[string]$FileId) {
    if ($script:Outage) { throw 'simulated disconnected network' }
    return $script:CloudFiles[$FileId]
}
function Move-SafeSyncGoogleItem([string]$Token,[string]$FileId,[string]$OldParentId,[string]$NewParentId) {
    if ($script:Fault -eq 'archive-failure' -and $FileId -eq 'old') { throw 'simulated archive failure' }
    $script:CloudFiles[$FileId].parents=@($NewParentId)
    $script:CloudFiles[$FileId].version=([long]$script:CloudFiles[$FileId].version + 1).ToString()
}
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body)
    if ($Method -ne 'Patch') { throw 'Unexpected real API route in mock test.' }
    if ($script:Fault -eq 'publish') { throw 'simulated Google promotion failure' }
    $item=$script:CloudFiles[$script:LastUploadedId]
    $item.parents=@('root');$item.name='sample.txt'
    if ($script:Fault -eq 'corrupt-after-publish') { $item.sha256Checksum='wrong' }
    if ($script:Fault -eq 'timeout-after-publish') { throw 'simulated Google response lost after promotion' }
    return $item
}

foreach ($provider in @('Dropbox','GoogleDrive')) {
    foreach ($fault in @('none','upload','checksum','missing-checksum','publish','timeout-after-publish','corrupt-after-publish')) {
        Reset-Mock $provider $fault
        $previous=$script:CloudFiles['old'] | Select-Object *
        $job=[pscustomobject]@{Id='mock';CloudFolderId=if($provider -eq 'Dropbox'){'/Backups'}else{'root'}}
        $action = {
            if ($provider -eq 'Dropbox') { Publish-SafeSyncDropboxFile 'mock' $sourceFile '/Backups/sample.txt' $previous $job }
            else { Publish-SafeSyncGoogleFile 'mock' $sourceFile 'root' $previous $job @{'_'='root'} }
        }
        if ($fault -in @('none','timeout-after-publish')) {
            & $action
            $new=$script:CloudFiles[$script:LastUploadedId]
            Assert-Test ($new.size -eq $sourceFile.Length) "$provider did not publish the full file."
            if ($provider -eq 'Dropbox') {
                Assert-Test ($new.path_display -eq '/Backups/sample.txt' -and $script:CloudFiles['old'].path_display -like '/Backups/.safesync-trash/*') 'Dropbox did not preserve its old version after verification.'
            } else {
                Assert-Test ($new.parents[0] -eq 'root' -and $script:CloudFiles['old'].parents[0] -like '.safesync-trash/*') 'Google did not preserve its old version after verification.'
            }
        } else {
            Assert-Fails $action "$provider $fault incorrectly reported success."
            if ($provider -eq 'Dropbox') { Assert-Test ($script:CloudFiles['old'].path_display -eq '/Backups/sample.txt') "Dropbox $fault lost its original live backup." }
            else { Assert-Test ($script:CloudFiles['old'].parents[0] -eq 'root') "Google $fault lost its original live backup." }
        }
    }
}

Reset-Mock 'Dropbox' 'recovery'
$previous=$script:CloudFiles['old'] | Select-Object *
$job=[pscustomobject]@{Id='mock';CloudFolderId='/Backups'}
Assert-Fails { Publish-SafeSyncDropboxFile 'mock' $sourceFile '/Backups/sample.txt' $previous $job } 'Disconnected Dropbox promotion incorrectly succeeded.'
Assert-Test ((@(Get-ChildItem -LiteralPath (Join-Path $script:DataRoot 'transactions') -Filter '*.json')).Count -eq 1) 'Disconnected transaction was not recorded for recovery.'
$script:Outage=$false;$script:Fault='none'
Repair-SafeSyncCloudTransactions 'Dropbox' 'mock' $job
Assert-Test ($script:CloudFiles['old'].path_display -eq '/Backups/sample.txt') 'Dropbox next-run recovery did not restore the original.'

Reset-Mock 'GoogleDrive' 'archive-failure'
$previous=$script:CloudFiles['old'] | Select-Object *
$job=[pscustomobject]@{Id='mock';CloudFolderId='root'}
Assert-Fails { Publish-SafeSyncGoogleFile 'mock' $sourceFile 'root' $previous $job @{'_'='root'} } 'Failed Google old-version archive incorrectly succeeded.'
Assert-Test ($script:CloudFiles['old'].parents[0] -eq 'root' -and $script:CloudFiles[$script:LastUploadedId].parents[0] -eq 'root') 'Google archive failure did not preserve both versions.'
$script:Fault='none'
Repair-SafeSyncCloudTransactions 'GoogleDrive' 'mock' $job
Assert-Test ($script:CloudFiles['old'].parents[0] -like '.safesync-trash/*') 'Google next-run recovery did not complete the old-version archive.'

Reset-Mock 'GoogleDrive' 'md5-fallback'
$job=[pscustomobject]@{Id='mock';CloudFolderId='root'}
Publish-SafeSyncGoogleFile 'mock' $sourceFile 'root' $null $job @{'_'='root'}
Assert-Test ($script:CloudFiles[$script:LastUploadedId].parents[0] -eq 'root') 'Google MD5 verification fallback failed.'

# Exercise the real Dropbox upload-session sender using only mocked HTTP responses.
$cloudAst=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.Cloud.ps1').Path,[ref]$tokens,[ref]$parseErrors)
$sender=@($cloudAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Send-SafeSyncDropboxFile'},$true))[0]
Invoke-Expression $sender.Extent.Text
$script:UploadBytes=[long]0
$script:LargeLength=[long](141MB + 17)
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body,$InFile)
    Assert-Test ($Headers['Dropbox-API-Arg'] -notmatch '[^\x20-\x7e]') 'Upload session header contains raw Unicode.'
    $arg=$Headers['Dropbox-API-Arg'] | ConvertFrom-Json
    if ($Uri -like '*/files/upload') {
        Assert-Test ((Get-Item -LiteralPath $InFile).Length -eq 0 -and $arg.mode -eq 'add') 'Empty upload failed to use the safe staging mode.'
        return [pscustomobject]@{id='empty';size=0}
    }
    Assert-Test ($Body -is [byte[]]) 'Upload session chunk is not binary data.'
    if ($Uri -like '*/start') {
        $script:UploadBytes += $Body.Length
        return [pscustomobject]@{session_id='mock-session'}
    }
    Assert-Test ([long]$arg.cursor.offset -eq $script:UploadBytes) 'Upload session offset does not match the transmitted bytes.'
    $script:UploadBytes += $Body.Length
    if ($Uri -like '*/finish') {
        Assert-Test ($script:UploadBytes -eq $script:LargeLength -and $arg.commit.mode -eq 'add' -and $arg.commit.strict_conflict) 'Upload session final chunk or safe commit mode is incorrect.'
        return [pscustomobject]@{id='large';size=$script:UploadBytes}
    }
    return $null
}
$largePath=Join-Path $script:TestRoot 'large.bin'
$stream=[System.IO.File]::Create($largePath)
try{$stream.SetLength($script:LargeLength)}finally{$stream.Dispose()}
[void](Send-SafeSyncDropboxFile 'mock' (Get-Item -LiteralPath $largePath) '/한글/.safesync-staging/large')
[void](Send-SafeSyncDropboxFile 'mock' $empty '/한글/.safesync-staging/empty')

# Google omits nextPageToken on the final page; StrictMode must still accept it.
$children=@($cloudAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SafeSyncGoogleChildren'},$true))[0]
Invoke-Expression $children.Extent.Text
$script:PageCalls=0
function Invoke-RestMethod {
    param($Method,$Uri,$Headers)
    $script:PageCalls++
    if ($script:PageCalls -eq 1) { return [pscustomobject]@{files=@([pscustomobject]@{id='page-one'});nextPageToken='page-two'} }
    return [pscustomobject]@{files=@([pscustomobject]@{id='page-two'})}
}
$items=@(Get-SafeSyncGoogleChildren 'mock' 'root')
Assert-Test ($items.Count -eq 2 -and $script:PageCalls -eq 2) 'Google folder enumeration failed when the final page omitted nextPageToken.'

[pscustomobject]@{AssertionsPassed=$script:Passed;LocalFaults='corrupt/truncated/locked/source-busy/recovery';CloudFaults='upload/checksum/missing-checksum/publish/lost-response/recovery';ExternalCalls=0;Status='OK'}
