$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework,System.Windows.Forms,System.Drawing
$script:Passed=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++}

$testRoot=Join-Path (Resolve-Path '.\work').Path ('notification-test-'+[guid]::NewGuid().ToString('N'))
$script:DataRoot=$testRoot
$script:LogRoot=Join-Path $testRoot 'logs'
$script:ManifestRoot=Join-Path $testRoot 'manifests'
$script:NotificationStatePath=Join-Path $testRoot 'notification-state.json'
[void][IO.Directory]::CreateDirectory($script:ManifestRoot)
$script:KnownIssues=@{}
$script:PendingNotices=New-Object System.Collections.ArrayList
$script:ShowingPendingNotices=$false
$script:TrayAnimationFrames=@()
$script:TrayAnimationIndex=0
$script:RunningJobs=@{}
$script:ReconciliationJobs=@{}

. '.\outputs\SafeSync\SafeSync.Integrity.ps1'

$path=(Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$script:ScriptPath=$path
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Test ($errors.Count -eq 0) 'Main script does not parse.'
$names=@('Write-AppLog','Initialize-DataFolders','Get-SafeSyncStatePath','New-SafeSyncState','Get-SafeSyncState','ConvertTo-SafeSyncRelativePath','Save-SafeSyncNotificationState','Load-SafeSyncNotificationState','Get-SafeSyncIssueKey','Get-SafeSyncErrorFile','Remove-SafeSyncResolvedIssueKeys','Initialize-SafeSyncTrayAnimation','Dispose-SafeSyncTrayAnimation','Update-SafeSyncTrayIcon','Test-SafeSyncTrayWorkRunning','Update-SafeSyncNoticeIndicator','Remove-SafeSyncLockedFileErrors','Add-SafeSyncResultNotices','Test-SafeSyncCanShowNotices')
foreach($node in $ast.FindAll({param($item)$item -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){if($node.Name -in $names){Invoke-Expression $node.Extent.Text}}

$jobId='notice-job'
$state=[pscustomobject]@{Version=1;JobId=$jobId;LastFullScanUtc='';LastRunUtc='';FullScanRequired=$false;PendingPaths=@();Files=@([pscustomobject]@{RelativePath='folder/problem.txt';Length=10;CreationTimeUtc='';LastWriteTimeUtc='';Status='Conflict';LastError='';LastAttemptUtc='';RemoteId='';RemoteParentId=''})}
$state|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
$conflict=[pscustomobject]@{JobId=$jobId;JobName='Notice test';Conflicts=@([pscustomobject]@{File='folder/problem.txt';Reason='test conflict';SourceSize=10;BackupSize=20;SourceModified='';BackupModified=''});Errors=@()}
$first=[int](Add-SafeSyncResultNotices $conflict)
Assert-Test ($first -eq 1 -and $script:PendingNotices.Count -eq 1 -and $script:KnownIssues.Count -eq 1) 'First conflict was not queued exactly once.'
$second=[int](Add-SafeSyncResultNotices $conflict)
Assert-Test ($second -eq 0 -and $script:PendingNotices.Count -eq 1 -and $script:KnownIssues.Count -eq 1) 'Repeated conflict produced another notification.'
Assert-Test (Test-Path -LiteralPath $script:NotificationStatePath) 'Notification state was not persisted.'

$script:KnownIssues=@{};$script:PendingNotices=New-Object System.Collections.ArrayList
Load-SafeSyncNotificationState
Assert-Test ($script:KnownIssues.Count -eq 1 -and $script:PendingNotices.Count -eq 1) 'Notification deduplication state did not survive reload.'
$loadedState=Get-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Raw -Encoding UTF8|ConvertFrom-Json
$loadedState.Files[0].Status='BackedUp'
$loadedState|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
$cleared=[int](Add-SafeSyncResultNotices ([pscustomobject]@{JobId=$jobId;JobName='Notice test';Conflicts=@();Errors=@()}))
Assert-Test ($cleared -eq 0 -and $script:KnownIssues.Count -eq 0 -and $script:PendingNotices.Count -eq 0) 'Resolved file did not clear its deduplication key and stale pending notice.'
$loadedState.Files[0].Status='Conflict'
$loadedState|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
Assert-Test ([int](Add-SafeSyncResultNotices $conflict) -eq 1) 'A newly recurring conflict was not allowed after the earlier issue was resolved.'

$script:KnownIssues=@{};$script:PendingNotices=New-Object System.Collections.ArrayList
$loadedState.Files[0].Status='Locked'
$loadedState|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
$lockedResult=[pscustomobject]@{JobId=$jobId;JobName='Notice test';Conflicts=@();Errors=@();LockedFiles=@([pscustomobject]@{File='folder/problem.txt'})}
Assert-Test ([int](Add-SafeSyncResultNotices $lockedResult) -eq 0 -and $script:PendingNotices.Count -eq 0) 'An in-use file was added to ordinary popup notices.'
$wrappedLockedResult=[pscustomobject]@{JobId=$jobId;JobName='Notice test';Conflicts=@();Errors=@('folder/problem.txt : The process cannot access the file because it is being used by another process.');LockedFiles=@([pscustomobject]@{File='folder/problem.txt'})}
Assert-Test ([int](Add-SafeSyncResultNotices $wrappedLockedResult) -eq 0 -and @($wrappedLockedResult.Errors).Count -eq 0 -and $script:PendingNotices.Count -eq 0) 'A wrapped in-use file error was added to ordinary popup notices.'
$loadedState.Files[0].Status='Failed'
$loadedState|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
$errorResult=[pscustomobject]@{JobId=$jobId;JobName='Notice test';Conflicts=@();Errors=@('folder/problem.txt : test error');LockedFiles=@()}
Assert-Test ([int](Add-SafeSyncResultNotices $errorResult) -eq 1) 'An ordinary file error was not recorded.'
$loadedState.Files[0].Status='Locked'
$loadedState|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
Assert-Test ([int](Add-SafeSyncResultNotices $lockedResult) -eq 0 -and $script:PendingNotices.Count -eq 0) 'A file reclassified as in-use kept its old popup notice.'
$loadedState.Files[0].Status='Conflict'
$loadedState|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $script:ManifestRoot "$jobId.sync.json") -Encoding UTF8
Assert-Test ([int](Add-SafeSyncResultNotices $conflict) -eq 1) 'A conflict was not restored for indicator testing.'

$script:NotifyIcon=New-Object System.Windows.Forms.NotifyIcon
$script:NotificationsButton=New-Object System.Windows.Controls.Button
$script:AppIcon=$null
try{
    Update-SafeSyncNoticeIndicator
    Assert-Test ($script:NotifyIcon.Text -match '1' -and [string]$script:NotificationsButton.Content -match '1' -and $script:NotificationsButton.IsEnabled) 'Pending message did not change the tray or main-window indicator.'
}finally{$script:NotifyIcon.Dispose()}

$script:NotifyIcon=New-Object System.Windows.Forms.NotifyIcon
$script:AppIcon=New-Object System.Drawing.Icon((Resolve-Path '.\outputs\SafeSync\SafeSync.ico'))
$script:RunningJobs=@{'animation-job'=[pscustomobject]@{}}
try {
    Initialize-SafeSyncTrayAnimation
    Assert-Test ($script:TrayAnimationFrames.Count -eq 4) 'Tray animation frames were not generated.'
    Update-SafeSyncTrayIcon
    Assert-Test ($null -ne $script:NotifyIcon.Icon -and $script:NotifyIcon.Text -match 'SafeSync') 'Running backup did not select an animated tray frame.'
}
finally { Dispose-SafeSyncTrayAnimation; $script:NotifyIcon.Dispose(); $script:AppIcon.Dispose(); $script:RunningJobs=@{} }

$script:Window=New-Object System.Windows.Window
$script:Window.ShowActivated=$false;$script:Window.Left=-9000;$script:Window.Top=-9000
$script:Window.Show();$script:Window.WindowState=[Windows.WindowState]::Minimized
Assert-Test (-not (Test-SafeSyncCanShowNotices)) 'A minimized window was allowed to show error popups.'
$script:Window.WindowState=[Windows.WindowState]::Normal
Assert-Test (Test-SafeSyncCanShowNotices) 'A visible normal window was not allowed to show pending notices.'
$script:Window.Close()

Write-Host "PASS: $script:Passed notification assertions"
