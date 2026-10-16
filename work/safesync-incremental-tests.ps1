$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
$script:TestRoot = Join-Path (Resolve-Path '.\work').Path ('incremental-test-' + [guid]::NewGuid().ToString('N'))
$script:DataRoot = Join-Path $script:TestRoot 'data'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:ManifestRoot = Join-Path $script:DataRoot 'manifests'
$script:ResultRoot = Join-Path $script:DataRoot 'results'
$script:ProgressRoot = Join-Path $script:DataRoot 'progress'
$script:LastProgressWrite = @{}
$script:ChangedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:PendingChanges = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
[void][System.IO.Directory]::CreateDirectory($script:TestRoot)
. '.\outputs\SafeSync\SafeSync.Integrity.ps1'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw (@($parseErrors | ForEach-Object {$_.Message}) -join '; ') }
$functions = @('Write-SafeSyncProgress','Initialize-DataFolders','Write-AppLog','Get-NormalizedPath','Test-PathRelationship','Get-RelativePath','Get-SafeSyncFilesWithProgress','Move-ToSafeTrash','Remove-ExpiredTrash','Copy-FileToSafeTrash','Get-SafeSyncStatePath','New-SafeSyncState','Get-SafeSyncState','Save-SafeSyncState','ConvertTo-SafeSyncRelativePath','Set-SafeSyncStateEntry','Remove-SafeSyncStateEntry','Get-SafeSyncBackupPlan','Test-SafeSyncStartupReconciliationRequired','Queue-SafeSyncSnapshotRetries','Invoke-SafeSyncStartupReconciliation','Copy-FileSafely','Invoke-LocalBackupJob','Add-SafeSyncChangedPath','Queue-SafeSyncStartupReconciliation','Save-PendingFileChanges')
foreach ($node in $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
    if ($node.Name -in $functions) { Invoke-Expression $node.Extent.Text }
}

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Add-Activity([string]$Text) { }
function Write-Fixture([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Text)
    [System.IO.File]::SetLastWriteTimeUtc($Path, [datetime]::UtcNow)
}
function Queue-Paths([string]$JobId, [string[]]$Paths) {
    $state = Get-SafeSyncState $JobId
    $state.PendingPaths = @($Paths)
    Save-SafeSyncState $state
}

$source = Join-Path $script:TestRoot 'source'
$destination = Join-Path $script:TestRoot 'destination'
[void][System.IO.Directory]::CreateDirectory($source)
[void][System.IO.Directory]::CreateDirectory($destination)
Write-Fixture (Join-Path $source 'a.txt') 'alpha'
Write-Fixture (Join-Path $source 'b.txt') 'bravo'
Write-Fixture (Join-Path $source 'folder\c.txt') 'charlie'
$job = [pscustomobject]@{Id='incremental';Name='Incremental test';Source=$source;Destination=$destination;MirrorDeletes=$true}

$first = Invoke-LocalBackupJob $job 100
Assert-Test ($first.Status -eq 'Completed' -and $first.ScanMode -eq 'Full' -and $first.Copied -eq 3) 'First run was not a complete initial scan.'
$state = Get-SafeSyncState $job.Id
Assert-Test ($state.Entries.Count -eq 3 -and @($state.Entries.Values | Where-Object {$_.Status -ne 'BackedUp'}).Count -eq 0) 'Initial snapshot is incomplete.'
$state.DropboxCursor='dropbox-cursor';$state.GoogleChangeToken='google-token';Save-SafeSyncState $state
$cursorState=Get-SafeSyncState $job.Id
Assert-Test ($cursorState.DropboxCursor -eq 'dropbox-cursor' -and $cursorState.GoogleChangeToken -eq 'google-token') 'Cloud change-feed cursors were not preserved in the snapshot.'
Assert-Test (-not (Test-SafeSyncStartupReconciliationRequired $job)) 'A current snapshot incorrectly requests another startup-wide comparison.'
$state.Entries['a.txt'].Status='Failed';Save-SafeSyncState $state
Queue-SafeSyncSnapshotRetries $job
Assert-Test ($script:PendingChanges.ContainsKey($job.Id)) 'A failed snapshot entry was not queued for incremental retry.'
$discard=[datetime]::MinValue;[void]$script:PendingChanges.TryRemove($job.Id,[ref]$discard)
$state.Entries['a.txt'].Status='BackedUp';Save-SafeSyncState $state

Start-Sleep -Milliseconds 1100
Write-Fixture (Join-Path $source 'b.txt') 'bravo changed'
Queue-Paths $job.Id @('b.txt')
$incremental = Invoke-LocalBackupJob $job 100
Assert-Test ($incremental.Status -eq 'Completed' -and $incremental.ScanMode -eq 'Incremental') 'Automatic run did not use incremental mode.'
Assert-Test ($incremental.Copied -eq 1 -and $incremental.Skipped -eq 0) 'Incremental run inspected files outside the change queue.'
$progress = Get-Content -LiteralPath (Join-Path $script:ProgressRoot 'incremental.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Test ($progress.TotalFiles -eq 1) 'Incremental progress includes unchanged files.'
Assert-Test (-not [string]::IsNullOrWhiteSpace([string]$progress.Detail) -and -not [string]::IsNullOrWhiteSpace([string]$progress.CurrentFolder)) 'Detailed progress omitted its phase explanation or current folder.'
Assert-Test ([string]$progress.SourceLocation -eq $source -and [string]$progress.DestinationLocation -eq $destination) 'Detailed progress omitted the source or destination location.'

$copyDefinition = @($ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Copy-FileSafely'}, $true))[0].Extent.Text
Invoke-Expression ($copyDefinition -replace '^function Copy-FileSafely', 'function Copy-FileSafely-Original')
function Copy-FileSafely {
    param($SourceFile,$DestinationPath,$DestinationRoot,$RelativePath)
    if ($SourceFile.Name -eq 'a.txt') { throw 'simulated incremental failure' }
    Copy-FileSafely-Original $SourceFile $DestinationPath $DestinationRoot $RelativePath
}
Start-Sleep -Milliseconds 1100
Write-Fixture (Join-Path $source 'a.txt') 'alpha changed'
Write-Fixture (Join-Path $source 'folder\c.txt') 'charlie changed'
Queue-Paths $job.Id @('a.txt','folder/c.txt')
$failed = Invoke-LocalBackupJob $job 100
Assert-Test ($failed.Status -eq 'CompletedWithErrors' -and $failed.Copied -eq 1 -and @($failed.Errors).Count -eq 1) 'A failed changed file blocked another changed file.'
$state = Get-SafeSyncState $job.Id
Assert-Test ([string]$state.Entries['a.txt'].Status -eq 'Failed' -and -not [string]::IsNullOrWhiteSpace([string]$state.Entries['a.txt'].LastError)) 'Failed file was not retained in the snapshot.'

Invoke-Expression $copyDefinition
$retryPlan = Get-SafeSyncBackupPlan $job $source
Assert-Test (-not $retryPlan.FullScan -and @($retryPlan.Paths).Count -eq 1 -and $retryPlan.Paths[0] -eq 'a.txt') 'Failed file was not automatically added to the next incremental run.'
$retried = Invoke-LocalBackupJob $job 100
Assert-Test ($retried.Status -eq 'Completed' -and $retried.ScanMode -eq 'Incremental' -and $retried.Copied -eq 1) 'Failed file was not retried successfully.'
$state = Get-SafeSyncState $job.Id
Assert-Test ([string]$state.Entries['a.txt'].Status -eq 'BackedUp') 'Successful retry did not clear the failed state.'

Remove-Item -LiteralPath (Join-Path $destination 'b.txt') -Force
Queue-Paths $job.Id @('b.txt')
$restored = Invoke-LocalBackupJob $job 100
Assert-Test ($restored.ScanMode -eq 'Incremental' -and $restored.Copied -eq 1 -and (Test-Path -LiteralPath (Join-Path $destination 'b.txt'))) 'Deleted backup file was not restored incrementally.'

$state = Get-SafeSyncState $job.Id
$state.LastFullScanUtc = [datetime]::UtcNow.AddDays(-8).ToString('o')
Save-SafeSyncState $state
Assert-Test (Test-SafeSyncStartupReconciliationRequired $job) 'A snapshot older than seven days did not request startup reconciliation.'
$weekly = Invoke-LocalBackupJob $job 100
Assert-Test ($weekly.ScanMode -eq 'Full' -and $weekly.Skipped -eq 3) 'A snapshot older than seven days did not trigger a full scan.'

$manual = Invoke-LocalBackupJob $job 100 -ForceFull
Assert-Test ($manual.ScanMode -eq 'Full' -and $manual.Skipped -eq 3) 'Manual force-full run did not scan all files.'

$sourceConflictPath=Join-Path $source 'a.txt'
$destinationConflictPath=Join-Path $destination 'a.txt'
[System.IO.File]::WriteAllText($destinationConflictPath,'newer backup that should be preserved in trash')
[System.IO.File]::SetLastWriteTimeUtc($destinationConflictPath,[datetime]::UtcNow.AddMinutes(5))
Queue-Paths $job.Id @('a.txt')
$conflicted=Invoke-LocalBackupJob $job 100
Assert-Test ($conflicted.Status -eq 'CompletedWithConflicts' -and @($conflicted.Conflicts).Count -eq 1) 'A newer backup file was not presented as a conflict.'
$resolved=Invoke-LocalBackupJob $job 100 -ForceOverwritePaths @('a.txt')
Assert-Test ($resolved.Status -eq 'Completed' -and $resolved.Copied -eq 1) 'Selected conflict was not overwritten from the source.'
Assert-Test ([System.IO.File]::ReadAllText($destinationConflictPath) -eq [System.IO.File]::ReadAllText($sourceConflictPath)) 'Resolved backup content does not match the source.'
Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $destination '.safesync-trash') -File -Recurse -ErrorAction SilentlyContinue | Where-Object {$_.Name -eq 'a.txt'}).Count -ge 1) 'The replaced conflicting backup was not retained in SafeSync trash.'
$state=Get-SafeSyncState $job.Id
Assert-Test ([string]$state.Entries['a.txt'].Status -eq 'BackedUp') 'Resolved conflict was not marked as backed up.'

Start-Sleep -Milliseconds 1100
Write-Fixture (Join-Path $source 'a.txt') 'changed while app was closed'
Remove-Item -LiteralPath (Join-Path $destination 'folder\c.txt') -Force
Queue-SafeSyncStartupReconciliation $job
Assert-Test ($script:ChangedPaths.ContainsKey('incremental|S|a.txt')) 'Startup reconciliation missed an offline source change.'
Assert-Test ($script:ChangedPaths.ContainsKey('incremental|D|folder/c.txt')) 'Startup reconciliation missed an offline destination deletion.'
[void](Save-PendingFileChanges $job)
$queuedState = Get-SafeSyncState $job.Id
Assert-Test (@($queuedState.PendingPaths | Where-Object {$_ -eq 'a.txt'}).Count -eq 1 -and @($queuedState.PendingPaths | Where-Object {$_ -eq 'folder/c.txt'}).Count -eq 1) 'Windows PowerShell did not persist split change-path keys.'
Assert-Test (@($script:ChangedPaths.Keys | Where-Object {$_.StartsWith('incremental|')}).Count -eq 0) 'Persisted change-path keys were not removed from memory.'

$lockedPath = Join-Path $source 'locked.txt'
Write-Fixture $lockedPath 'content held open by another application'
Queue-Paths $job.Id @('locked.txt')
$lockStream = [System.IO.File]::Open($lockedPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
try { $lockedResult = Invoke-LocalBackupJob $job 100 }
finally { $lockStream.Dispose() }
Assert-Test ($lockedResult.Status -eq 'CompletedWithLockedFiles' -and @($lockedResult.LockedFiles).Count -eq 1 -and @($lockedResult.Errors).Count -eq 0) 'An in-use file was shown as an ordinary backup error.'
$lockedState = Get-SafeSyncState $job.Id
Assert-Test ([string]$lockedState.Entries['locked.txt'].Status -eq 'Locked' -and [int]$lockedState.Entries['locked.txt'].LockRetryCount -eq 1) 'The in-use file and its retry count were not persisted.'
Assert-Test (-not (Test-Path -LiteralPath (Join-Path $destination 'locked.txt'))) 'A partially read in-use file was published to the backup.'
$lockedPlan = Get-SafeSyncBackupPlan $job $source
Assert-Test (@($lockedPlan.Paths).Count -eq 0) 'An in-use file was retried immediately instead of waiting for the lock schedule.'
$lockedState.PendingPaths = @('locked.txt')
Save-SafeSyncState $lockedState
$unlockedResult = Invoke-LocalBackupJob $job 100
Assert-Test ($unlockedResult.Status -eq 'Completed' -and $unlockedResult.Copied -eq 1) 'A file was not backed up after its application lock was released.'
$lockedState = Get-SafeSyncState $job.Id
Assert-Test ([string]$lockedState.Entries['locked.txt'].Status -eq 'BackedUp' -and [int]$lockedState.Entries['locked.txt'].LockRetryCount -eq 0) 'Successful retry did not clear the in-use state.'

$mainText = [System.IO.File]::ReadAllText((Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path)
$watcherCode = [regex]::Match($mainText, 'Add-Type -TypeDefinition @"\r?\n(?<code>.*?)\r?\n"@', [Text.RegularExpressions.RegexOptions]::Singleline)
Assert-Test ($watcherCode.Success) 'Watcher implementation could not be located.'
Add-Type -TypeDefinition $watcherCode.Groups['code'].Value
$pending = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$changedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$watchSource = Join-Path $script:TestRoot 'watch-source'
$watchDestination = Join-Path $script:TestRoot 'watch-destination'
[void][System.IO.Directory]::CreateDirectory($watchSource)
[void][System.IO.Directory]::CreateDirectory($watchDestination)
[System.IO.File]::WriteAllText((Join-Path $watchDestination 'gone.txt'),'delete me')
$sourceWatcher = [SafeSyncWatcher]::new($watchSource,'watch-job',$pending,$changedPaths,'S',$false)
$destinationWatcher = [SafeSyncWatcher]::new($watchDestination,'watch-job',$pending,$changedPaths,'D',$true)
try {
    [System.IO.File]::WriteAllText((Join-Path $watchSource 'new.txt'),'new')
    Remove-Item -LiteralPath (Join-Path $watchDestination 'gone.txt') -Force
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while([datetime]::UtcNow -lt $deadline -and (-not $changedPaths.ContainsKey('watch-job|S|new.txt') -or -not $changedPaths.ContainsKey('watch-job|D|gone.txt'))){Start-Sleep -Milliseconds 100}
    Assert-Test ($changedPaths.ContainsKey('watch-job|S|new.txt')) 'Source watcher did not retain the changed file path.'
    Assert-Test ($changedPaths.ContainsKey('watch-job|D|gone.txt')) 'Destination watcher did not retain the deleted file path.'
}
finally { $sourceWatcher.Dispose(); $destinationWatcher.Dispose() }

Write-Host "PASS: $script:Passed incremental snapshot assertions"
