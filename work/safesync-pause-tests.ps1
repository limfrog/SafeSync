$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }

$sourcePath = (Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
Assert-Test ($errors.Count -eq 0) 'SafeSync.ps1 does not parse.'
$source = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)

foreach ($name in @('Test-SafeSyncJobPaused', 'Stop-SafeSyncJobProcesses', 'Set-SafeSyncJobPaused')) {
    $node = @($ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true))[0]
    Assert-Test ($null -ne $node) "Missing function: $name"
    Invoke-Expression $node.Extent.Text
}

$checkNode = @($ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Check-Automation' }, $true))[0]
$watchNode = @($ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Start-Watchers' }, $true))[0]
$startNode = @($ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Start-BackupProcess' }, $true))[0]
Assert-Test ($checkNode.Extent.Text.Contains('Test-SafeSyncJobPaused')) 'Paused jobs are not excluded from automatic and scheduled execution.'
Assert-Test ($watchNode.Extent.Text.Contains('if (-not (Test-SafeSyncJobPaused $job))')) 'Paused jobs still launch startup reconciliation.'
Assert-Test ($startNode.Extent.Text.Contains('if (Test-SafeSyncJobPaused $Job)')) 'Direct backup startup does not reject a paused job.'
Assert-Test ($source.Contains('Paused = if ($null -ne $ExistingJob')) 'Editing a job does not preserve its paused state.'
Assert-Test ($source.Contains("Join-Path ([string]`$job.Destination) '.safesync-trash'")) 'The trash button is not routed to the selected backup destination.'
Assert-Test ($source.Contains('Show-SelectedSafeSyncTrashBrowser')) 'The SafeSync trash management window is not connected.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SafeSync.pause-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot -Force)
$script:ProgressRoot = $testRoot
$script:RunningJobs = @{}
$script:ReconciliationJobs = @{}
$script:PendingChanges = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:LastStatus = @{}
$script:Activities = New-Object System.Collections.Generic.List[string]
$script:SavedState = $null
$script:RefreshCount = 0

function Save-Config([object]$Config) {
    $Config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $testRoot 'config.json') -Encoding UTF8
}
function Save-PendingFileChanges([object]$Job) { return 0 }
function Get-SafeSyncState([string]$JobId) { return [pscustomobject]@{ JobId=$JobId; FullScanRequired=$false } }
function Save-SafeSyncState([object]$State) { $script:SavedState = $State }
function Add-Activity([string]$Text) { $script:Activities.Add($Text) }
function Write-AppLog([string]$Message, [string]$Level = 'INFO') { }
function Refresh-JobsGrid { $script:RefreshCount++ }
function Refresh-ProgressWindow { }

$job = [pscustomobject]@{ Id='pause-me'; Name='멈출 작업'; TriggerType='Realtime'; Paused=$false }
$otherJob = [pscustomobject]@{ Id='keep-running'; Name='계속할 작업'; TriggerType='Realtime'; Paused=$false }
$script:Config = [pscustomobject]@{ Version=5; Jobs=@($job, $otherJob) }
$sleepArgs = '-NoProfile -WindowStyle Hidden -Command "Start-Sleep -Seconds 60"'
$pausedProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $sleepArgs -WindowStyle Hidden -PassThru
$otherProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $sleepArgs -WindowStyle Hidden -PassThru
$pausedProcessId = $pausedProcess.Id
$otherProcessId = $otherProcess.Id
$script:RunningJobs[$job.Id] = [pscustomobject]@{ Process=$pausedProcess; Job=$job; ResultPath=(Join-Path $testRoot 'pause-result.json'); ConflictPlanPath='' }
$script:RunningJobs[$otherJob.Id] = [pscustomobject]@{ Process=$otherProcess; Job=$otherJob; ResultPath=(Join-Path $testRoot 'other-result.json'); ConflictPlanPath='' }

try {
    $pauseFailures = @(Set-SafeSyncJobPaused $job $true)
    Assert-Test ($pauseFailures.Count -eq 0) 'Pausing returned an unexpected cleanup failure.'
    Assert-Test (Test-SafeSyncJobPaused $job) 'The selected job was not marked paused.'
    Assert-Test (-not $script:RunningJobs.ContainsKey($job.Id)) 'The selected running job was not removed.'
    Assert-Test ($null -eq (Get-Process -Id $pausedProcessId -ErrorAction SilentlyContinue)) 'The selected backup process is still running.'
    Assert-Test ($script:RunningJobs.ContainsKey($otherJob.Id)) 'A different backup job was removed.'
    Assert-Test ($null -ne (Get-Process -Id $otherProcessId -ErrorAction SilentlyContinue)) 'A different backup process was stopped.'
    Assert-Test ($null -ne $script:SavedState -and -not [bool]$script:SavedState.FullScanRequired) 'Pausing incorrectly scheduled a source-wide full check.'
    Assert-Test ($source.Contains('CheckpointActive') -and $source.Contains('checkpointPending')) 'The worker has no resumable file checkpoint.'
    $savedConfig = Get-Content -LiteralPath (Join-Path $testRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test ([bool](@($savedConfig.Jobs | Where-Object Id -eq $job.Id)[0].Paused)) 'The paused state was not persisted.'

    $resumeFailures = @(Set-SafeSyncJobPaused $job $false)
    Assert-Test ($resumeFailures.Count -eq 0) 'Resuming returned an unexpected failure.'
    Assert-Test (-not (Test-SafeSyncJobPaused $job)) 'The job remained paused after resume.'
    Assert-Test ($script:PendingChanges.ContainsKey($job.Id)) 'A realtime job did not schedule its safe resume check.'

    $scheduled = [pscustomobject]@{ Id='scheduled'; Name='예약 작업'; TriggerType='Scheduled'; ScheduleTime=(Get-Date).AddMinutes(-1).ToString('HH:mm'); LastScheduledRun=''; Paused=$true }
    $script:Config.Jobs += $scheduled
    [datetime]$discard = [datetime]::MinValue
    [void]$script:PendingChanges.TryRemove($scheduled.Id, [ref]$discard)
    [void](Set-SafeSyncJobPaused $scheduled $false)
    Assert-Test (-not $script:PendingChanges.ContainsKey($scheduled.Id)) 'A scheduled job ran immediately instead of waiting for its schedule.'
    Assert-Test ([string]$scheduled.LastScheduledRun -eq (Get-Date).ToString('yyyy-MM-dd')) 'A missed schedule was not advanced to the next scheduled day on resume.'
}
finally {
    foreach ($processId in @($pausedProcessId, $otherProcessId)) {
        try { $process = Get-Process -Id $processId -ErrorAction SilentlyContinue; if ($null -ne $process) { $process.Kill(); [void]$process.WaitForExit(5000); $process.Dispose() } } catch { }
    }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: $script:Passed pause and trash assertions"
