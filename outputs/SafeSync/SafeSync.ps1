[CmdletBinding()]
param(
    [switch]$Minimized,
    [switch]$StartVisible,
    [switch]$ExitAfterStartupForTest,
    [switch]$SkipAutoStartForTest,
    [string]$WorkerJobId,
    [string]$ReconcileJobId,
    [switch]$ReconcileForce,
    [string]$ConflictPlanPath,
    [switch]$WorkerForceFull,
    [string]$DataRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'SafeSync'
$script:AppVersion = '1.9.10'
$script:ScriptPath = $MyInvocation.MyCommand.Path
if (-not [string]::IsNullOrWhiteSpace($WorkerJobId) -or -not [string]::IsNullOrWhiteSpace($ReconcileJobId)) {
    # The OS keeps this shared named object alive until every detached worker exits.
    # Installers can detect active workers without administrator privileges or WMI.
    $workerNameHasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $workerScriptKey = [System.IO.Path]::GetFullPath($script:ScriptPath).ToLowerInvariant()
        $workerNameHash = [System.BitConverter]::ToString($workerNameHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($workerScriptKey))).Replace('-', '').ToLowerInvariant()
    }
    finally { $workerNameHasher.Dispose() }
    $script:WorkerLifetimeMutex = [System.Threading.Mutex]::new($false, "Local\SafeSync.Workers.$workerNameHash")
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $DataRoot = Join-Path $env:LOCALAPPDATA 'SafeSync'
}
$script:DataRoot = [System.IO.Path]::GetFullPath($DataRoot)
$script:ConfigPath = Join-Path $script:DataRoot 'config.json'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:ResultRoot = Join-Path $script:DataRoot 'results'
$script:ManifestRoot = Join-Path $script:DataRoot 'manifests'
$script:ProgressRoot = Join-Path $script:DataRoot 'progress'
$script:NotificationStatePath = Join-Path $script:DataRoot 'notification-state.json'
$script:LastProgressWrite = @{}
$script:AppIcon = $null
$script:TrayAnimationFrames = @()
$script:TrayAnimationFramePaths = @()
$script:TrayAnimationIndex = 0
$script:TrayAnimationTimer = $null

function Write-SafeSyncProgress {
    param(
        [Parameter(Mandatory=$true)][object]$Job,
        [Parameter(Mandatory=$true)][string]$Stage,
        [string]$Detail = '',
        [string]$CurrentFolder = '',
        [string]$CurrentFile = '',
        [long]$CurrentFileSize = 0,
        [int]$CompletedFiles = 0,
        [int]$TotalFiles = 0,
        [switch]$Force
    )
    try {
        if (-not (Test-Path -LiteralPath $script:ProgressRoot)) { [void](New-Item -ItemType Directory -Path $script:ProgressRoot -Force) }
        $jobId = [string]$Job.Id
        $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
        $destinationValue = if ($null -ne $Job.PSObject.Properties['Destination']) { [string]$Job.Destination } else { '' }
        $cloudFolderValue = if ($null -ne $Job.PSObject.Properties['CloudFolderId']) { [string]$Job.CloudFolderId } else { '' }
        $now = [datetime]::UtcNow
        if (-not $Force -and $script:LastProgressWrite.ContainsKey($jobId) -and ($now - $script:LastProgressWrite[$jobId]).TotalMilliseconds -lt 200) { return }
        $script:LastProgressWrite[$jobId] = $now
        $percent = if ($TotalFiles -le 0) { 0 } else { [Math]::Min(100, [Math]::Max(0, [Math]::Round(($CompletedFiles * 100.0) / $TotalFiles, 1))) }
        $progress = [pscustomobject]@{
            JobId = $jobId; JobName = [string]$Job.Name; Stage = $Stage
            Detail = $Detail; CurrentFolder = $CurrentFolder
            CurrentFile = $CurrentFile; CurrentFileSize = $CurrentFileSize
            SourceLocation = [string]$Job.Source
            DestinationLocation = if ($destinationType -eq 'Local') { $destinationValue } elseif (-not [string]::IsNullOrWhiteSpace($destinationValue)) { $destinationValue } else { $cloudFolderValue }
            DestinationType = $destinationType
            CompletedFiles = $CompletedFiles; TotalFiles = $TotalFiles; Percent = $percent
            UpdatedAt = $now.ToString('o')
        }
        $path = Join-Path $script:ProgressRoot "$jobId.json"
        $tempPath = "$path.$PID.tmp"
        $progress | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $path -Force
    }
    catch {
        # Progress reporting must never stop a backup job.
    }
}
$integrityModulePath = Join-Path (Split-Path -Parent $script:ScriptPath) 'SafeSync.Integrity.ps1'
if (-not (Test-Path -LiteralPath $integrityModulePath)) { throw 'SafeSync.Integrity.ps1 모듈을 찾을 수 없습니다. ZIP의 모든 파일을 함께 압축 해제하세요.' }
. $integrityModulePath
$cloudModulePath = Join-Path (Split-Path -Parent $script:ScriptPath) 'SafeSync.Cloud.ps1'
if (Test-Path -LiteralPath $cloudModulePath) { . $cloudModulePath }

function Initialize-DataFolders {
    foreach ($path in @($script:DataRoot, $script:LogRoot, $script:ResultRoot, $script:ManifestRoot, $script:ProgressRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
    }
}

function New-DefaultConfig {
    [pscustomobject]@{
        Version = 8
        AutoStart = $true
        TrashRetentionDays = 100
        SoundOnMinimize = $false
        SoundOnBackupError = $true
        SoundOnBackupComplete = $false
        ThemeMode = 'Light'
        WindowLayout = [pscustomobject]@{
            MainWidth = 1080; MainHeight = 720; MainActivityHeight = 155
            ProgressWidth = 1180; ProgressHeight = 720; ProgressLockedHeight = 125
        }
        Jobs = @()
        CloudAccounts = [pscustomobject]@{
            Dropbox = [pscustomobject]@{ AppKey=''; RefreshTokenProtected=''; AccountName=''; AccountId='' }
            GoogleDrive = [pscustomobject]@{ ClientId=''; ClientSecretProtected=''; RefreshTokenProtected=''; AccountName=''; AccountId='' }
        }
    }
}

function Load-Config {
    Initialize-DataFolders
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        $config = New-DefaultConfig
        Save-Config $config
        return $config
    }
    try {
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $config.PSObject.Properties['Jobs']) { $config | Add-Member -NotePropertyName Jobs -NotePropertyValue @() -Force }
        if ($null -eq $config.PSObject.Properties['TrashRetentionDays']) { $config | Add-Member -NotePropertyName TrashRetentionDays -NotePropertyValue 100 -Force }
        if ($null -eq $config.PSObject.Properties['AutoStart']) { $config | Add-Member -NotePropertyName AutoStart -NotePropertyValue $true -Force }
        if ($null -eq $config.PSObject.Properties['SoundOnMinimize']) { $config | Add-Member -NotePropertyName SoundOnMinimize -NotePropertyValue $false -Force }
        if ($null -eq $config.PSObject.Properties['SoundOnBackupError']) { $config | Add-Member -NotePropertyName SoundOnBackupError -NotePropertyValue $true -Force }
        if ($null -eq $config.PSObject.Properties['SoundOnBackupComplete']) { $config | Add-Member -NotePropertyName SoundOnBackupComplete -NotePropertyValue $false -Force }
        if ($null -eq $config.PSObject.Properties['ThemeMode']) { $config | Add-Member -NotePropertyName ThemeMode -NotePropertyValue 'Light' -Force }
        elseif (@('Light','Dark') -notcontains [string]$config.ThemeMode) { $config.ThemeMode = 'Light' }
        if ($null -eq $config.PSObject.Properties['WindowLayout']) {
            $defaults = New-DefaultConfig
            $config | Add-Member -NotePropertyName WindowLayout -NotePropertyValue $defaults.WindowLayout -Force
        }
        if ($null -eq $config.PSObject.Properties['CloudAccounts']) {
            $defaults = New-DefaultConfig
            $config | Add-Member -NotePropertyName CloudAccounts -NotePropertyValue $defaults.CloudAccounts -Force
        }
        if ($null -eq $config.PSObject.Properties['Version']) { $config | Add-Member -NotePropertyName Version -NotePropertyValue 8 -Force }
        else { $config.Version = 8 }
        foreach ($job in @($config.Jobs)) {
            if ($null -ne $job -and $null -eq $job.PSObject.Properties['Paused']) {
                $job | Add-Member -NotePropertyName Paused -NotePropertyValue $false -Force
            }
        }
        return $config
    }
    catch {
        $backupPath = "$($script:ConfigPath).broken-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -LiteralPath $script:ConfigPath -Destination $backupPath -Force
        return New-DefaultConfig
    }
}

function Save-Config([object]$Config) {
    Initialize-DataFolders
    $tempPath = "$($script:ConfigPath).tmp"
    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $script:ConfigPath -Force
}

function Get-SafeSyncLayoutNumber([object]$Layout, [string]$Name, [double]$Default, [double]$Minimum, [double]$Maximum) {
    $value = $Default
    try {
        if ($null -ne $Layout -and $null -ne $Layout.PSObject.Properties[$Name]) { $value = [double]$Layout.$Name }
    } catch { $value = $Default }
    return [Math]::Min($Maximum, [Math]::Max($Minimum, $value))
}

function Test-SafeSyncSoundEnabled([ValidateSet('Minimize','BackupError','BackupComplete')][string]$SoundType) {
    if ($null -eq $script:Config) { return $true }
    $propertyName = switch ($SoundType) { 'Minimize' { 'SoundOnMinimize' } 'BackupError' { 'SoundOnBackupError' } default { 'SoundOnBackupComplete' } }
    $property = $script:Config.PSObject.Properties[$propertyName]
    return $null -eq $property -or [bool]$property.Value
}

function Play-SafeSyncNotificationSound([ValidateSet('Minimize','BackupError','BackupComplete')][string]$SoundType) {
    if (-not (Test-SafeSyncSoundEnabled $SoundType)) { return }
    try {
        if ($SoundType -eq 'BackupError') { [System.Media.SystemSounds]::Exclamation.Play() }
        else { [System.Media.SystemSounds]::Asterisk.Play() }
    }
    catch { Write-AppLog "알림음 재생 실패($SoundType): $($_.Exception.Message)" 'WARN' }
}

function Write-AppLog([string]$Message, [string]$Level = 'INFO') {
    Initialize-DataFolders
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath (Join-Path $script:LogRoot "SafeSync-$(Get-Date -Format 'yyyy-MM').log") -Value $line -Encoding UTF8
}

function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -eq $rootPath.Length) { return $rootPath }
    return $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathRelationship([string]$Source, [string]$Destination) {
    $sourcePath = Get-NormalizedPath $Source
    $destinationPath = Get-NormalizedPath $Destination
    if (-not $sourcePath.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) { $sourcePath += [System.IO.Path]::DirectorySeparatorChar }
    if (-not $destinationPath.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) { $destinationPath += [System.IO.Path]::DirectorySeparatorChar }
    return $sourcePath.StartsWith($destinationPath, [System.StringComparison]::OrdinalIgnoreCase) -or
           $destinationPath.StartsWith($sourcePath, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePath([string]$BasePath, [string]$FullPath) {
    $base = Get-NormalizedPath $BasePath
    if (-not $base.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) { $base += [System.IO.Path]::DirectorySeparatorChar }
    $baseUri = New-Object System.Uri($base)
    $fileUri = New-Object System.Uri($FullPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fileUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

function Get-SafeSyncFilesWithProgress {
    param(
        [Parameter(Mandatory=$true)][object]$Job,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)][string]$Stage,
        [string]$Detail = '폴더의 파일 목록을 확인하고 있습니다.'
    )
    if ('SafeSyncFastScanner' -as [type]) {
        $progressCallback = [Action[string]]{
            param([string]$folderPath)
            $relativeFolder = if ($folderPath.Length -le $Root.Length) { '(최상위 폴더)' } else { $folderPath.Substring($Root.Length).TrimStart('\','/') }
            if ([string]::IsNullOrWhiteSpace($relativeFolder)) { $relativeFolder = '(최상위 폴더)' }
            Write-SafeSyncProgress -Job $Job -Stage $Stage -Detail $Detail -CurrentFolder $relativeFolder
        }
        return [SafeSyncFastScanner]::EnumerateFiles($Root, $progressCallback)
    }
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $folders = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $folders.Push((Get-Item -LiteralPath $Root -Force -ErrorAction Stop))
    while ($folders.Count -gt 0) {
        $folder = $folders.Pop()
        $relativeFolder = if ($folder.FullName.Length -le $Root.Length) { '' } else { $folder.FullName.Substring($Root.Length).TrimStart('\','/') }
        if ([string]::IsNullOrWhiteSpace($relativeFolder)) { $relativeFolder = '(최상위 폴더)' }
        Write-SafeSyncProgress -Job $Job -Stage $Stage -Detail $Detail -CurrentFolder $relativeFolder
        foreach ($file in @($folder.GetFiles())) {
            if (-not (Test-SafeSyncInternalPath $file.FullName)) { $files.Add($file) }
        }
        foreach ($child in @($folder.GetDirectories())) {
            if (-not (Test-SafeSyncInternalPath $child.FullName)) { $folders.Push($child) }
        }
    }
    return $files.ToArray()
}

function Move-ToSafeTrash {
    param(
        [Parameter(Mandatory=$true)][string]$DestinationRoot,
        [Parameter(Mandatory=$true)][string]$ItemPath,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [string]$Reason = 'deleted'
    )
    if (-not (Test-Path -LiteralPath $ItemPath)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $trashBase = Join-Path $DestinationRoot '.safesync-trash'
    $target = Join-Path (Join-Path $trashBase "$stamp-$Reason") $RelativePath
    if (Test-Path -LiteralPath $target) {
        $target = "$target-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    Move-Item -LiteralPath $ItemPath -Destination $target -Force
    return $target
}

function Remove-ExpiredTrash([string]$DestinationRoot, [int]$RetentionDays) {
    $trashRoot = Join-Path $DestinationRoot '.safesync-trash'
    if (-not (Test-Path -LiteralPath $trashRoot)) { return 0 }
    $cutoff = (Get-Date).AddDays(-[Math]::Max(1, $RetentionDays))
    $removed = 0
    Get-ChildItem -LiteralPath $trashRoot -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -lt $cutoff } |
        ForEach-Object {
            if ($_.PSIsContainer) {
                $removed += (Get-ChildItem -LiteralPath $_.FullName -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
    return $removed
}

function Copy-FileToSafeTrash {
    param(
        [Parameter(Mandatory=$true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory=$true)][string]$DestinationRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [string]$Reason = 'backup-deleted'
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $trashBase = Join-Path $DestinationRoot '.safesync-trash'
    $target = Join-Path (Join-Path $trashBase "$stamp-$Reason") $RelativePath
    if (Test-Path -LiteralPath $target) {
        $target = "$target-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    Copy-FileSafely -SourceFile $SourceFile -DestinationPath $target -DestinationRoot $DestinationRoot -RelativePath (Get-RelativePath $DestinationRoot $target)
    return $target
}

function Get-LocalManifestPath([string]$JobId) {
    $safeJobId = $JobId -replace '[^a-zA-Z0-9_.-]', '_'
    return Join-Path $script:ManifestRoot "$safeJobId.json"
}

function Get-LocalBackupManifest([string]$JobId) {
    $manifest = @{}
    $path = Get-LocalManifestPath $JobId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $manifest }
    try {
        foreach ($entry in @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)) {
            if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.RelativePath)) {
                $manifest[([string]$entry.RelativePath).ToLowerInvariant()] = $entry
            }
        }
    }
    catch {
        Write-AppLog "백업 기록을 읽지 못했습니다 ($JobId): $($_.Exception.Message)" 'WARN'
    }
    return $manifest
}

function Save-LocalBackupManifest([string]$JobId, [string]$DestinationRoot) {
    Initialize-DataFolders
    $trashRoot = Join-Path $DestinationRoot '.safesync-trash'
    $entries = @(
        Get-ChildItem -LiteralPath $DestinationRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-SafeSyncInternalPath $_.FullName) } |
            ForEach-Object {
                [pscustomobject]@{
                    RelativePath = Get-RelativePath $DestinationRoot $_.FullName
                    Length = $_.Length
                    CreationTimeUtc = $_.CreationTimeUtc.ToString('o')
                    LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
                }
            }
    )
    $path = Get-LocalManifestPath $JobId
    $tempPath = "$path.tmp"
    ConvertTo-Json -InputObject ([object[]]$entries) -Depth 4 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $path -Force
}

function Get-SafeSyncStatePath([string]$JobId) {
    $safeJobId = $JobId -replace '[^a-zA-Z0-9_.-]', '_'
    return Join-Path $script:ManifestRoot "$safeJobId.sync.json"
}

function New-SafeSyncState([string]$JobId) {
    return [pscustomobject]@{
        JobId = $JobId
        Generation = ''
        Exists = $false
        LastFullScanUtc = ''
        LastRunUtc = ''
        FullScanRequired = $false
        CheckpointActive = $false
        CheckpointFullScan = $false
        DropboxCursor = ''
        GoogleChangeToken = ''
        UsnInitialized = $false
        UsnSupported = $false
        UsnJournalId = 0
        UsnNext = 0
        UsnVolumeRoot = ''
        PendingPaths = @()
        Entries = @{}
    }
}

function Get-SafeSyncState([string]$JobId) {
    $state = New-SafeSyncState $JobId
    $path = Get-SafeSyncStatePath $JobId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $state }
    try {
        $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.Exists = $true
        if ($null -ne $saved.PSObject.Properties['Generation']) { $state.Generation = [string]$saved.Generation }
        if ($null -ne $saved.PSObject.Properties['LastFullScanUtc']) { $state.LastFullScanUtc = [string]$saved.LastFullScanUtc }
        if ($null -ne $saved.PSObject.Properties['LastRunUtc']) { $state.LastRunUtc = [string]$saved.LastRunUtc }
        if ($null -ne $saved.PSObject.Properties['FullScanRequired']) { $state.FullScanRequired = [bool]$saved.FullScanRequired }
        if ($null -ne $saved.PSObject.Properties['CheckpointActive']) { $state.CheckpointActive = [bool]$saved.CheckpointActive }
        if ($null -ne $saved.PSObject.Properties['CheckpointFullScan']) { $state.CheckpointFullScan = [bool]$saved.CheckpointFullScan }
        if ($null -ne $saved.PSObject.Properties['DropboxCursor']) { $state.DropboxCursor = [string]$saved.DropboxCursor }
        if ($null -ne $saved.PSObject.Properties['GoogleChangeToken']) { $state.GoogleChangeToken = [string]$saved.GoogleChangeToken }
        if ($null -ne $saved.PSObject.Properties['UsnInitialized']) { $state.UsnInitialized = [bool]$saved.UsnInitialized }
        if ($null -ne $saved.PSObject.Properties['UsnSupported']) { $state.UsnSupported = [bool]$saved.UsnSupported }
        if ($null -ne $saved.PSObject.Properties['UsnJournalId']) { $state.UsnJournalId = [long]$saved.UsnJournalId }
        if ($null -ne $saved.PSObject.Properties['UsnNext']) { $state.UsnNext = [long]$saved.UsnNext }
        if ($null -ne $saved.PSObject.Properties['UsnVolumeRoot']) { $state.UsnVolumeRoot = [string]$saved.UsnVolumeRoot }
        if ($null -ne $saved.PSObject.Properties['PendingPaths']) { $state.PendingPaths = @($saved.PendingPaths) }
        if ($null -ne $saved.PSObject.Properties['Files']) {
            foreach ($entry in @($saved.Files)) {
                if ($null -ne $entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.RelativePath)) {
                    $key = ([string]$entry.RelativePath).Replace('\','/').TrimStart('/').ToLowerInvariant()
                    $state.Entries[$key] = $entry
                }
            }
        }
        $checkpointFolder = "$path.checkpoints"
        if (Test-Path -LiteralPath $checkpointFolder -PathType Container) {
            $pending = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($relative in @($state.PendingPaths)) { [void]$pending.Add([string]$relative) }
            foreach ($segment in @(Get-ChildItem -LiteralPath $checkpointFolder -Filter '*.json' -File | Sort-Object Name)) {
                $delta = Get-Content -LiteralPath $segment.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$delta.Generation -ne [string]$state.Generation) { continue }
                foreach ($entry in @($delta.Entries)) { $state.Entries[([string]$entry.RelativePath).ToLowerInvariant()] = $entry }
                foreach ($key in @($delta.RemovedKeys)) { $state.Entries.Remove([string]$key) }
                foreach ($relative in @($delta.CompletedPaths)) { [void]$pending.Remove([string]$relative) }
            }
            $state.PendingPaths = @($pending)
        }
    }
    catch {
        Write-AppLog "증분 스냅샷을 읽지 못했습니다 ($JobId). 안전을 위해 전체 검사를 실행합니다: $($_.Exception.Message)" 'WARN'
        $state.FullScanRequired = $true
    }
    return $state
}

function Save-SafeSyncState([object]$State) {
    Initialize-DataFolders
    $path = Get-SafeSyncStatePath ([string]$State.JobId)
    $tempPath = "$path.$PID.tmp"
    $checkpointFolder = "$path.checkpoints"
    $oldSegments = if (Test-Path -LiteralPath $checkpointFolder -PathType Container) { @(Get-ChildItem -LiteralPath $checkpointFolder -Filter '*.json' -File) } else { @() }
    $generation = [guid]::NewGuid().ToString('N')
    $files = @($State.Entries.Values | Sort-Object RelativePath)
    $saved = [pscustomobject]@{
        Version = 2
        Generation = $generation
        JobId = [string]$State.JobId
        LastFullScanUtc = [string]$State.LastFullScanUtc
        LastRunUtc = [string]$State.LastRunUtc
        FullScanRequired = [bool]$State.FullScanRequired
        CheckpointActive = [bool]$State.CheckpointActive
        CheckpointFullScan = [bool]$State.CheckpointFullScan
        DropboxCursor = [string]$State.DropboxCursor
        GoogleChangeToken = [string]$State.GoogleChangeToken
        UsnInitialized = [bool]$State.UsnInitialized
        UsnSupported = [bool]$State.UsnSupported
        UsnJournalId = [long]$State.UsnJournalId
        UsnNext = [long]$State.UsnNext
        UsnVolumeRoot = [string]$State.UsnVolumeRoot
        PendingPaths = @($State.PendingPaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
        Files = [object[]]$files
    }
    $saved | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $path -Force
    $State.Exists = $true
    if ($null -eq $State.PSObject.Properties['Generation']) { $State | Add-Member -NotePropertyName Generation -NotePropertyValue $generation } else { $State.Generation = $generation }
    # Delete only segments observed before this save; a new generation makes
    # old segments harmless even after a crash between replacement and cleanup.
    foreach ($segment in $oldSegments) { Remove-Item -LiteralPath $segment.FullName -Force -ErrorAction SilentlyContinue }
}

function Save-SafeSyncCheckpoint([object]$State, [string[]]$CompletedPaths) {
    if (@($CompletedPaths).Count -eq 0) { return }
    if ($null -eq $State.PSObject.Properties['Generation'] -or [string]::IsNullOrWhiteSpace([string]$State.Generation)) { Save-SafeSyncState $State; return }
    $entries = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($relative in $CompletedPaths) {
        $key = $relative.ToLowerInvariant()
        if ($State.Entries.ContainsKey($key)) { $entries.Add($State.Entries[$key]) } else { $removed.Add($key) }
    }
    $folder = (Get-SafeSyncStatePath ([string]$State.JobId)) + '.checkpoints'
    [void][System.IO.Directory]::CreateDirectory($folder)
    $path = Join-Path $folder ('{0:D19}-{1}.json' -f [datetime]::UtcNow.Ticks, [guid]::NewGuid().ToString('N'))
    $record = [pscustomobject]@{Generation=[string]$State.Generation;CompletedPaths=[string[]]$CompletedPaths;Entries=$entries.ToArray();RemovedKeys=$removed.ToArray()}
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 8 -Compress))
    $stream = [System.IO.File]::Open("$path.tmp", 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    [System.IO.File]::Move("$path.tmp", $path)
}

function ConvertTo-SafeSyncRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Replace('\','/').TrimStart('/')
}

function Set-SafeSyncStateEntry {
    param(
        [Parameter(Mandatory=$true)][object]$State,
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory=$true)][ValidateSet('BackedUp','Failed','Conflict','Locked')][string]$Status,
        [string]$ErrorMessage = '',
        [string]$RemoteId = '',
        [string]$RemoteParentId = ''
    )
    $relative = ConvertTo-SafeSyncRelativePath $RelativePath
    $key = $relative.ToLowerInvariant()
    $existing = if ($State.Entries.ContainsKey($key)) { $State.Entries[$key] } else { $null }
    if ([string]::IsNullOrWhiteSpace($RemoteId) -and $null -ne $existing -and $null -ne $existing.PSObject.Properties['RemoteId']) { $RemoteId = [string]$existing.RemoteId }
    if ([string]::IsNullOrWhiteSpace($RemoteParentId) -and $null -ne $existing -and $null -ne $existing.PSObject.Properties['RemoteParentId']) { $RemoteParentId = [string]$existing.RemoteParentId }
    $fileId = if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['FileId']) { [long]$existing.FileId } else { 0 }
    if ($null -ne $File -and 'SafeSyncUsnJournalWorker' -as [type]) {
        try { $fileId = [SafeSyncUsnJournalWorker]::GetFileId([string]$File.FullName) } catch {}
    }
    $lockedSince = if ($Status -eq 'Locked' -and $null -ne $existing -and [string]$existing.Status -eq 'Locked' -and $null -ne $existing.PSObject.Properties['LockedSinceUtc']) { [string]$existing.LockedSinceUtc } elseif ($Status -eq 'Locked') { [datetime]::UtcNow.ToString('o') } else { '' }
    $lockRetryCount = if ($Status -eq 'Locked' -and $null -ne $existing -and $null -ne $existing.PSObject.Properties['LockRetryCount']) { [int]$existing.LockRetryCount + 1 } elseif ($Status -eq 'Locked') { 1 } else { 0 }
    $State.Entries[$key] = [pscustomobject]@{
        RelativePath = $relative
        Length = if ($null -ne $File) { [long]$File.Length } elseif ($null -ne $existing) { [long]$existing.Length } else { 0 }
        CreationTimeUtc = if ($null -ne $File) { $File.CreationTimeUtc.ToString('o') } elseif ($null -ne $existing) { [string]$existing.CreationTimeUtc } else { '' }
        LastWriteTimeUtc = if ($null -ne $File) { $File.LastWriteTimeUtc.ToString('o') } elseif ($null -ne $existing) { [string]$existing.LastWriteTimeUtc } else { '' }
        Status = $Status
        LastError = $ErrorMessage
        LastAttemptUtc = [datetime]::UtcNow.ToString('o')
        LockedSinceUtc = $lockedSince
        LockRetryCount = $lockRetryCount
        FileId = $fileId
        RemoteId = $RemoteId
        RemoteParentId = $RemoteParentId
    }
}

function Remove-SafeSyncStateEntry([object]$State, [string]$RelativePath) {
    $key = (ConvertTo-SafeSyncRelativePath $RelativePath).ToLowerInvariant()
    if ($State.Entries.ContainsKey($key)) { $State.Entries.Remove($key) }
}

function Get-SafeSyncBackupPlan([object]$Job, [string]$SourceRoot, [switch]$ForceFull) {
    $state = Get-SafeSyncState ([string]$Job.Id)
    $lastFull = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace([string]$state.LastFullScanUtc)) { [void][datetime]::TryParse([string]$state.LastFullScanUtc, [ref]$lastFull) }
    if (-not $ForceFull -and [bool]$state.CheckpointActive) {
        return [pscustomobject]@{ State=$state; FullScan=$false; Paths=@($state.PendingPaths | ForEach-Object { ConvertTo-SafeSyncRelativePath ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique); Checkpoint=$true }
    }
    $full = $ForceFull -or -not $state.Exists -or [bool]$state.FullScanRequired -or $lastFull -eq [datetime]::MinValue -or ([datetime]::UtcNow - $lastFull.ToUniversalTime()).TotalDays -ge 7
    $paths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not $full) {
        $requested = New-Object System.Collections.Generic.List[string]
        $requestedDirectories = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @($state.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $requested.Add((ConvertTo-SafeSyncRelativePath ([string]$path))) } }
        foreach ($entry in @($state.Entries.Values)) { if ([string]$entry.Status -eq 'Failed') { $requested.Add([string]$entry.RelativePath) } }
        foreach ($relative in @($requested | Sort-Object -Unique)) {
            $key = $relative.ToLowerInvariant()
            if ($state.Entries.ContainsKey($key)) {
                # Snapshot entries are files, so retry them directly. Avoiding a
                # network Test-Path for every failed file makes large NAS/Drive
                # restart queues inexpensive to prepare.
                $paths[$relative] = $relative
                continue
            }
            $localPath = Join-Path $SourceRoot $relative.Replace('/','\')
            if (Test-Path -LiteralPath $localPath -PathType Container -ErrorAction SilentlyContinue) {
                [void]$requestedDirectories.Add($relative.TrimEnd('/'))
                foreach ($file in @(Get-ChildItem -LiteralPath $localPath -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not (Test-SafeSyncInternalPath $_.FullName) })) {
                    $child = ConvertTo-SafeSyncRelativePath ($file.FullName.Substring($SourceRoot.Length).TrimStart('\','/'))
                    $paths[$child] = $child
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($relative)) {
                $paths[$relative] = $relative
                [void]$requestedDirectories.Add($relative.TrimEnd('/'))
            }
        }
        if ($requestedDirectories.Count -gt 0) {
            # Scan the saved snapshot once and walk each saved path's ancestors.
            # The former per-request full snapshot scan became extremely slow when
            # thousands of pending paths were restored after an interrupted run.
            foreach ($entry in @($state.Entries.Values)) {
                $savedRelative = ConvertTo-SafeSyncRelativePath ([string]$entry.RelativePath)
                $ancestor = [string][System.IO.Path]::GetDirectoryName($savedRelative.Replace('/','\'))
                while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
                    $ancestor = $ancestor.Replace('\','/')
                    if ($requestedDirectories.Contains($ancestor)) { $paths[$savedRelative] = $savedRelative; break }
                    $ancestor = [string][System.IO.Path]::GetDirectoryName($ancestor.Replace('/','\'))
                }
            }
        }
    }
    return [pscustomobject]@{ State=$state; FullScan=[bool]$full; Paths=@($paths.Values | Sort-Object); Checkpoint=$false }
}

function Test-SafeSyncStartupReconciliationRequired([object]$Job) {
    $state = Get-SafeSyncState ([string]$Job.Id)
    if (-not $state.Exists -or [bool]$state.FullScanRequired) { return $true }
    $lastFull = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace([string]$state.LastFullScanUtc)) { [void][datetime]::TryParse([string]$state.LastFullScanUtc, [ref]$lastFull) }
    return $lastFull -eq [datetime]::MinValue -or ([datetime]::UtcNow - $lastFull.ToUniversalTime()).TotalDays -ge 7
}

function Queue-SafeSyncSnapshotRetries([object]$Job) {
    $state = Get-SafeSyncState ([string]$Job.Id)
    $paths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($state.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $paths[[string]$path] = [string]$path } }
    foreach ($entry in @($state.Entries.Values | Where-Object { [string]$_.Status -eq 'Failed' })) { $paths[[string]$entry.RelativePath] = [string]$entry.RelativePath }
    if ($paths.Count -gt 0) {
        $script:PendingChanges[[string]$Job.Id] = Get-Date
        Add-Activity "'$($Job.Name)' 저장된 스냅샷에서 재시도할 파일 $($paths.Count)개를 예약했습니다."
    }
}

function Invoke-SafeSyncStartupReconciliation([object]$Job, [switch]$ForceMetadata) {
    $jobId = [string]$Job.Id
    $state = Get-SafeSyncState $jobId
    $changes = New-Object System.Collections.Generic.List[object]
    $pending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($state.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $pending[[string]$path] = [string]$path } }
    $result = [ordered]@{ JobId=$jobId; JobName=[string]$Job.Name; FullScanRequired=$false; SourceUnavailable=$false; Changes=@(); Error='' }
    try {
        $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
        $snapshotDetail = if ($destinationType -eq 'GoogleDrive') { '저장된 스냅샷과 원본의 경로·시간·크기만 대조합니다. Google Drive 전체 목록은 다시 읽지 않습니다.' } elseif ($destinationType -eq 'Dropbox') { '저장된 스냅샷과 원본의 경로·시간·크기만 대조합니다. Dropbox 전체 목록은 다시 읽지 않습니다.' } else { '저장된 스냅샷과 원본의 경로·시간·크기만 대조합니다.' }
        Write-SafeSyncProgress -Job $Job -Stage '시작 스냅샷 대조 중' -Detail $snapshotDetail -CurrentFolder ([string]$Job.Source) -Force
        if (-not (Test-Path -LiteralPath $Job.Source -PathType Container)) {
            $state.FullScanRequired = $true
            Save-SafeSyncState $state
            $result.FullScanRequired = $true
            $result.SourceUnavailable = $true
            return [pscustomobject]$result
        }
        $lastFull = [datetime]::MinValue
        if (-not [string]::IsNullOrWhiteSpace([string]$state.LastFullScanUtc)) { [void][datetime]::TryParse([string]$state.LastFullScanUtc, [ref]$lastFull) }
        if (-not $ForceMetadata -and (-not $state.Exists -or [bool]$state.FullScanRequired -or $lastFull -eq [datetime]::MinValue -or ([datetime]::UtcNow-$lastFull.ToUniversalTime()).TotalDays -ge 7)) {
            $state.FullScanRequired = $true
            Save-SafeSyncState $state
            $result.FullScanRequired = $true
            return [pscustomobject]$result
        }
        $sourceRoot = Get-NormalizedPath ([string]$Job.Source)
        $seen = @{}
        foreach ($file in @(Get-SafeSyncFilesWithProgress -Job $Job -Root $sourceRoot -Stage '시작 스냅샷 대조 중' -Detail $snapshotDetail)) {
            $relative = ConvertTo-SafeSyncRelativePath ($file.FullName.Substring($sourceRoot.Length).TrimStart('\','/'))
            $key = $relative.ToLowerInvariant()
            $seen[$key] = $true
            $changed = -not $state.Entries.ContainsKey($key)
            if (-not $changed) {
                $entry = $state.Entries[$key]
                $savedModified = [datetime]::MinValue
                [void][datetime]::TryParse([string]$entry.LastWriteTimeUtc, [ref]$savedModified)
                $changed = [string]$entry.Status -eq 'Failed' -or [long]$entry.Length -ne $file.Length -or $savedModified -eq [datetime]::MinValue -or [Math]::Abs(($file.LastWriteTimeUtc-$savedModified.ToUniversalTime()).TotalSeconds) -gt 2
            }
            if ($changed) { $pending[$relative] = $relative; $changes.Add([pscustomobject]@{Side='S';RelativePath=$relative}) }
        }
        foreach ($entry in @($state.Entries.Values)) {
            $relative = [string]$entry.RelativePath
            $key = $relative.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $pending[$relative] = $relative
                $changes.Add([pscustomobject]@{Side='S';RelativePath=$relative})
                continue
            }
            if ($destinationType -eq 'Local' -and [string]$entry.Status -eq 'BackedUp') {
                $destinationPath = Join-Path ([string]$Job.Destination) $relative.Replace('/','\')
                if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                    $pending[$relative] = $relative
                    $changes.Add([pscustomobject]@{Side='D';RelativePath=$relative})
                }
            }
        }
        $state.PendingPaths = @($pending.Values)
        if ($ForceMetadata) { $state.FullScanRequired = $false }
        if ($null -ne (Get-Command Set-SafeSyncUsnCursor -ErrorAction SilentlyContinue)) { [void](Set-SafeSyncUsnCursor $Job $state) }
        Save-SafeSyncState $state
        $result.Changes = $changes.ToArray()
    }
    catch { $result.Error = $_.Exception.Message }
    return [pscustomobject]$result
}

function Write-SafeSyncReconciliationResult([object]$Result) {
    Initialize-DataFolders
    $path = Join-Path $script:ResultRoot "reconcile-$($Result.JobId).json"
    $tempPath = "$path.$PID.tmp"
    $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $path -Force
}

function Copy-FileSafely {
    param(
        [Parameter(Mandatory=$true)][System.IO.FileInfo]$SourceFile,
        [Parameter(Mandatory=$true)][string]$DestinationPath,
        [Parameter(Mandatory=$true)][string]$DestinationRoot,
        [Parameter(Mandatory=$true)][string]$RelativePath
    )
    $parent = Split-Path -Parent $DestinationPath
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    $tempPath = "$DestinationPath.safesync-part-$([guid]::NewGuid().ToString('N'))"
    $snapshot = New-SafeSyncSnapshot -File $SourceFile -StagedPath $tempPath
    Publish-SafeSyncLocalSnapshot -Snapshot $snapshot -Destination $DestinationPath -Root $DestinationRoot -Relative $RelativePath
}

function Get-SafeSyncConflictSiblingPath([string]$DestinationPath) {
    $directory = [System.IO.Path]::GetDirectoryName($DestinationPath)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($DestinationPath)
    $extension = [System.IO.Path]::GetExtension($DestinationPath)
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $candidate = Join-Path $directory "$baseName.SafeSync-conflict-$stamp$extension"
    $counter = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $directory "$baseName.SafeSync-conflict-$stamp-$counter$extension"
        $counter++
    }
    return $candidate
}

function Invoke-LocalBackupJob {
    param(
        [Parameter(Mandatory=$true)][object]$Job,
        [int]$TrashRetentionDays = 100,
        [switch]$ForceFull,
        [string[]]$ForceOverwritePaths = @(),
        [string[]]$RenameExistingPaths = @()
    )
    $started = Get-Date
    $result = [ordered]@{
        JobId = [string]$Job.Id
        JobName = [string]$Job.Name
        StartedAt = $started.ToString('o')
        FinishedAt = $null
        Status = 'Running'
        Copied = 0
        Skipped = 0
        Trashed = 0
        RenamedBackups = 0
        ExpiredTrashRemoved = 0
        Conflicts = @()
        Errors = @()
        LockedFiles = @()
        ScanMode = ''
    }
    $state = $null
    try {
        $sourceRoot = Get-NormalizedPath ([string]$Job.Source)
        $destinationRoot = Get-NormalizedPath ([string]$Job.Destination)
        Write-SafeSyncProgress -Job $Job -Stage '로컬 백업 준비 중' -Detail '원본과 백업 위치에 접근할 수 있는지 확인하고 있습니다.' -CurrentFolder $sourceRoot -Force
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "원본 위치에 접근할 수 없습니다: $sourceRoot" }
        if (-not (Test-Path -LiteralPath $destinationRoot)) { [void](New-Item -ItemType Directory -Path $destinationRoot -Force) }
        if (Test-PathRelationship $sourceRoot $destinationRoot) { throw '원본과 백업 위치는 서로의 하위 폴더일 수 없습니다.' }
        Write-SafeSyncProgress -Job $Job -Stage '이전 작업 복구 확인 중' -Detail '중단된 파일 교체가 있는지 백업 위치를 확인하고 있습니다.' -CurrentFolder $destinationRoot -Force
        Repair-SafeSyncLocalTransactions $destinationRoot

        Write-SafeSyncProgress -Job $Job -Stage 'Preparing saved changes' -Detail '스냅샷에서 변경되었거나 이전에 실패한 파일을 모으고 있습니다.' -CurrentFolder $sourceRoot -Force
        $plan = Get-SafeSyncBackupPlan -Job $Job -SourceRoot $sourceRoot -ForceFull:$ForceFull
        $forced = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($forcedPath in @($ForceOverwritePaths)) {
            $normalizedForced = ConvertTo-SafeSyncRelativePath ([string]$forcedPath)
            if (-not [string]::IsNullOrWhiteSpace($normalizedForced)) { $forced[$normalizedForced] = $normalizedForced }
        }
        $renameExisting = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($renamePath in @($RenameExistingPaths)) {
            $normalizedRename = ConvertTo-SafeSyncRelativePath ([string]$renamePath)
            if (-not [string]::IsNullOrWhiteSpace($normalizedRename)) {
                $renameExisting[$normalizedRename] = $normalizedRename
                $forced[$normalizedRename] = $normalizedRename
            }
        }
        $state = $plan.State
        $result.ScanMode = if ($plan.FullScan) { 'Full' } else { 'Incremental' }
        Write-SafeSyncProgress -Job $Job -Stage $(if ($plan.FullScan) { '전체 파일 목록 확인 중' } else { '변경 파일 준비 중' }) -Detail $(if($plan.FullScan){'원본 폴더를 차례로 확인하고 있습니다.'}else{'변경되었거나 이전에 실패한 파일을 준비하고 있습니다.'}) -CurrentFolder $sourceRoot -Force
        $sourceFiles = if ($plan.FullScan) {
            @(Get-SafeSyncFilesWithProgress -Job $Job -Root $sourceRoot -Stage '전체 파일 목록 확인 중' -Detail '현재 폴더에서 백업할 파일을 찾고 있습니다.')
        } else { @() }
        $workPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        if ($plan.FullScan) {
            foreach ($file in $sourceFiles) { $relative = ConvertTo-SafeSyncRelativePath ($file.FullName.Substring($sourceRoot.Length).TrimStart('\','/')); $workPaths[$relative] = $relative }
            foreach ($entry in @($state.Entries.Values)) { $relative = [string]$entry.RelativePath; if (-not $workPaths.ContainsKey($relative)) { $workPaths[$relative] = $relative } }
        }
        else { foreach ($relative in @($plan.Paths)) { $workPaths[[string]$relative] = [string]$relative } }
        foreach ($relative in @($forced.Values)) { $workPaths[[string]$relative] = [string]$relative }
        $checkpointPending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($relative in @($workPaths.Values | Sort-Object)) { $checkpointPending[[string]$relative] = [string]$relative }
        $state.PendingPaths = @($checkpointPending.Values)
        $state.CheckpointActive = $true
        $state.CheckpointFullScan = [bool]$plan.FullScan
        Save-SafeSyncState $state
        $sourceMap = @{}
        $progressIndex = 0
        foreach ($relative in @($workPaths.Values | Sort-Object)) {
            $progressIndex++
            $sourcePath = Join-Path $sourceRoot $relative.Replace('/','\')
            $sourceFile = if (Test-Path -LiteralPath $sourcePath -PathType Leaf) { Get-Item -LiteralPath $sourcePath -Force } else { $null }
            $currentFolder = [string][System.IO.Path]::GetDirectoryName($relative)
            if ([string]::IsNullOrWhiteSpace($currentFolder)) { $currentFolder = '(최상위 폴더)' }
            Write-SafeSyncProgress -Job $Job -Stage '파일 비교 및 백업 중' -Detail '원본과 백업 파일의 시간·크기를 비교하고 필요한 파일을 안전하게 복사합니다.' -CurrentFolder $currentFolder -CurrentFile $relative -CurrentFileSize $(if($null -ne $sourceFile){$sourceFile.Length}else{0}) -CompletedFiles ($progressIndex - 1) -TotalFiles $workPaths.Count
            $destinationPath = Join-Path $destinationRoot $relative
            try {
                if ($null -eq $sourceFile) {
                    if ([bool]$Job.MirrorDeletes -and (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                        [void](Move-ToSafeTrash -DestinationRoot $destinationRoot -ItemPath $destinationPath -RelativePath $relative -Reason 'deleted')
                        $result.Trashed++
                    }
                    Remove-SafeSyncStateEntry $state $relative
                    continue
                }
                $sourceMap[$relative.ToLowerInvariant()] = $true
                if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                    $manifestKey = $relative.ToLowerInvariant()
                    if ($state.Entries.ContainsKey($manifestKey)) {
                        try {
                            [void](Copy-FileToSafeTrash -SourceFile $sourceFile -DestinationRoot $destinationRoot -RelativePath $relative -Reason 'backup-deleted')
                            $result.Trashed++
                        }
                        catch {
                            $result.Errors += "$relative : 삭제된 백업 파일의 휴지통 사본 생성 실패 - $($_.Exception.Message)"
                        }
                    }
                    Copy-FileSafely -SourceFile $sourceFile -DestinationPath $destinationPath -DestinationRoot $destinationRoot -RelativePath $relative
                    $result.Copied++
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status BackedUp
                    continue
                }
                $destinationFile = Get-Item -LiteralPath $destinationPath -Force
                $sameCreation = [Math]::Abs(($sourceFile.CreationTimeUtc - $destinationFile.CreationTimeUtc).TotalSeconds) -le 2
                $sameModified = [Math]::Abs(($sourceFile.LastWriteTimeUtc - $destinationFile.LastWriteTimeUtc).TotalSeconds) -le 2
                $sameSize = $sourceFile.Length -eq $destinationFile.Length

                if ($forced.ContainsKey($relative)) {
                    $keepExisting = $renameExisting.ContainsKey($relative)
                    $renamedPath = ''
                    Write-SafeSyncProgress -Job $Job -Stage '충돌 파일 백업 중' -Detail $(if($keepExisting){'현재 백업 파일을 다른 이름으로 보관한 뒤 원본 파일을 안전하게 복사하고 있습니다.'}else{'사용자가 선택한 원본 파일로 기존 백업을 안전하게 교체하고 있습니다.'}) -CurrentFolder $currentFolder -CurrentFile $relative -CurrentFileSize $sourceFile.Length -CompletedFiles ($progressIndex - 1) -TotalFiles $workPaths.Count -Force
                    if ($keepExisting) {
                        $renamedPath = Get-SafeSyncConflictSiblingPath $destinationPath
                        Move-Item -LiteralPath $destinationPath -Destination $renamedPath
                    }
                    try {
                        Copy-FileSafely -SourceFile $sourceFile -DestinationPath $destinationPath -DestinationRoot $destinationRoot -RelativePath $relative
                    }
                    catch {
                        if ($keepExisting -and -not [string]::IsNullOrWhiteSpace($renamedPath) -and (Test-Path -LiteralPath $renamedPath -PathType Leaf) -and -not (Test-Path -LiteralPath $destinationPath)) {
                            Move-Item -LiteralPath $renamedPath -Destination $destinationPath
                        }
                        throw
                    }
                    $result.Copied++
                    if ($keepExisting) { $result.RenamedBackups++ }
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status BackedUp
                }
                elseif ($sameCreation -and $sameModified -and $sameSize) {
                    $result.Skipped++
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status BackedUp
                }
                elseif ($sourceFile.LastWriteTimeUtc -gt $destinationFile.LastWriteTimeUtc.AddSeconds(2)) {
                    Copy-FileSafely -SourceFile $sourceFile -DestinationPath $destinationPath -DestinationRoot $destinationRoot -RelativePath $relative
                    $result.Copied++
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status BackedUp
                }
                elseif ($sameModified -and -not $sameSize) {
                    $result.Conflicts += [pscustomobject]@{
                        File = $relative
                        Reason = '수정 시간은 같지만 크기가 다릅니다.'
                        SourceSize = $sourceFile.Length
                        BackupSize = $destinationFile.Length
                        SourceModified = $sourceFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                        BackupModified = $destinationFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status Conflict
                }
                elseif ($destinationFile.LastWriteTimeUtc -gt $sourceFile.LastWriteTimeUtc.AddSeconds(2)) {
                    $result.Conflicts += [pscustomobject]@{
                        File = $relative
                        Reason = '백업 위치의 파일이 원본보다 최신입니다.'
                        SourceSize = $sourceFile.Length
                        BackupSize = $destinationFile.Length
                        SourceModified = $sourceFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                        BackupModified = $destinationFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status Conflict
                }
                elseif (-not $sameSize) {
                    $result.Conflicts += [pscustomobject]@{
                        File = $relative
                        Reason = '시간 정보가 비슷하지만 크기가 다릅니다.'
                        SourceSize = $sourceFile.Length
                        BackupSize = $destinationFile.Length
                        SourceModified = $sourceFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                        BackupModified = $destinationFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                    }
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status Conflict
                }
                else {
                    $result.Skipped++
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status BackedUp
                }
            }
            catch {
                if (Test-SafeSyncFileInUseError $_) {
                    Add-SafeSyncLockedFile $result $relative $_
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status Locked -ErrorMessage $_.Exception.Message
                }
                else {
                    $result.Errors += "$relative : $($_.Exception.Message)"
                    Set-SafeSyncStateEntry -State $state -RelativePath $relative -File $sourceFile -Status Failed -ErrorMessage $_.Exception.Message
                }
            }
            finally {
                [void]$checkpointPending.Remove([string]$relative)
                $state.PendingPaths = @($checkpointPending.Values)
                # Persist a small resumable checkpoint periodically. A file that
                # was in flight at interruption is retried safely on the next run.
                if (($progressIndex % 5) -eq 0 -or $checkpointPending.Count -eq 0) { Save-SafeSyncState $state }
            }
        }

        Write-SafeSyncProgress -Job $Job -Stage '삭제 파일과 휴지통 정리 중' -Detail '삭제된 백업 파일을 SafeSync 휴지통으로 옮기고 보관 기간을 확인합니다.' -CurrentFolder $destinationRoot -CompletedFiles $workPaths.Count -TotalFiles $workPaths.Count -Force
        $completedFullScan = [bool]$plan.FullScan -or [bool]$state.CheckpointFullScan
        if ($completedFullScan -and [bool]$Job.MirrorDeletes) {
            Get-ChildItem -LiteralPath $destinationRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-SafeSyncInternalPath $_.FullName) } |
                ForEach-Object {
                    $relative = ConvertTo-SafeSyncRelativePath (Get-RelativePath $destinationRoot $_.FullName)
                    if (-not $sourceMap.ContainsKey($relative.ToLowerInvariant())) {
                        try {
                            [void](Move-ToSafeTrash -DestinationRoot $destinationRoot -ItemPath $_.FullName -RelativePath $relative -Reason 'deleted')
                            $result.Trashed++
                            Remove-SafeSyncStateEntry $state $relative
                        }
                        catch { $result.Errors += "$relative : 휴지통 이동 실패 - $($_.Exception.Message)"; Set-SafeSyncStateEntry -State $state -RelativePath $relative -Status Failed -ErrorMessage $_.Exception.Message }
                    }
                }
        }
        $result.ExpiredTrashRemoved = Remove-ExpiredTrash -DestinationRoot $destinationRoot -RetentionDays $TrashRetentionDays
        if ($completedFullScan) {
            foreach ($key in @($state.Entries.Keys)) {
                if (-not $sourceMap.ContainsKey($key) -and [string]$state.Entries[$key].Status -notin @('Failed','Locked')) { $state.Entries.Remove($key) }
            }
            $state.LastFullScanUtc = [datetime]::UtcNow.ToString('o')
            $state.FullScanRequired = $false
        }
        $state.PendingPaths = @()
        $state.CheckpointActive = $false
        $state.CheckpointFullScan = $false
        $state.LastRunUtc = [datetime]::UtcNow.ToString('o')
        if ($null -ne (Get-Command Set-SafeSyncUsnCursor -ErrorAction SilentlyContinue)) { [void](Set-SafeSyncUsnCursor $Job $state) }
        Save-SafeSyncState $state
        if (@($result.Errors).Count -gt 0) { $result.Status = 'CompletedWithErrors' }
        elseif (@($result.Conflicts).Count -gt 0) { $result.Status = 'CompletedWithConflicts' }
        elseif (@($result.LockedFiles).Count -gt 0) { $result.Status = 'CompletedWithLockedFiles' }
        else { $result.Status = 'Completed' }
    }
    catch {
        $result.Status = 'Failed'
        $result.Errors += $_.Exception.Message
        if ($null -ne $state) { try { Save-SafeSyncState $state } catch {} }
    }
    $result.FinishedAt = (Get-Date).ToString('o')
    return [pscustomobject]$result
}

function Invoke-BackupJob {
    param(
        [Parameter(Mandatory=$true)][object]$Job,
        [int]$TrashRetentionDays = 100,
        [object]$Config = $null,
        [switch]$ForceFull,
        [string[]]$ForceOverwritePaths = @(),
        [string[]]$RenameExistingPaths = @()
    )
    $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
    $targetKey = if ($destinationType -eq 'Local') { Get-NormalizedPath ([string]$Job.Destination) } else { [string]$Job.CloudFolderId }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $lockId = [BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$destinationType|$targetKey".ToLowerInvariant()))).Replace('-','') } finally { $sha.Dispose() }
    $targetMutex = [System.Threading.Mutex]::new($false, "Local\SafeSync.Target.$lockId")
    $acquired = $false
    try {
        try { $acquired = $targetMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw '같은 백업 위치에서 다른 작업이 실행 중입니다. 해당 작업이 끝난 뒤 다시 실행하세요.' }
        if ($destinationType -eq 'Dropbox' -or $destinationType -eq 'GoogleDrive') {
            if ($null -eq $Config) { throw '클라우드 백업 설정을 불러오지 못했습니다.' }
            if (-not (Get-Command Invoke-SafeSyncCloudBackup -ErrorAction SilentlyContinue)) { throw '클라우드 백업 모듈을 찾을 수 없습니다.' }
            return Invoke-SafeSyncCloudBackup -Job $Job -Config $Config -TrashRetentionDays $TrashRetentionDays -ForceFull:$ForceFull -ForceOverwritePaths $ForceOverwritePaths -RenameExistingPaths $RenameExistingPaths
        }
        return Invoke-LocalBackupJob -Job $Job -TrashRetentionDays $TrashRetentionDays -ForceFull:$ForceFull -ForceOverwritePaths $ForceOverwritePaths -RenameExistingPaths $RenameExistingPaths
    }
    catch {
        return [pscustomobject]@{ JobId=[string]$Job.Id; JobName=[string]$Job.Name; Status='Failed'; StartedAt=(Get-Date).ToString('o'); FinishedAt=(Get-Date).ToString('o'); Copied=0; Skipped=0; Trashed=0; RenamedBackups=0; ExpiredTrashRemoved=0; Conflicts=@(); Errors=@($_.Exception.Message); LockedFiles=@() }
    }
    finally { if ($acquired) { $targetMutex.ReleaseMutex() }; $targetMutex.Dispose() }
}

function Write-WorkerResult([object]$Result) {
    Initialize-DataFolders
    $resultPath = Join-Path $script:ResultRoot "$($Result.JobId).json"
    $tempPath = "$resultPath.tmp"
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $resultPath -Force
}

if (-not ('SafeSyncUsnJournalWorker' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;

public static class SafeSyncUsnJournalWorker
{
    private const uint FILE_READ_ATTRIBUTES=0x00000080, FILE_SHARE_READ=1, FILE_SHARE_WRITE=2, FILE_SHARE_DELETE=4, OPEN_EXISTING=3, FILE_FLAG_BACKUP_SEMANTICS=0x02000000;
    [StructLayout(LayoutKind.Sequential)] private struct Info { public uint A; public System.Runtime.InteropServices.ComTypes.FILETIME B,C,D; public uint E,F,G,H,I,J; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateFile(string name,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(IntPtr handle,out Info info);
    public static long GetFileId(string path){IntPtr h=CreateFile(path,FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,IntPtr.Zero,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,IntPtr.Zero);if(h==IntPtr.Zero||h==new IntPtr(-1))return 0;try{Info i;if(!GetFileInformationByHandle(h,out i))return 0;return unchecked(((long)i.I<<32)|i.J);}finally{CloseHandle(h);}}
}
'@
}

# Worker and reconciliation modes exit before the UI-only helper types are loaded.
# The main UI later replaces this fallback with the real USN cursor implementation.
if ($null -eq (Get-Command Set-SafeSyncUsnCursor -ErrorAction SilentlyContinue)) {
    function Set-SafeSyncUsnCursor([object]$Job, [object]$State) { return $false }
}

Initialize-DataFolders

if (-not [string]::IsNullOrWhiteSpace($ReconcileJobId)) {
    $reconcileConfig = Load-Config
    $reconcileJob = @($reconcileConfig.Jobs) | Where-Object { [string]$_.Id -eq $ReconcileJobId } | Select-Object -First 1
    if ($null -eq $reconcileJob) {
        Write-SafeSyncReconciliationResult ([pscustomobject]@{JobId=$ReconcileJobId;JobName='알 수 없는 작업';FullScanRequired=$false;SourceUnavailable=$false;Changes=@();Error='작업을 찾을 수 없습니다.'})
        exit 2
    }
    $reconcileResult = Invoke-SafeSyncStartupReconciliation $reconcileJob -ForceMetadata:$ReconcileForce
    Write-SafeSyncReconciliationResult $reconcileResult
    if (-not [string]::IsNullOrWhiteSpace([string]$reconcileResult.Error)) { exit 1 }
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($WorkerJobId)) {
    $workerConfig = Load-Config
    $workerJob = @($workerConfig.Jobs) | Where-Object { [string]$_.Id -eq $WorkerJobId } | Select-Object -First 1
    if ($null -eq $workerJob) {
        Write-WorkerResult ([pscustomobject]@{ JobId=$WorkerJobId; JobName='알 수 없는 작업'; Status='Failed'; StartedAt=(Get-Date).ToString('o'); FinishedAt=(Get-Date).ToString('o'); Copied=0; Skipped=0; Trashed=0; ExpiredTrashRemoved=0; Conflicts=@(); Errors=@('작업을 찾을 수 없습니다.'); LockedFiles=@() })
        exit 2
    }
    $forceOverwritePaths = @()
    $renameExistingPaths = @()
    if (-not [string]::IsNullOrWhiteSpace($ConflictPlanPath)) {
        $fullPlanPath = [System.IO.Path]::GetFullPath($ConflictPlanPath)
        $allowedPlanRoot = [System.IO.Path]::GetFullPath($script:ResultRoot).TrimEnd('\') + '\'
        if (-not $fullPlanPath.StartsWith($allowedPlanRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPlanPath -PathType Leaf)) { throw '충돌 처리 요청 파일이 올바르지 않습니다.' }
        $conflictPlan = Get-Content -LiteralPath $fullPlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$conflictPlan.JobId -ne [string]$workerJob.Id) { throw '충돌 처리 요청의 작업 정보가 일치하지 않습니다.' }
        foreach ($path in @($conflictPlan.BackupPaths)) {
            $relative = ConvertTo-SafeSyncRelativePath ([string]$path)
            if ([System.IO.Path]::IsPathRooted($relative) -or @($relative.Split('/')) -contains '..') { throw "안전하지 않은 충돌 파일 경로입니다: $relative" }
            if (-not [string]::IsNullOrWhiteSpace($relative)) { $forceOverwritePaths += $relative }
        }
        if ($null -ne $conflictPlan.PSObject.Properties['RenamePaths']) {
            foreach ($path in @($conflictPlan.RenamePaths)) {
                $relative = ConvertTo-SafeSyncRelativePath ([string]$path)
                if ([System.IO.Path]::IsPathRooted($relative) -or @($relative.Split('/')) -contains '..') { throw "안전하지 않은 충돌 파일 경로입니다: $relative" }
                if (-not [string]::IsNullOrWhiteSpace($relative)) {
                    $renameExistingPaths += $relative
                    if ($forceOverwritePaths -notcontains $relative) { $forceOverwritePaths += $relative }
                }
            }
        }
    }
    Write-SafeSyncProgress -Job $workerJob -Stage '백업 준비 중' -Detail $(if($forceOverwritePaths.Count -gt 0){'선택한 충돌 파일을 처리할 준비를 하고 있습니다.'}else{'백업 설정과 저장된 작업 기록을 확인하고 있습니다.'}) -CurrentFolder ([string]$workerJob.Source) -Force
    $workerResult = Invoke-BackupJob -Job $workerJob -TrashRetentionDays ([int]$workerConfig.TrashRetentionDays) -Config $workerConfig -ForceFull:$WorkerForceFull -ForceOverwritePaths $forceOverwritePaths -RenameExistingPaths $renameExistingPaths
    Write-SafeSyncProgress -Job $workerJob -Stage '완료' -Detail '백업 작업 결과를 정리하고 있습니다.' -CompletedFiles 1 -TotalFiles 1 -Force
    Write-WorkerResult $workerResult
    if ($workerResult.Status -eq 'Failed') { exit 1 }
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.InteropServices;

public static class SafeSyncDpi
{
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDPIAware();

    public static void Enable()
    {
        try
        {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2. This keeps WPF,
            // WinForms tray menus and physical cursor coordinates in one space.
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return;
        }
        catch (EntryPointNotFoundException) { }
        catch (DllNotFoundException) { }
        try { SetProcessDPIAware(); } catch { }
    }
}

public sealed class SafeSyncWatcher : IDisposable
{
    private readonly string jobId;
    private readonly ConcurrentDictionary<string, DateTime> pending;
    private readonly ConcurrentDictionary<string, DateTime> paths;
    private readonly FileSystemWatcher watcher;
    private readonly bool deletionsOnly;
    private readonly string root;
    private readonly string side;

    public SafeSyncWatcher(string path, string id, ConcurrentDictionary<string, DateTime> pendingChanges, ConcurrentDictionary<string, DateTime> changedPaths, string changeSide)
        : this(path, id, pendingChanges, changedPaths, changeSide, false)
    {
    }

    public SafeSyncWatcher(string path, string id, ConcurrentDictionary<string, DateTime> pendingChanges, ConcurrentDictionary<string, DateTime> changedPaths, string changeSide, bool watchDeletionsOnly)
    {
        jobId = id;
        pending = pendingChanges;
        paths = changedPaths;
        root = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        side = changeSide;
        deletionsOnly = watchDeletionsOnly;
        watcher = new FileSystemWatcher(path);
        watcher.IncludeSubdirectories = true;
        watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime;
        if (!deletionsOnly)
        {
            watcher.Changed += OnChanged;
            watcher.Created += OnChanged;
        }
        watcher.Deleted += OnChanged;
        watcher.Renamed += OnRenamed;
        watcher.Error += OnError;
        watcher.EnableRaisingEvents = true;
    }

    private void Touch(string fullPath, bool forceFull)
    {
        DateTime now = DateTime.Now;
        string relative = "*";
        string eventSide = forceFull ? "F" : side;
        if (!forceFull)
        {
            string value = Path.GetFullPath(fullPath);
            if (value.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                relative = value.Substring(root.Length + 1).Replace(Path.DirectorySeparatorChar, '/');
            else if (String.Equals(value, root, StringComparison.OrdinalIgnoreCase))
                relative = "";
        }
        paths.AddOrUpdate(jobId + "|" + eventSide + "|" + relative, now, (key, previous) => now);
        pending.AddOrUpdate(jobId, now, (key, previous) => now);
    }

    private bool InternalPath(string path)
    {
        return System.Text.RegularExpressions.Regex.IsMatch(path, @"(^|[\\/])\.safesync-(trash|staging)([\\/]|$)|\.safesync-(part|txn)-", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }
    private void OnChanged(object sender, FileSystemEventArgs args) { if (!InternalPath(args.FullPath)) Touch(args.FullPath, false); }
    private void OnRenamed(object sender, RenamedEventArgs args)
    {
        if (!InternalPath(args.OldFullPath)) Touch(args.OldFullPath, false);
        if (!InternalPath(args.FullPath)) Touch(args.FullPath, false);
    }
    private void OnError(object sender, ErrorEventArgs args) { Touch(root, true); }

    public void Dispose()
    {
        watcher.EnableRaisingEvents = false;
        if (!deletionsOnly)
        {
            watcher.Changed -= OnChanged;
            watcher.Created -= OnChanged;
        }
        watcher.Deleted -= OnChanged;
        watcher.Renamed -= OnRenamed;
        watcher.Error -= OnError;
        watcher.Dispose();
    }
}
"@
[SafeSyncDpi]::Enable()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

if (-not ('SafeSyncUsnJournal' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class SafeSyncUsnChange
{
    public long FileReferenceNumber;
    public long ParentFileReferenceNumber;
    public int Reason;
    public string Name;
    public string Path;
}

public sealed class SafeSyncUsnBatch
{
    public bool Supported;
    public bool JournalReset;
    public long JournalId;
    public long FirstUsn;
    public long NextUsn;
    public string VolumeRoot;
    public string Error;
    public SafeSyncUsnChange[] Changes;
}

public static class SafeSyncUsnJournal
{
    private const uint FSCTL_QUERY_USN_JOURNAL = 0x000900f4;
    private const uint FSCTL_READ_USN_JOURNAL = 0x000900bb;
    private const uint FILE_READ_ATTRIBUTES = 0x00000080;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint FILE_ID_TYPE = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct USN_JOURNAL_DATA
    {
        public ulong UsnJournalID;
        public long FirstUsn;
        public long NextUsn;
        public long LowestValidUsn;
        public long MaxUsn;
        public ulong MaximumSize;
        public ulong AllocationDelta;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct READ_USN_JOURNAL_DATA
    {
        public long StartUsn;
        public uint ReasonMask;
        public uint ReturnOnlyOnClose;
        public ulong Timeout;
        public ulong BytesToWaitFor;
        public ulong UsnJournalID;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILE_ID_DESCRIPTOR
    {
        public uint Size;
        public uint Type;
        public ulong Id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BY_HANDLE_FILE_INFORMATION
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(IntPtr handle, uint code, IntPtr input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(IntPtr handle, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenFileById(IntPtr volume, ref FILE_ID_DESCRIPTOR fileId, uint access, uint share, IntPtr security, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(IntPtr handle, StringBuilder path, uint length, uint flags);

    private static bool Invalid(IntPtr handle) { return handle == IntPtr.Zero || handle == new IntPtr(-1); }

    private static string VolumeRoot(string path)
    {
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full);
        if (String.IsNullOrWhiteSpace(root) || root.Length < 2 || root[1] != ':') return null;
        return root.Substring(0, 2).ToUpperInvariant() + "\\";
    }

    private static string VolumeDevice(string root) { return "\\\\.\\" + root.Substring(0, 2); }

    private static bool Query(IntPtr volume, out USN_JOURNAL_DATA data)
    {
        data = new USN_JOURNAL_DATA();
        int size = Marshal.SizeOf(typeof(USN_JOURNAL_DATA));
        IntPtr output = Marshal.AllocHGlobal(size);
        try
        {
            int returned;
            if (!DeviceIoControl(volume, FSCTL_QUERY_USN_JOURNAL, IntPtr.Zero, 0, output, size, out returned, IntPtr.Zero)) return false;
            data = (USN_JOURNAL_DATA)Marshal.PtrToStructure(output, typeof(USN_JOURNAL_DATA));
            return true;
        }
        finally { Marshal.FreeHGlobal(output); }
    }

    public static long GetFileId(string path)
    {
        IntPtr handle = CreateFile(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        if (Invalid(handle)) return 0;
        try
        {
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(handle, out info)) return 0;
            return unchecked(((long)info.FileIndexHigh << 32) | info.FileIndexLow);
        }
        finally { CloseHandle(handle); }
    }

    private static string GetPathById(IntPtr volume, long fileReference)
    {
        FILE_ID_DESCRIPTOR descriptor = new FILE_ID_DESCRIPTOR { Size = (uint)Marshal.SizeOf(typeof(FILE_ID_DESCRIPTOR)), Type = FILE_ID_TYPE, Id = unchecked((ulong)fileReference) };
        IntPtr handle = OpenFileById(volume, ref descriptor, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, FILE_FLAG_BACKUP_SEMANTICS);
        if (Invalid(handle)) return "";
        try
        {
            StringBuilder value = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, value, (uint)value.Capacity, 0);
            if (length == 0 || length >= value.Capacity) return "";
            string path = value.ToString();
            if (path.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) path = "\\\\" + path.Substring(8);
            else if (path.StartsWith("\\\\?\\", StringComparison.OrdinalIgnoreCase)) path = path.Substring(4);
            return path;
        }
        finally { CloseHandle(handle); }
    }

    public static SafeSyncUsnBatch Read(string root, long startUsn, long expectedJournalId)
    {
        SafeSyncUsnBatch result = new SafeSyncUsnBatch { Supported = false, JournalReset = false, JournalId = 0, FirstUsn = 0, NextUsn = 0, VolumeRoot = "", Error = "", Changes = new SafeSyncUsnChange[0] };
        string volumeRoot = VolumeRoot(root);
        result.VolumeRoot = volumeRoot ?? "";
        if (String.IsNullOrWhiteSpace(volumeRoot)) { result.Error = "USN Journal은 드라이브 문자 경로에서만 사용할 수 있습니다."; return result; }
        IntPtr volume = CreateFile(VolumeDevice(volumeRoot), 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
        if (Invalid(volume)) { result.Error = "볼륨에 접근할 수 없어 USN Journal을 사용할 수 없습니다."; return result; }
        try
        {
            USN_JOURNAL_DATA journal;
            if (!Query(volume, out journal)) { result.Error = "이 드라이브에서 USN Journal을 사용할 수 없습니다."; return result; }
            result.Supported = true; result.JournalId = unchecked((long)journal.UsnJournalID); result.FirstUsn = journal.FirstUsn; result.NextUsn = journal.NextUsn;
            if (expectedJournalId != 0 && expectedJournalId != result.JournalId) { result.JournalReset = true; return result; }
            if (startUsn != 0 && (startUsn < journal.FirstUsn || startUsn > journal.NextUsn)) { result.JournalReset = true; return result; }
            long cursor = startUsn == 0 ? journal.NextUsn : startUsn;
            List<SafeSyncUsnChange> changes = new List<SafeSyncUsnChange>();
            int inputSize = Marshal.SizeOf(typeof(READ_USN_JOURNAL_DATA));
            int bufferSize = 1024 * 1024;
            IntPtr input = Marshal.AllocHGlobal(inputSize);
            IntPtr output = Marshal.AllocHGlobal(bufferSize);
            try
            {
                for (int pass = 0; pass < 128 && cursor < journal.NextUsn; pass++)
                {
                    READ_USN_JOURNAL_DATA request = new READ_USN_JOURNAL_DATA { StartUsn = cursor, ReasonMask = 0xffffffff, ReturnOnlyOnClose = 0, Timeout = 0, BytesToWaitFor = 0, UsnJournalID = journal.UsnJournalID };
                    Marshal.StructureToPtr(request, input, false);
                    int returned;
                    if (!DeviceIoControl(volume, FSCTL_READ_USN_JOURNAL, input, inputSize, output, bufferSize, out returned, IntPtr.Zero)) { result.Error = "USN Journal 변경 기록을 읽지 못했습니다."; break; }
                    if (returned < 8) break;
                    long nextCursor = Marshal.ReadInt64(output);
                    int offset = 8;
                    while (offset + 60 <= returned)
                    {
                        int recordLength = Marshal.ReadInt32(IntPtr.Add(output, offset));
                        if (recordLength < 60 || offset + recordLength > returned) break;
                        long fileRef = Marshal.ReadInt64(IntPtr.Add(output, offset + 8));
                        long parentRef = Marshal.ReadInt64(IntPtr.Add(output, offset + 16));
                        int reason = Marshal.ReadInt32(IntPtr.Add(output, offset + 40));
                        ushort nameLength = (ushort)Marshal.ReadInt16(IntPtr.Add(output, offset + 56));
                        ushort nameOffset = (ushort)Marshal.ReadInt16(IntPtr.Add(output, offset + 58));
                        string name = "";
                        if (nameLength > 0 && nameOffset + nameLength <= recordLength)
                        {
                            byte[] bytes = new byte[nameLength]; Marshal.Copy(IntPtr.Add(output, offset + nameOffset), bytes, 0, nameLength); name = Encoding.Unicode.GetString(bytes);
                        }
                        string currentPath = GetPathById(volume, fileRef);
                        changes.Add(new SafeSyncUsnChange { FileReferenceNumber = fileRef, ParentFileReferenceNumber = parentRef, Reason = reason, Name = name, Path = currentPath });
                        offset += recordLength;
                    }
                    if (nextCursor <= cursor) break;
                    cursor = nextCursor;
                    if (returned < bufferSize) break;
                }
            }
            finally { Marshal.FreeHGlobal(input); Marshal.FreeHGlobal(output); }
            result.NextUsn = cursor; result.Changes = changes.ToArray();
            return result;
        }
        finally { CloseHandle(volume); }
    }
}
'@
}

function Set-SafeSyncUsnCursor([object]$Job, [object]$State) {
    if ($null -eq $State -or $null -eq $Job -or 'SafeSyncUsnJournal' -as [type]) { return $false }
    try {
        $batch = [SafeSyncUsnJournal]::Read([string]$Job.Source, 0, 0)
        if (-not [bool]$batch.Supported) {
            $State.UsnSupported = $false
            $State.UsnInitialized = $false
            $State.UsnVolumeRoot = ''
            return $false
        }
        $State.UsnSupported = $true
        $State.UsnInitialized = $true
        $State.UsnJournalId = [long]$batch.JournalId
        $State.UsnNext = [long]$batch.NextUsn
        $State.UsnVolumeRoot = [string]$batch.VolumeRoot
        return $true
    }
    catch {
        $State.UsnSupported = $false
        $State.UsnInitialized = $false
        $State.UsnVolumeRoot = ''
        return $false
    }
}

function Invoke-SafeSyncOfflineChangeDetection([object]$Job) {
    $state = Get-SafeSyncState ([string]$Job.Id)
    $fallback = [pscustomobject]@{ Mode='Reconcile'; Changes=0; Error=''; State=$state }
    if ([bool]$state.CheckpointActive) { $fallback.Mode = 'Checkpoint'; return $fallback }
    $lastFull = [datetime]::MinValue
    if (-not [string]::IsNullOrWhiteSpace([string]$state.LastFullScanUtc)) { [void][datetime]::TryParse([string]$state.LastFullScanUtc, [ref]$lastFull) }
    if (-not $state.Exists -or [bool]$state.FullScanRequired -or $lastFull -eq [datetime]::MinValue -or ([datetime]::UtcNow - $lastFull.ToUniversalTime()).TotalDays -ge 7) { return $fallback }
    if (-not [bool]$state.UsnInitialized -or -not ('SafeSyncUsnJournal' -as [type])) { return $fallback }
    try {
        $batch = [SafeSyncUsnJournal]::Read([string]$Job.Source, [long]$state.UsnNext, [long]$state.UsnJournalId)
        if (-not [bool]$batch.Supported -or [bool]$batch.JournalReset) {
            Write-AppLog "USN Journal을 사용할 수 없어 시작 메타데이터 대조로 전환합니다. 지원=$($batch.Supported), 초기화=$($batch.JournalReset), 오류=$([string]$batch.Error)" 'INFO'
            $state.UsnSupported = [bool]$batch.Supported
            $state.UsnInitialized = $false
            $state.FullScanRequired = $true
            Save-SafeSyncState $state
            $fallback.State = $state
            return $fallback
        }
        $root = Get-NormalizedPath ([string]$Job.Source)
        $knownIds = @{}
        foreach ($entry in @($state.Entries.Values)) {
            if ($null -ne $entry.PSObject.Properties['FileId'] -and [long]$entry.FileId -ne 0) { $knownIds[[string][long]$entry.FileId] = [string]$entry.RelativePath }
        }
        $pending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @($state.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $pending[[string]$path] = [string]$path } }
        $unknown = $false
        foreach ($change in @($batch.Changes)) {
            $relative = ''
            $current = [string]$change.Path
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $normalized = Get-NormalizedPath $current
                if ($normalized.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { $relative = '' }
                elseif ($normalized.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $relative = ConvertTo-SafeSyncRelativePath ($normalized.Substring($root.Length).TrimStart('\','/')) }
            }
            $knownRelative = if ($knownIds.ContainsKey([string][long]$change.FileReferenceNumber)) { ConvertTo-SafeSyncRelativePath ([string]$knownIds[[string][long]$change.FileReferenceNumber]) } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($knownRelative) -and -not [string]::IsNullOrWhiteSpace($relative) -and -not $knownRelative.Equals($relative, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not (Test-SafeSyncInternalPath $knownRelative)) { $pending[$knownRelative] = $knownRelative }
            }
            if ([string]::IsNullOrWhiteSpace($relative) -and -not [string]::IsNullOrWhiteSpace($knownRelative)) { $relative = $knownRelative }
            if (-not [string]::IsNullOrWhiteSpace($relative)) {
                if (-not (Test-SafeSyncInternalPath $relative)) { $pending[$relative] = $relative }
            }
            elseif (($change.Reason -band 0x00000100) -ne 0 -or ($change.Reason -band 0x00000200) -ne 0 -or ($change.Reason -band 0x00001000) -ne 0 -or ($change.Reason -band 0x00002000) -ne 0) {
                $unknown = $true
            }
        }
        if ($unknown) {
            $state.FullScanRequired = $true
            $state.UsnInitialized = $false
            Save-SafeSyncState $state
            $fallback.State = $state
            return $fallback
        }
        $state.PendingPaths = @($pending.Values)
        $state.UsnSupported = $true
        $state.UsnInitialized = $true
        $state.UsnJournalId = [long]$batch.JournalId
        $state.UsnNext = [long]$batch.NextUsn
        $state.UsnVolumeRoot = [string]$batch.VolumeRoot
        Save-SafeSyncState $state
        foreach ($relative in @($pending.Values)) { Add-SafeSyncChangedPath ([string]$Job.Id) 'S' ([string]$relative) }
        return [pscustomobject]@{ Mode='Journal'; Changes=$pending.Count; Error=''; State=$state }
    }
    catch {
        $fallback.Error = $_.Exception.Message
        return $fallback
    }
}

$mainMutexName = 'Local\SafeSync.Main'
if ($SkipAutoStartForTest) {
    $mainNameHasher = [System.Security.Cryptography.SHA256]::Create()
    try { $mainNameHash = [BitConverter]::ToString($mainNameHasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:DataRoot.ToLowerInvariant()))).Replace('-','') }
    finally { $mainNameHasher.Dispose() }
    $mainMutexName = "Local\SafeSync.Test.Main.$mainNameHash"
}
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mainMutexName, [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.MessageBox]::Show('SafeSync가 이미 실행 중입니다. 작업 표시줄 알림 영역을 확인하세요.', 'SafeSync') | Out-Null
    exit 0
}

$script:Config = Load-Config
$script:Watchers = @{}
$script:RunningJobs = @{}
$script:ReconciliationJobs = @{}
$script:PendingChanges = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:ChangedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:LastStatus = @{}
$script:AllowExit = $false
$script:KnownIssues = @{}
$script:PendingNotices = New-Object System.Collections.ArrayList
$script:ShowingPendingNotices = $false
$script:LockedFiles = @{}
$script:LockedRetryAt = @{}
$script:LockedRetryDelaySeconds = @{}
$script:TrashBrowserContext = $null

function Save-SafeSyncNotificationState {
    try {
        $known=@($script:KnownIssues.Values)
        $pending=@($script:PendingNotices)
        $saved=[pscustomobject]@{Version=1;KnownIssues=[object[]]$known;PendingNotices=[object[]]$pending}
        $temp="$($script:NotificationStatePath).tmp"
        $saved|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $temp -Encoding UTF8
        Move-Item -LiteralPath $temp -Destination $script:NotificationStatePath -Force
    }catch{Write-AppLog "알림 상태 저장 실패: $($_.Exception.Message)" 'WARN'}
}

function Load-SafeSyncNotificationState {
    if(-not (Test-Path -LiteralPath $script:NotificationStatePath -PathType Leaf)){return}
    try{
        $saved=Get-Content -LiteralPath $script:NotificationStatePath -Raw -Encoding UTF8|ConvertFrom-Json
        foreach($issue in @($saved.KnownIssues)){if($null -ne $issue -and -not [string]::IsNullOrWhiteSpace([string]$issue.Key)){$script:KnownIssues[[string]$issue.Key]=$issue}}
        foreach($notice in @($saved.PendingNotices)){if($null -ne $notice){[void]$script:PendingNotices.Add($notice)}}
    }catch{Write-AppLog "알림 상태를 읽지 못했습니다: $($_.Exception.Message)" 'WARN'}
}

function Get-SafeSyncIssueKey([string]$JobId,[string]$Type,[string]$File,[string]$Message){
    $identity=if(-not [string]::IsNullOrWhiteSpace($File)){"$JobId|$Type|$($File.Replace('\','/').ToLowerInvariant())"}else{"$JobId|$Type|$Message"}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}

function Get-SafeSyncErrorFile([string]$JobId,[string]$Message){
    $separator=$Message.IndexOf(' : ',[StringComparison]::Ordinal)
    if($separator -le 0){return ''}
    $candidate=ConvertTo-SafeSyncRelativePath $Message.Substring(0,$separator)
    $state=Get-SafeSyncState $JobId
    if($state.Entries.ContainsKey($candidate.ToLowerInvariant())){return $candidate}
    return ''
}

function Remove-SafeSyncResolvedIssueKeys([string]$JobId){
    $state=Get-SafeSyncState $JobId
    $changed=$false
    foreach($key in @($script:KnownIssues.Keys)){
        $issue=$script:KnownIssues[$key]
        if([string]$issue.JobId -ne $JobId -or [string]::IsNullOrWhiteSpace([string]$issue.File)){continue}
        $fileKey=(ConvertTo-SafeSyncRelativePath ([string]$issue.File)).ToLowerInvariant()
        $currentStatus=if($state.Entries.ContainsKey($fileKey)){[string]$state.Entries[$fileKey].Status}else{''}
        if(-not $state.Entries.ContainsKey($fileKey) -or $currentStatus -eq 'BackedUp' -or ($currentStatus -eq 'Locked' -and [string]$issue.Type -eq 'Error')){[void]$script:KnownIssues.Remove($key);$changed=$true}
    }
    if($changed){
        $keptNotices=New-Object System.Collections.ArrayList
        foreach($notice in @($script:PendingNotices)){
            if([string]$notice.JobId -ne $JobId){[void]$keptNotices.Add($notice);continue}
            if([string]$notice.Type -eq 'Conflict'){
                $kept=@($notice.Conflicts|Where-Object{$key=Get-SafeSyncIssueKey $JobId 'Conflict' ([string]$_.File) ([string]$_.Reason);$script:KnownIssues.ContainsKey($key)})
                if($kept.Count -gt 0){$notice.Conflicts=[object[]]$kept;[void]$keptNotices.Add($notice)}
            }else{
                $kept=@($notice.Errors|Where-Object{$message=[string]$_;$file=Get-SafeSyncErrorFile $JobId $message;$key=Get-SafeSyncIssueKey $JobId 'Error' $file $message;$script:KnownIssues.ContainsKey($key)})
                if($kept.Count -gt 0){$notice.Errors=[string[]]$kept;[void]$keptNotices.Add($notice)}
            }
        }
        $script:PendingNotices=$keptNotices
    }
    if($changed){Save-SafeSyncNotificationState}
}

function Update-SafeSyncNoticeIndicator {
    $count=$script:PendingNotices.Count
    $notifyVariable=Get-Variable -Name NotifyIcon -Scope Script -ErrorAction SilentlyContinue
    if($null -ne $notifyVariable -and $null -ne $script:NotifyIcon){
        Update-SafeSyncTrayIcon
    }
    $buttonVariable=Get-Variable -Name NotificationsButton -Scope Script -ErrorAction SilentlyContinue
    if($null -ne $buttonVariable -and $null -ne $script:NotificationsButton){
        $script:NotificationsButton.Content=if($count -gt 0){"확인할 메시지 ($count)"}else{'확인할 메시지'}
        $script:NotificationsButton.IsEnabled=$count -gt 0
    }
}

function New-SafeSyncTrayFrameIcon {
    param(
        [Parameter(Mandatory=$true)][System.Drawing.Bitmap]$Bitmap,
        [Parameter(Mandatory=$true)][int]$FrameIndex
    )
    # Icon.FromHandle/GetHicon produces an invalid alpha mask in Windows 11's
    # notification-area host on some machines. Write a standard 32-bit ICO
    # instead, including an explicit AND mask, and load it as a normal Icon.
    $size = 32
    $canvas = $null
    $graphics = $null
    $data = $null
    $stream = $null
    $writer = $null
    try {
        $canvas = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($canvas)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Bitmap, [System.Drawing.Rectangle]::new(0, 0, $size, $size))
        $rect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
        $data = $canvas.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $rowLength = $size * 4
        $xorBytes = [byte[]]::new($rowLength * $size)
        $row = [byte[]]::new($rowLength)
        for ($rowIndex = 0; $rowIndex -lt $size; $rowIndex++) {
            [System.Runtime.InteropServices.Marshal]::Copy([System.IntPtr]::Add($data.Scan0, $rowIndex * $data.Stride), $row, 0, $rowLength)
            [System.Array]::Copy($row, 0, $xorBytes, ($size - 1 - $rowIndex) * $rowLength, $rowLength)
        }
        $maskStride = [int]([Math]::Ceiling($size / 32.0) * 4)
        $andMask = [byte[]]::new($maskStride * $size)
        $cacheRoot = Join-Path $script:DataRoot 'cache\\tray-icons'
        if (-not (Test-Path -LiteralPath $cacheRoot)) { [void](New-Item -ItemType Directory -Path $cacheRoot -Force) }
        $framePath = Join-Path $cacheRoot ("safesync-progress-$FrameIndex.ico")
        $stream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($stream)
        # ICONDIR + ICONDIRENTRY
        $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]1)
        $writer.Write([byte]$size); $writer.Write([byte]$size); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([UInt16]1); $writer.Write([UInt16]32)
        $writer.Write([UInt32](40 + $xorBytes.Length + $andMask.Length)); $writer.Write([UInt32]22)
        # BITMAPINFOHEADER. ICO height is XOR + AND-mask height.
        $writer.Write([UInt32]40); $writer.Write([Int32]$size); $writer.Write([Int32]($size * 2))
        $writer.Write([UInt16]1); $writer.Write([UInt16]32); $writer.Write([UInt32]0)
        $writer.Write([UInt32]$xorBytes.Length); $writer.Write([Int32]0); $writer.Write([Int32]0); $writer.Write([UInt32]0); $writer.Write([UInt32]0)
        $writer.Write($xorBytes); $writer.Write($andMask); $writer.Flush()
        [System.IO.File]::WriteAllBytes($framePath, $stream.ToArray())
        return [pscustomobject]@{ Icon = [System.Drawing.Icon]::new($framePath); Path = $framePath }
    }
    finally {
        if ($null -ne $data) { $canvas.UnlockBits($data) }
        if ($null -ne $writer) { $writer.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $canvas) { $canvas.Dispose() }
    }
}

function Initialize-SafeSyncTrayAnimation {
    if ($script:TrayAnimationFrames.Count -gt 0) { return }
    $frames = New-Object System.Collections.Generic.List[object]
    $paths = New-Object System.Collections.Generic.List[string]
    try {
        # These ICOs are generated when SafeSync is packaged, not at runtime.
        # Shell_NotifyIcon therefore receives ordinary file-backed icons, the
        # same reliable format used by desktop applications with tray animation.
        $assetRoot = Split-Path -Parent $script:ScriptPath
        for ($step = 0; $step -lt 4; $step++) {
            $framePath = Join-Path $assetRoot ("SafeSync-Progress-$step.ico")
            if (-not (Test-Path -LiteralPath $framePath -PathType Leaf)) { throw "진행 아이콘 파일을 찾을 수 없습니다: $framePath" }
            [void]$frames.Add([System.Drawing.Icon]::new($framePath))
            [void]$paths.Add($framePath)
        }
        $script:TrayAnimationFrames = @($frames.ToArray())
        $script:TrayAnimationFramePaths = @($paths.ToArray())
    }
    catch {
        foreach ($frame in @($frames)) { try { $frame.Dispose() } catch {} }
        $script:TrayAnimationFrames = @()
        $script:TrayAnimationFramePaths = @()
        Write-AppLog "알림 영역 진행 아이콘을 준비하지 못했습니다: $($_.Exception.Message)" 'WARN'
    }
}

function Dispose-SafeSyncTrayAnimation {
    foreach ($frame in @($script:TrayAnimationFrames)) { try { $frame.Dispose() } catch {} }
    $script:TrayAnimationFrames = @()
    $script:TrayAnimationFramePaths = @()
    $script:TrayAnimationIndex = 0
}

function Test-SafeSyncTrayWorkRunning {
    $running = $false
    try { $running = ($script:RunningJobs.Count -gt 0 -or $script:ReconciliationJobs.Count -gt 0) } catch {}
    return $running
}

function Update-SafeSyncTrayIcon {
    if ($null -eq $script:NotifyIcon) { return }
    $count = @($script:PendingNotices).Count
    if (Test-SafeSyncTrayWorkRunning) {
        Initialize-SafeSyncTrayAnimation
        if ($script:TrayAnimationFrames.Count -gt 0) {
            $script:NotifyIcon.Icon = $script:TrayAnimationFrames[$script:TrayAnimationIndex]
            $script:TrayAnimationIndex = ($script:TrayAnimationIndex + 1) % $script:TrayAnimationFrames.Count
        }
        else {
            $script:NotifyIcon.Icon = if ($null -ne $script:AppIcon) { $script:AppIcon } else { [System.Drawing.SystemIcons]::Shield }
        }
        $script:NotifyIcon.Text = if ($count -gt 0) { "SafeSync - 백업 중 · 확인할 메시지 ${count}개" } else { 'SafeSync - 백업 진행 중' }
    }
    else {
        $script:NotifyIcon.Icon = if ($count -gt 0) { [System.Drawing.SystemIcons]::Warning } elseif ($null -ne $script:AppIcon) { $script:AppIcon } else { [System.Drawing.SystemIcons]::Shield }
        $script:NotifyIcon.Text = if ($count -gt 0) { "SafeSync - 확인할 메시지 ${count}개" } else { 'SafeSync - 자동 백업 대기 중' }
    }
}

function Remove-SafeSyncLockedFileErrors([object]$Result) {
    if ($null -eq $Result -or $null -eq $Result.PSObject.Properties['Errors']) { return 0 }
    $remaining = New-Object System.Collections.Generic.List[string]
    $removed = 0
    foreach ($message in @($Result.Errors)) {
        # A worker can report a wrapped IO error after it has already saved the
        # same file as Locked. Keep it out of both the error popup and alert sound.
        if (Test-SafeSyncFileInUseError $message) {
            $removed++
            continue
        }
        $remaining.Add([string]$message)
    }
    if ($removed -gt 0) { $Result.Errors = [string[]]$remaining.ToArray() }
    return $removed
}

function Add-SafeSyncResultNotices([object]$Result){
    [void](Remove-SafeSyncLockedFileErrors $Result)
    Remove-SafeSyncResolvedIssueKeys ([string]$Result.JobId)
    $newConflicts=New-Object System.Collections.Generic.List[object]
    foreach($item in @($Result.Conflicts)){
        $key=Get-SafeSyncIssueKey ([string]$Result.JobId) 'Conflict' ([string]$item.File) ([string]$item.Reason)
        if($script:KnownIssues.ContainsKey($key)){continue}
        $script:KnownIssues[$key]=[pscustomobject]@{Key=$key;JobId=[string]$Result.JobId;Type='Conflict';File=[string]$item.File;Message=[string]$item.Reason;FirstSeen=(Get-Date).ToString('o')}
        $newConflicts.Add($item)
    }
    if($newConflicts.Count -gt 0){
        [void]$script:PendingNotices.Add([pscustomobject]@{Type='Conflict';JobId=[string]$Result.JobId;JobName=[string]$Result.JobName;Conflicts=[object[]]$newConflicts.ToArray();Errors=@();CreatedAt=(Get-Date).ToString('o')})
    }
    $newErrors=New-Object System.Collections.Generic.List[string]
    foreach($message in @($Result.Errors)){
        $file=Get-SafeSyncErrorFile ([string]$Result.JobId) ([string]$message)
        $key=Get-SafeSyncIssueKey ([string]$Result.JobId) 'Error' $file ([string]$message)
        if($script:KnownIssues.ContainsKey($key)){continue}
        $script:KnownIssues[$key]=[pscustomobject]@{Key=$key;JobId=[string]$Result.JobId;Type='Error';File=$file;Message=[string]$message;FirstSeen=(Get-Date).ToString('o')}
        $newErrors.Add([string]$message)
    }
    if($newErrors.Count -gt 0){
        [void]$script:PendingNotices.Add([pscustomobject]@{Type='Error';JobId=[string]$Result.JobId;JobName=[string]$Result.JobName;Conflicts=@();Errors=[string[]]$newErrors.ToArray();CreatedAt=(Get-Date).ToString('o')})
    }
    Save-SafeSyncNotificationState
    Update-SafeSyncNoticeIndicator
    $progressRowsVariable=Get-Variable -Name ProgressConflictRows -Scope Script -ErrorAction SilentlyContinue
    if($null -ne $progressRowsVariable){Refresh-ProgressConflictRows}
    return ($newConflicts.Count+$newErrors.Count)
}

Load-SafeSyncNotificationState

function Set-AutoStart([bool]$Enabled) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ($Enabled) {
        $launcherPath = Join-Path (Split-Path -Parent $script:ScriptPath) 'SafeSync.exe'
        if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
            $command = "`"$launcherPath`" -Minimized"
        }
        else {
            $powershellPath = (Get-Command powershell.exe).Source
            $command = "`"$powershellPath`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:ScriptPath`" -Minimized"
        }
        New-ItemProperty -Path $runKey -Name $script:AppName -Value $command -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -Path $runKey -Name $script:AppName -ErrorAction SilentlyContinue
    }
}

if (-not $SkipAutoStartForTest) {
    try { Set-AutoStart ([bool]$script:Config.AutoStart) } catch { Write-AppLog "자동 시작 설정 실패: $($_.Exception.Message)" 'WARN' }
}

function Load-Xaml([string]$Xaml) {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Get-SafeSyncThemeMode {
    $mode = if ($null -ne $script:Config -and $null -ne $script:Config.PSObject.Properties['ThemeMode']) { [string]$script:Config.ThemeMode } else { 'Light' }
    if ($mode -eq 'Dark') { return 'Dark' }
    return 'Light'
}

function Get-SafeSyncThemePalette {
    if ((Get-SafeSyncThemeMode) -eq 'Dark') {
        return @{
            Window = '#171B22'; Surface = '#20262F'; Subtle = '#282F3A'; Heading = '#303B4B'; MenuBorder = '#090C11'; Input = '#1B222C'
            Border = '#465164'; BorderSoft = '#354052'; Text = '#F3F6FA'; Muted = '#B3BECE'
            Accent = '#4C91FF'; AccentDark = '#2E6FC9'; SuccessSurface = '#193A2A'; SuccessText = '#72D49D'
            ActivitySurface = '#0F131A'; ActivityText = '#E7EDF6'; ActivityMuted = '#A9B8CE'; Warning = '#F4A340'; Danger = '#F26B62'
        }
    }
    return @{
        Window = '#F5F7FB'; Surface = '#FFFFFF'; Subtle = '#EEF2F8'; Heading = '#DCE8F7'; MenuBorder = '#E7ECF3'; Input = '#FFFFFF'
        Border = '#D7DEEA'; BorderSoft = '#DEE5EF'; Text = '#182033'; Muted = '#64748B'
        Accent = '#246BFD'; AccentDark = '#163B75'; SuccessSurface = '#E8F7EE'; SuccessText = '#16794A'
        ActivitySurface = '#EEF3F9'; ActivityText = '#263548'; ActivityMuted = '#52677F'; Warning = '#D97706'; Danger = '#C83B3B'
    }
}

function New-SafeSyncThemeBrush([string]$ColorValue) {
    $color = [System.Windows.Media.ColorConverter]::ConvertFromString($ColorValue)
    $brush = [System.Windows.Media.SolidColorBrush]::new($color)
    $brush.Freeze()
    return $brush
}

function Get-SafeSyncThemeBrushRole([object]$Brush) {
    if ($Brush -isnot [System.Windows.Media.SolidColorBrush]) { return '' }
    $color = $Brush.Color
    $value = ('#{0:X2}{1:X2}{2:X2}' -f $color.R, $color.G, $color.B).ToUpperInvariant()
    $aliases = @{
        Window = @('#F5F7FB','#F7F9FC','#171B22')
        Surface = @('#FFFFFF','#F8FAFC','#20262F')
        Subtle = @('#EEF2F8','#E8EEF8','#282F3A')
        Heading = @('#DCE8F7','#303B4B')
        MenuBorder = @('#E7ECF3','#090C11')
        Input = @('#1B222C')
        Border = @('#D7DEEA','#D5DDE9','#465164')
        BorderSoft = @('#DEE5EF','#DCE3EE','#E3E8F1','#354052')
        Text = @('#162033','#172033','#182033','#1E3A5F','#F3F6FA')
        Muted = @('#64748B','#475569','#334155','#B3BECE')
        Accent = @('#246BFD','#4C91FF')
        AccentDark = @('#163B75','#2E6FC9')
        SuccessSurface = @('#E8F7EE','#193A2A')
        SuccessText = @('#16794A','#72D49D')
        ActivitySurface = @('#111827','#0F131A','#EEF3F9')
        ActivityText = @('#E5E7EB','#E7EDF6','#263548')
        ActivityMuted = @('#A7B3C8','#A9B8CE','#52677F')
        Warning = @('#D97706','#F4A340')
        Danger = @('#C83B3B','#F26B62')
    }
    foreach ($role in $aliases.Keys) { if ($aliases[$role] -contains $value) { return $role } }
    return ''
}

function Set-SafeSyncThemeElementBrush([object]$Element,[string]$PropertyName,[hashtable]$Palette) {
    try {
        $property = $Element.PSObject.Properties[$PropertyName]
        if ($null -eq $property) { return }
        if ($PropertyName -eq 'Foreground' -and $property.Value -is [System.Windows.Media.SolidColorBrush]) {
            $color = $property.Value.Color
            if ($color.R -eq 255 -and $color.G -eq 255 -and $color.B -eq 255) { return }
        }
        $role = Get-SafeSyncThemeBrushRole $property.Value
        if (-not [string]::IsNullOrWhiteSpace($role) -and $Palette.ContainsKey($role)) { $Element.$PropertyName = New-SafeSyncThemeBrush $Palette[$role] }
    }
    catch { }
}

function Apply-SafeSyncThemeToWindow([System.Windows.Window]$Window) {
    if ($null -eq $Window) { return }
    $palette = Get-SafeSyncThemePalette
    foreach ($resource in @(
        @{Name='SafeSyncWindowBrush';Role='Window'}, @{Name='SafeSyncSurfaceBrush';Role='Surface'}, @{Name='SafeSyncSubtleBrush';Role='Subtle'}, @{Name='SafeSyncHeadingBrush';Role='Heading'}, @{Name='SafeSyncMenuBorderBrush';Role='MenuBorder'},
        @{Name='SafeSyncInputBrush';Role='Input'}, @{Name='SafeSyncBorderBrush';Role='Border'}, @{Name='SafeSyncBorderSoftBrush';Role='BorderSoft'},
        @{Name='SafeSyncTextBrush';Role='Text'}, @{Name='SafeSyncMutedBrush';Role='Muted'}, @{Name='SafeSyncAccentBrush';Role='Accent'},
        @{Name='SafeSyncAccentDarkBrush';Role='AccentDark'}, @{Name='SafeSyncSuccessSurfaceBrush';Role='SuccessSurface'}, @{Name='SafeSyncSuccessTextBrush';Role='SuccessText'},
        @{Name='SafeSyncActivityBrush';Role='ActivitySurface'}, @{Name='SafeSyncActivityTextBrush';Role='ActivityText'}, @{Name='SafeSyncActivityMutedBrush';Role='ActivityMuted'},
        @{Name='SafeSyncWarningBrush';Role='Warning'}, @{Name='SafeSyncDangerBrush';Role='Danger'}
    )) { $Window.Resources[$resource.Name] = New-SafeSyncThemeBrush $palette[$resource.Role] }

    # WPF's built-in menus, combo boxes and check boxes use SystemColors inside
    # their templates.  Providing matching window-local resources keeps popup
    # surfaces and their borders in the selected mode as well.
    foreach ($systemResource in @(
        @{Name='WindowBrushKey';Role='Window'}, @{Name='WindowTextBrushKey';Role='Text'},
        @{Name='ControlBrushKey';Role='Surface'}, @{Name='ControlTextBrushKey';Role='Text'},
        @{Name='ControlLightBrushKey';Role='Subtle'}, @{Name='ControlDarkBrushKey';Role='MenuBorder'},
        @{Name='MenuBarBrushKey';Role='Heading'}, @{Name='MenuBrushKey';Role='Surface'},
        @{Name='MenuTextBrushKey';Role='Text'}, @{Name='MenuHighlightBrushKey';Role='Accent'},
        @{Name='HighlightBrushKey';Role='Accent'}, @{Name='HighlightTextBrushKey';Role='Surface'},
        @{Name='GrayTextBrushKey';Role='Muted'}, @{Name='ActiveBorderBrushKey';Role='Border'},
        @{Name='InactiveSelectionHighlightBrushKey';Role='Subtle'}, @{Name='InactiveSelectionHighlightTextBrushKey';Role='Text'}
    )) {
        try {
            $propertyInfo = [System.Windows.SystemColors].GetProperty([string]$systemResource.Name)
            if ($null -ne $propertyInfo) { $Window.Resources[$propertyInfo.GetValue($null)] = New-SafeSyncThemeBrush $palette[$systemResource.Role] }
        }
        catch { }
    }

    $queue = New-Object 'System.Collections.Generic.Queue[System.Windows.DependencyObject]'
    $queue.Enqueue($Window)
    while ($queue.Count -gt 0) {
        $element = $queue.Dequeue()
        foreach ($propertyName in @('Background','Foreground','BorderBrush','AlternatingRowBackground','RowBackground')) { Set-SafeSyncThemeElementBrush $element $propertyName $palette }
        try {
            $children = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($element)
            for ($index = 0; $index -lt $children; $index++) { $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($element,$index)) }
        }
        catch { }
    }
}

function Apply-SafeSyncTheme {
    foreach ($candidate in @($script:Window, $script:ProgressWindow)) {
        if ($null -ne $candidate) { Apply-SafeSyncThemeToWindow $candidate }
    }
    if ($null -ne $script:TrashBrowserContext -and $null -ne $script:TrashBrowserContext.Dialog) { Apply-SafeSyncThemeToWindow $script:TrashBrowserContext.Dialog }
}

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SafeSync 백업" Width="1080" Height="720" MinWidth="800" MinHeight="540"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource SafeSyncWindowBrush}" FontFamily="Segoe UI, Malgun Gothic">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="MinHeight" Value="30"/>
    </Style>
    <Style x:Key="CommandButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Padding" Value="11,6"/><Setter Property="Margin" Value="0,0,4,0"/>
      <Setter Property="MinWidth" Value="84"/>
    </Style>
    <Style x:Key="MenuHeaderItem" TargetType="MenuItem">
      <Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/>
      <Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/>
      <Setter Property="Padding" Value="10,4"/><Setter Property="MinHeight" Value="28"/>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/>
      <Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource SafeSyncMenuBorderBrush}"/>
      <Setter Property="Padding" Value="8,3"/><Setter Property="MinWidth" Value="124"/><Setter Property="MinHeight" Value="27"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Style.Triggers><Trigger Property="IsHighlighted" Value="True"><Setter Property="Background" Value="{DynamicResource SafeSyncSubtleBrush}"/></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="Menu"><Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/></Style>
    <Style TargetType="ContextMenu"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncMenuBorderBrush}"/><Setter Property="BorderThickness" Value="1"/></Style>
    <Style TargetType="Separator"><Setter Property="Background" Value="{DynamicResource SafeSyncBorderBrush}"/></Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/><Setter Property="BorderThickness" Value="0,0,1,1"/><Setter Property="Padding" Value="10,7"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type DataGridColumnHeader}"><Grid SnapsToDevicePixels="True"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentStringFormat="{TemplateBinding ContentStringFormat}" RecognizesAccessKey="True"/></Border><Thumb x:Name="PART_LeftHeaderGripper" HorizontalAlignment="Left" Width="4" Background="{TemplateBinding Background}" Cursor="SizeWE"/><Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="4" Background="{TemplateBinding Background}" Cursor="SizeWE"/><Border HorizontalAlignment="Right" Width="1" Background="{DynamicResource SafeSyncBorderSoftBrush}"/></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="DataGridCell"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
    <Style TargetType="DataGridColumnHeadersPresenter"><Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/></Style>
  </Window.Resources>
  <Grid Margin="14">
    <Grid.RowDefinitions><RowDefinition Height="29"/><RowDefinition Height="Auto"/><RowDefinition x:Name="MainJobsRow" Height="*" MinHeight="110"/><RowDefinition Height="8"/><RowDefinition x:Name="MainActivityRow" Height="155" MinHeight="56"/><RowDefinition Height="26"/></Grid.RowDefinitions>
    <Menu Grid.Row="0" Background="{DynamicResource SafeSyncHeadingBrush}" Foreground="{DynamicResource SafeSyncTextBrush}" BorderBrush="{DynamicResource SafeSyncBorderBrush}" BorderThickness="1">
      <MenuItem Header="파일" Style="{StaticResource MenuHeaderItem}">
        <MenuItem x:Name="MenuAddJobItem" Header="새 백업 작업"/><Separator/><MenuItem x:Name="MenuExitItem" Header="프로그램 종료"/>
      </MenuItem>
      <MenuItem Header="작업" Style="{StaticResource MenuHeaderItem}">
        <MenuItem x:Name="EditButton" Header="작업 수정"/><MenuItem x:Name="DeleteButton" Header="작업 삭제"/><Separator/>
        <MenuItem x:Name="FullScanButton" Header="전체 검사" ToolTip="선택한 작업의 모든 파일을 다시 비교합니다."/>
      </MenuItem>
      <MenuItem Header="보기" Style="{StaticResource MenuHeaderItem}"><MenuItem x:Name="MenuProgressItem" Header="동기화 상태 창"/><MenuItem x:Name="MenuMessagesItem" Header="확인할 메시지"/><Separator/><MenuItem x:Name="TrashButton" Header="휴지통 관리"/></MenuItem>
      <MenuItem Header="도구" Style="{StaticResource MenuHeaderItem}"><MenuItem x:Name="SettingsButton" Header="환경설정"/><MenuItem x:Name="MenuCloudAccountsItem" Header="클라우드 계정"/></MenuItem>
      <MenuItem Header="도움말" Style="{StaticResource MenuHeaderItem}"><MenuItem x:Name="MenuAboutItem" Header="SafeSync 정보"/></MenuItem>
    </Menu>
    <Border Grid.Row="1" Background="{DynamicResource SafeSyncSubtleBrush}" BorderBrush="{DynamicResource SafeSyncBorderBrush}" BorderThickness="1,0,1,1" Padding="7" Margin="0,0,0,10">
      <DockPanel LastChildFill="False">
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
          <Button x:Name="AddButton" Style="{StaticResource CommandButton}" Content="＋ 새 작업" Background="{DynamicResource SafeSyncSurfaceBrush}"/>
          <Button x:Name="RunButton" Style="{StaticResource CommandButton}" Content="▶ 지금 백업" ToolTip="저장된 변경 목록만 빠르게 확인하여 백업합니다." Background="{DynamicResource SafeSyncAccentBrush}" Foreground="White" BorderBrush="{DynamicResource SafeSyncAccentBrush}"/>
          <Button x:Name="PauseButton" Style="{StaticResource CommandButton}" Content="Ⅱ 일시정지"/>
          <Button x:Name="RunAllButton" Style="{StaticResource CommandButton}" Content="▶▶ 모든 작업" ToolTip="모든 작업에서 변경된 파일만 빠르게 백업합니다."/>
          <Border Width="1" Height="24" Background="{DynamicResource SafeSyncBorderBrush}" Margin="5,3,8,3"/>
          <Button x:Name="ProgressButton" Style="{StaticResource CommandButton}" Content="동기화 상태" ToolTip="독립적인 동기화 상태 창을 열거나 닫습니다."/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" VerticalAlignment="Center">
          <Border Background="{DynamicResource SafeSyncSuccessSurfaceBrush}" BorderBrush="{DynamicResource SafeSyncSuccessSurfaceBrush}" BorderThickness="1" Padding="9,5" Margin="0,0,8,0">
            <TextBlock x:Name="ServiceBadge" Text="● 자동 감시 중" Foreground="{DynamicResource SafeSyncSuccessTextBrush}" FontWeight="SemiBold"/>
          </Border>
          <Button x:Name="NotificationsButton" Content="확인할 메시지" IsEnabled="False"/>
        </StackPanel>
      </DockPanel>
    </Border>
    <Border Grid.Row="2" Background="{DynamicResource SafeSyncSurfaceBrush}" BorderBrush="{DynamicResource SafeSyncBorderSoftBrush}" BorderThickness="1" Padding="1">
      <DataGrid x:Name="JobsGrid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" GridLinesVisibility="Horizontal" BorderThickness="0" RowHeight="42" HeadersVisibility="Column" Background="{DynamicResource SafeSyncSurfaceBrush}" Foreground="{DynamicResource SafeSyncTextBrush}" RowBackground="{DynamicResource SafeSyncSurfaceBrush}" AlternatingRowBackground="{DynamicResource SafeSyncSubtleBrush}" HorizontalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}" VerticalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}">
        <DataGrid.Columns>
          <DataGridTextColumn Header="작업 이름" Binding="{Binding Name}" Width="1.2*"/>
          <DataGridTextColumn Header="원본 위치" Binding="{Binding Source}" Width="2*"/>
          <DataGridTextColumn Header="백업 위치" Binding="{Binding Destination}" Width="2*"/>
          <DataGridTextColumn Header="실행 방식" Binding="{Binding TriggerText}" Width="1.2*"/>
          <DataGridTextColumn Header="상태" Binding="{Binding Status}" Width="1.1*"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>
    <GridSplitter x:Name="MainLayoutSplitter" Grid.Row="3" Height="6" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="{DynamicResource SafeSyncBorderBrush}" ShowsPreview="True" Cursor="SizeNS"/>
    <Grid Grid.Row="4" Margin="0,8,0,12">
      <Border Background="{DynamicResource SafeSyncActivityBrush}" BorderBrush="{DynamicResource SafeSyncBorderBrush}" BorderThickness="1" Padding="12">
        <DockPanel><TextBlock DockPanel.Dock="Top" Text="활동 기록" Foreground="{DynamicResource SafeSyncActivityMutedBrush}" FontWeight="SemiBold" Margin="0,0,0,8"/>
          <TextBox x:Name="ActivityBox" Background="Transparent" Foreground="{DynamicResource SafeSyncActivityTextBrush}" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
        </DockPanel>
      </Border>
    </Grid>
    <TextBlock Grid.Row="5" x:Name="FooterText" Text="준비됨" Foreground="{DynamicResource SafeSyncMutedBrush}" Margin="2,0,0,0" VerticalAlignment="Center"/>
  </Grid>
</Window>
'@

$script:Window = Load-Xaml $mainXaml

$progressXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SafeSync 비교 및 충돌 처리" Width="1180" Height="720" MinWidth="680" MinHeight="600"
        WindowStyle="ToolWindow" ShowInTaskbar="False" ShowActivated="False" ResizeMode="CanResizeWithGrip"
        Background="{DynamicResource SafeSyncWindowBrush}" FontFamily="Segoe UI, Malgun Gothic">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type Button}"><Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" RecognizesAccessKey="True"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.90"/></Trigger><Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.76"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="ButtonBorder" Property="Opacity" Value="0.46"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="DataGrid"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/></Style>
    <Style TargetType="DataGridRow"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="DataGridCell"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
    <Style TargetType="DataGridColumnHeadersPresenter"><Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/></Style>
    <Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/><Setter Property="BorderThickness" Value="0,0,1,1"/><Setter Property="Padding" Value="9,6"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type DataGridColumnHeader}"><Grid SnapsToDevicePixels="True"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentStringFormat="{TemplateBinding ContentStringFormat}" RecognizesAccessKey="True"/></Border><Thumb x:Name="PART_LeftHeaderGripper" HorizontalAlignment="Left" Width="4" Background="{TemplateBinding Background}" Cursor="SizeWE"/><Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="4" Background="{TemplateBinding Background}" Cursor="SizeWE"/><Border HorizontalAlignment="Right" Width="1" Background="{DynamicResource SafeSyncBorderSoftBrush}"/></Grid></ControlTemplate></Setter.Value></Setter></Style>
  </Window.Resources>
  <Grid Margin="16">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition x:Name="ProgressLockedRow" Height="125" MinHeight="70"/><RowDefinition Height="8"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Margin="2,0,2,12">
      <TextBlock Text="백업 비교 및 충돌 처리" FontSize="22" FontWeight="Bold" Foreground="{DynamicResource SafeSyncTextBrush}"/>
      <TextBlock Text="원본과 백업 위치를 나란히 확인하고, 충돌 파일은 다른 파일의 백업이 끝난 뒤 여기서 직접 처리할 수 있습니다." Foreground="{DynamicResource SafeSyncMutedBrush}" Margin="0,4,0,0" TextWrapping="Wrap"/>
    </StackPanel>
    <Border Grid.Row="1" Background="{DynamicResource SafeSyncSurfaceBrush}" BorderBrush="{DynamicResource SafeSyncBorderSoftBrush}" BorderThickness="1" CornerRadius="9" Padding="14" Margin="0,0,0,12">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <StackPanel>
          <TextBlock Text="원본" Foreground="{DynamicResource SafeSyncAccentBrush}" FontWeight="Bold"/>
          <TextBlock x:Name="SourceSummaryPath" Text="대기 중" Margin="0,7,0,2" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource SafeSyncTextBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding RelativeSource={RelativeSource Self},Path=Text}"/>
          <TextBlock x:Name="SourceSummaryDetail" Text="실행할 작업을 선택하세요." Foreground="{DynamicResource SafeSyncMutedBrush}" TextWrapping="Wrap"/>
        </StackPanel>
        <StackPanel Grid.Column="1" VerticalAlignment="Center" HorizontalAlignment="Center">
          <TextBlock Text="→" FontSize="32" Foreground="{DynamicResource SafeSyncAccentBrush}" HorizontalAlignment="Center"/>
          <TextBlock Text="백업" Foreground="{DynamicResource SafeSyncMutedBrush}" HorizontalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="백업 위치" Foreground="{DynamicResource SafeSyncSuccessTextBrush}" FontWeight="Bold"/>
          <TextBlock x:Name="DestinationSummaryPath" Text="대기 중" Margin="0,7,0,2" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource SafeSyncTextBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding RelativeSource={RelativeSource Self},Path=Text}"/>
          <TextBlock x:Name="DestinationSummaryDetail" Text="로컬·네트워크·클라우드 위치를 지원합니다." Foreground="{DynamicResource SafeSyncMutedBrush}" TextWrapping="Wrap"/>
        </StackPanel>
      </Grid>
    </Border>
    <StackPanel Grid.Row="2" Margin="0,0,0,10">
      <DockPanel Margin="2,0,2,6"><TextBlock Text="진행 중인 작업" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource SafeSyncTextBrush}"/><TextBlock x:Name="ActiveSummaryText" DockPanel.Dock="Right" Text="대기 중" Foreground="{DynamicResource SafeSyncMutedBrush}"/></DockPanel>
      <ScrollViewer MaxHeight="175" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <ItemsControl x:Name="ProgressItems">
        <ItemsControl.ItemTemplate>
          <DataTemplate>
            <Border Background="{DynamicResource SafeSyncSurfaceBrush}" BorderBrush="{DynamicResource SafeSyncBorderSoftBrush}" BorderThickness="1" CornerRadius="8" Padding="11" Margin="0,0,0,7">
              <StackPanel>
                <DockPanel>
                  <TextBlock DockPanel.Dock="Right" Text="{Binding ProgressText}" Foreground="{DynamicResource SafeSyncAccentBrush}" FontWeight="SemiBold"/>
                  <TextBlock Text="{Binding JobName}" FontWeight="SemiBold" Foreground="{DynamicResource SafeSyncTextBrush}" TextTrimming="CharacterEllipsis"/>
                </DockPanel>
                <TextBlock Text="{Binding StageText}" Margin="0,7,0,2" Foreground="{DynamicResource SafeSyncAccentDarkBrush}" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <TextBlock Text="{Binding DetailText}" Margin="0,0,0,5" Foreground="{DynamicResource SafeSyncMutedBrush}" TextWrapping="Wrap"/>
                <TextBlock Text="{Binding FolderText}" Margin="0,0,0,3" Foreground="{DynamicResource SafeSyncMutedBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding FolderText}"/>
                <TextBlock Text="{Binding FileText}" Margin="0,0,0,5" Foreground="{DynamicResource SafeSyncMutedBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding FileText}"/>
                <TextBlock Text="{Binding LocationText}" Margin="0,0,0,7" Foreground="{DynamicResource SafeSyncMutedBrush}" FontSize="11" TextWrapping="Wrap" ToolTip="{Binding LocationText}"/>
                <ProgressBar Height="9" Minimum="0" Maximum="100" Value="{Binding Percent}" Foreground="{DynamicResource SafeSyncAccentBrush}" Background="{DynamicResource SafeSyncSubtleBrush}"/>
              </StackPanel>
            </Border>
          </DataTemplate>
        </ItemsControl.ItemTemplate>
      </ItemsControl>
      </ScrollViewer>
    </StackPanel>
    <Grid Grid.Row="3" Margin="2,0,2,7">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel><TextBlock Text="사용 중이라 대기 중인 파일" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource SafeSyncTextBrush}"/><TextBlock x:Name="LockedSummaryText" Text="대기 중인 파일이 없습니다." Foreground="{DynamicResource SafeSyncMutedBrush}" Margin="0,2,0,0"/></StackPanel>
      <Button Grid.Column="1" x:Name="RetryLockedButton" Content="지금 다시 시도" Padding="12,6" VerticalAlignment="Center"/>
    </Grid>
    <DataGrid Grid.Row="4" x:Name="ProgressLockedGrid" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="True" SelectionMode="Extended" SelectionUnit="FullRow" HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowHeight="48" Background="{DynamicResource SafeSyncSurfaceBrush}" Foreground="{DynamicResource SafeSyncTextBrush}" BorderBrush="{DynamicResource SafeSyncBorderSoftBrush}" RowBackground="{DynamicResource SafeSyncSurfaceBrush}" AlternatingRowBackground="{DynamicResource SafeSyncSubtleBrush}" HorizontalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}" VerticalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}">
      <DataGrid.Columns>
        <DataGridTextColumn Header="작업 / 파일" Binding="{Binding FileDisplay}" Width="2.4*"/>
        <DataGridTextColumn Header="상태" Binding="{Binding StatusText}" Width="1.5*"/>
        <DataGridTextColumn Header="처음 대기" Binding="{Binding WaitingSince}" Width="145"/>
        <DataGridTextColumn Header="마지막 확인" Binding="{Binding LastAttempt}" Width="145"/>
        <DataGridTextColumn Header="재시도" Binding="{Binding RetryText}" Width="100"/>
      </DataGrid.Columns>
    </DataGrid>
    <GridSplitter x:Name="ProgressLayoutSplitter" Grid.Row="5" Height="6" HorizontalAlignment="Stretch" VerticalAlignment="Center" Background="{DynamicResource SafeSyncBorderBrush}" ShowsPreview="True" Cursor="SizeNS"/>
    <Grid Grid.Row="6" Margin="2,10,2,7">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel><TextBlock Text="확인이 필요한 충돌" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource SafeSyncTextBrush}"/><TextBlock x:Name="ConflictSummaryText" Text="충돌이 없습니다." Foreground="{DynamicResource SafeSyncMutedBrush}" Margin="0,2,0,0"/></StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="ConflictAllOverwriteButton" Content="모두 덮어쓰기" Padding="11,6" Margin="0,0,6,0"/>
        <Button x:Name="ConflictAllRenameButton" Content="모두 기존 파일 이름 변경" Padding="11,6" Margin="0,0,6,0"/>
        <Button x:Name="ConflictAllIgnoreButton" Content="모두 이번에는 변경 안 함" Padding="11,6"/>
      </StackPanel>
    </Grid>
    <DataGrid Grid.Row="7" x:Name="ProgressConflictGrid" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="False" SelectionMode="Extended" SelectionUnit="FullRow" HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowHeight="62" Background="{DynamicResource SafeSyncSurfaceBrush}" Foreground="{DynamicResource SafeSyncTextBrush}" BorderBrush="{DynamicResource SafeSyncBorderSoftBrush}" RowBackground="{DynamicResource SafeSyncSurfaceBrush}" AlternatingRowBackground="{DynamicResource SafeSyncSubtleBrush}" HorizontalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}" VerticalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}">
      <DataGrid.Columns>
        <DataGridTextColumn Header="작업 / 파일" Binding="{Binding FileDisplay}" Width="2.1*" IsReadOnly="True"/>
        <DataGridTextColumn Header="원본" Binding="{Binding SourceInfo}" Width="150" IsReadOnly="True"/>
        <DataGridTextColumn Header="현재 백업" Binding="{Binding BackupInfo}" Width="150" IsReadOnly="True"/>
        <DataGridTextColumn Header="충돌 이유" Binding="{Binding Reason}" Width="1.7*" IsReadOnly="True"/>
        <DataGridTemplateColumn Header="처리 방법" Width="330"><DataGridTemplateColumn.CellTemplate><DataTemplate><StackPanel Margin="4,3"><WrapPanel><Button Content="덮어쓰기" Tag="Overwrite" Padding="8,4" Margin="0,0,4,3"/><Button Content="기존 이름 변경 후 복사" Tag="RenameThenCopy" Padding="8,4" Margin="0,0,4,3"/><Button Content="변경 안 함" Tag="Ignore" Padding="8,4" Margin="0,0,0,3"/></WrapPanel><TextBlock Text="{Binding ActionLabel}" Foreground="{DynamicResource SafeSyncAccentBrush}" FontSize="11" FontWeight="SemiBold"/></StackPanel></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
      </DataGrid.Columns>
    </DataGrid>
    <Grid Grid.Row="8" Margin="2,10,2,0">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <TextBlock Text="기존 파일 이름 변경은 현재 백업 파일을 같은 위치에 .SafeSync-conflict-날짜 이름으로 남긴 뒤 원본을 복사합니다. 창을 닫아도 백업은 중단되지 않습니다." Foreground="{DynamicResource SafeSyncMutedBrush}" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Center"/>
      <Button Grid.Column="1" x:Name="ApplyConflictActionsButton" Content="선택한 처리 적용" Padding="18,9" Margin="14,0,0,0" Background="{DynamicResource SafeSyncAccentBrush}" Foreground="White" BorderBrush="{DynamicResource SafeSyncAccentBrush}" FontWeight="SemiBold"/>
    </Grid>
  </Grid>
</Window>
'@

$script:ProgressWindow = Load-Xaml $progressXaml
Apply-SafeSyncTheme
$script:MainJobsRow = $script:Window.FindName('MainJobsRow')
$script:MainActivityRow = $script:Window.FindName('MainActivityRow')
$script:MainLayoutSplitter = $script:Window.FindName('MainLayoutSplitter')
$script:ProgressItems = $script:ProgressWindow.FindName('ProgressItems')
$script:ProgressConflictGrid = $script:ProgressWindow.FindName('ProgressConflictGrid')
$script:ProgressLockedGrid = $script:ProgressWindow.FindName('ProgressLockedGrid')
$script:ProgressLockedRow = $script:ProgressWindow.FindName('ProgressLockedRow')
$script:ProgressLayoutSplitter = $script:ProgressWindow.FindName('ProgressLayoutSplitter')
$script:SourceSummaryPath = $script:ProgressWindow.FindName('SourceSummaryPath')
$script:SourceSummaryDetail = $script:ProgressWindow.FindName('SourceSummaryDetail')
$script:DestinationSummaryPath = $script:ProgressWindow.FindName('DestinationSummaryPath')
$script:DestinationSummaryDetail = $script:ProgressWindow.FindName('DestinationSummaryDetail')
$script:ActiveSummaryText = $script:ProgressWindow.FindName('ActiveSummaryText')
$script:ConflictSummaryText = $script:ProgressWindow.FindName('ConflictSummaryText')
$script:LockedSummaryText = $script:ProgressWindow.FindName('LockedSummaryText')
$script:ProgressConflictRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:ProgressConflictGrid.ItemsSource = $script:ProgressConflictRows
$script:ProgressLockedRows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
$script:ProgressLockedGrid.ItemsSource = $script:ProgressLockedRows
$script:PositioningProgressWindow = $false
$script:ProgressWindowPlaced = $false
$script:ProgressWindowUserHidden = $false
$script:ProgressWindowOpenRequested = $false
$script:ProgressWindowTransitioning = $false
$script:MainWindowTransitioning = $false
$script:RefreshingProgressWindow = $false
$script:ProgressRefreshQueued = $false
$script:LayoutSaveTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
$script:LayoutSaveTimer.Interval = [TimeSpan]::FromMilliseconds(500)

$layout = $script:Config.WindowLayout
$script:Window.Width = Get-SafeSyncLayoutNumber $layout 'MainWidth' 1080 900 2400
$script:Window.Height = Get-SafeSyncLayoutNumber $layout 'MainHeight' 720 580 1800
$script:MainActivityRow.Height = [System.Windows.GridLength]::new((Get-SafeSyncLayoutNumber $layout 'MainActivityHeight' 155 80 900))
$script:ProgressWindow.Width = Get-SafeSyncLayoutNumber $layout 'ProgressWidth' 1180 680 2600
$script:ProgressWindow.Height = Get-SafeSyncLayoutNumber $layout 'ProgressHeight' 720 600 1800
$script:ProgressLockedRow.Height = [System.Windows.GridLength]::new((Get-SafeSyncLayoutNumber $layout 'ProgressLockedHeight' 125 70 900))

function Save-SafeSyncWindowLayout {
    if ($null -eq $script:Config -or $null -eq $script:Window -or $null -eq $script:ProgressWindow) { return }
    if ($null -eq $script:Config.PSObject.Properties['WindowLayout'] -or $null -eq $script:Config.WindowLayout) {
        $script:Config | Add-Member -NotePropertyName WindowLayout -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $layout = $script:Config.WindowLayout
    foreach ($item in @(
        @{Name='MainWidth';Value=$script:Window.Width}, @{Name='MainHeight';Value=$script:Window.Height},
        @{Name='MainActivityHeight';Value=$script:MainActivityRow.ActualHeight},
        @{Name='ProgressWidth';Value=$script:ProgressWindow.Width}, @{Name='ProgressHeight';Value=$script:ProgressWindow.Height},
        @{Name='ProgressLockedHeight';Value=$script:ProgressLockedRow.ActualHeight}
    )) {
        if ($null -eq $layout.PSObject.Properties[$item.Name]) { $layout | Add-Member -NotePropertyName $item.Name -NotePropertyValue ([double]$item.Value) -Force }
        else { $layout.($item.Name) = [double]$item.Value }
    }
    try { Save-Config $script:Config } catch { Write-AppLog "창 크기 설정 저장 실패: $($_.Exception.Message)" 'WARN' }
}

function Request-SafeSyncWindowLayoutSave {
    if ($null -eq $script:LayoutSaveTimer) { Save-SafeSyncWindowLayout; return }
    $script:LayoutSaveTimer.Stop()
    $script:LayoutSaveTimer.Start()
}

$script:LayoutSaveTimer.Add_Tick({ $script:LayoutSaveTimer.Stop(); Save-SafeSyncWindowLayout })

function Format-ProgressFileSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-SafeSyncConflictReasonText([string]$Reason) {
    switch ($Reason) {
        'Modified time matches but cloud file size differs.' { return '수정 시간은 같지만 클라우드 파일의 크기가 다릅니다.' }
        'Cloud file is newer than the source.' { return '백업 위치의 클라우드 파일이 원본보다 최신입니다.' }
        'Source and cloud file metadata differs.' { return '원본과 클라우드 파일의 시간 또는 크기가 다릅니다.' }
        default { return $Reason }
    }
}

function Set-SafeSyncProgressRoute([object]$Job) {
    if ($null -eq $Job) {
        $script:SourceSummaryPath.Text = '대기 중'
        $script:SourceSummaryDetail.Text = '실행 중인 작업이나 선택한 충돌 파일이 없습니다.'
        $script:DestinationSummaryPath.Text = '대기 중'
        $script:DestinationSummaryDetail.Text = '백업 작업이 시작되면 위치가 여기에 표시됩니다.'
        return
    }
    $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
    # CloudFolderId is required for API calls, but the UI should show the
    # human-readable label saved in Destination (for example, "내 드라이브 / Backup").
    $destinationPath = if ($destinationType -eq 'Local') { [string]$Job.Destination } elseif (-not [string]::IsNullOrWhiteSpace([string]$Job.Destination)) { [string]$Job.Destination } elseif ($null -ne $Job.PSObject.Properties['CloudFolderId']) { [string]$Job.CloudFolderId } else { '' }
    $destinationLabel = switch ($destinationType) { 'Dropbox' {'Dropbox 클라우드 폴더'} 'GoogleDrive' {'Google Drive 클라우드 폴더'} default {'로컬 또는 네트워크 백업 위치'} }
    $script:SourceSummaryPath.Text = [string]$Job.Source
    $script:SourceSummaryDetail.Text = "'$([string]$Job.Name)' 원본 폴더"
    $script:DestinationSummaryPath.Text = $destinationPath
    $script:DestinationSummaryDetail.Text = $destinationLabel
}

function Refresh-ProgressConflictRows {
    $savedActions = @{}
    foreach ($row in @($script:ProgressConflictRows)) { $savedActions[[string]$row.Key] = [string]$row.Action }
    $script:ProgressConflictRows.Clear()
    foreach ($notice in @($script:PendingNotices | Where-Object { [string]$_.Type -eq 'Conflict' })) {
        $job = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$notice.JobId } | Select-Object -First 1
        if ($null -eq $job) { continue }
        $destinationType = if ($null -ne $job.PSObject.Properties['DestinationType']) { [string]$job.DestinationType } else { 'Local' }
        $destinationRoot = if ($destinationType -eq 'Local') { [string]$job.Destination } else { [string]$job.CloudFolderId }
        foreach ($item in @($notice.Conflicts)) {
            $file = ConvertTo-SafeSyncRelativePath ([string]$item.File)
            $reason = Get-SafeSyncConflictReasonText ([string]$item.Reason)
            $key = "$([string]$notice.JobId)|$file|$([string]$item.Reason)"
            $action = if ($savedActions.ContainsKey($key)) { [string]$savedActions[$key] } else { 'Ignore' }
            $actionLabel = switch($action){'Overwrite'{'선택: 원본으로 덮어쓰기'}'RenameThenCopy'{'선택: 기존 백업 이름 변경 후 복사'}default{'선택: 이번에는 변경 안 함'}}
            $backupPath = if ($destinationType -eq 'Local') { Join-Path $destinationRoot $file.Replace('/','\') } else { "$destinationRoot/$file".Replace('//','/') }
            $sourcePath = Join-Path ([string]$job.Source) $file.Replace('/','\')
            $script:ProgressConflictRows.Add([pscustomobject]@{
                Key=$key; JobId=[string]$notice.JobId; JobName=[string]$notice.JobName; File=$file
                FileDisplay="$([string]$notice.JobName)`r`n$file"; Reason=$reason
                SourceInfo="$(Format-ProgressFileSize ([long]$item.SourceSize))`r`n$([string]$item.SourceModified)"
                BackupInfo="$(Format-ProgressFileSize ([long]$item.BackupSize))`r`n$([string]$item.BackupModified)"
                SourcePath=$sourcePath; BackupPath=$backupPath; Action=$action; ActionLabel=$actionLabel
            })
        }
    }
    $script:ConflictSummaryText.Text = if ($script:ProgressConflictRows.Count -gt 0) { "$($script:ProgressConflictRows.Count)개 파일은 사용자의 결정이 필요합니다. 각 행에서 처리 방법을 고른 뒤 적용하세요." } else { '충돌이 없습니다.' }
    foreach ($name in @('ConflictAllOverwriteButton','ConflictAllRenameButton','ConflictAllIgnoreButton','ApplyConflictActionsButton')) {
        $control = $script:ProgressWindow.FindName($name)
        if ($null -ne $control) { $control.IsEnabled = $script:ProgressConflictRows.Count -gt 0 }
    }
}

function Format-SafeSyncLocalTime([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '-' }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Value, [ref]$parsed)) { return '-' }
    return $parsed.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
}

function Refresh-SafeSyncLockedRows {
    $selectedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($selected in @($script:ProgressLockedGrid.SelectedItems)) { [void]$selectedKeys.Add([string]$selected.Key) }
    $script:ProgressLockedRows.Clear()
    foreach ($item in @($script:LockedFiles.Values | Sort-Object JobName,File)) {
        $row = [pscustomobject]@{
            Key=[string]$item.Key; JobId=[string]$item.JobId; JobName=[string]$item.JobName; File=[string]$item.File
            FileDisplay="$([string]$item.JobName)`r`n$([string]$item.File)"
            StatusText='다른 프로그램에서 사용 중 · 자동 재시도 대기'
            WaitingSince=(Format-SafeSyncLocalTime ([string]$item.LockedSinceUtc))
            LastAttempt=(Format-SafeSyncLocalTime ([string]$item.LastAttemptUtc))
            RetryText="$([int]$item.LockRetryCount)회"
        }
        $script:ProgressLockedRows.Add($row)
        if ($selectedKeys.Contains([string]$row.Key)) { [void]$script:ProgressLockedGrid.SelectedItems.Add($row) }
    }
    $count = $script:ProgressLockedRows.Count
    $script:LockedSummaryText.Text = if ($count -gt 0) { "${count}개 파일을 다른 작업과 충돌 없이 주기적으로 다시 확인합니다. 일반 오류 알림에는 포함하지 않습니다." } else { '대기 중인 파일이 없습니다.' }
    $script:ProgressWindow.FindName('RetryLockedButton').IsEnabled = $count -gt 0
    Update-SafeSyncProgressButton
}

function Refresh-SafeSyncLockedFilesForJob([object]$Job) {
    if ($null -eq $Job) { return 0 }
    $jobId = [string]$Job.Id
    $prefix = "$jobId|"
    foreach ($key in @($script:LockedFiles.Keys | Where-Object { ([string]$_).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) })) { [void]$script:LockedFiles.Remove($key) }
    $state = Get-SafeSyncState $jobId
    foreach ($entry in @($state.Entries.Values | Where-Object { [string]$_.Status -eq 'Locked' })) {
        $relative = ConvertTo-SafeSyncRelativePath ([string]$entry.RelativePath)
        $key = "$jobId|$($relative.ToLowerInvariant())"
        $script:LockedFiles[$key] = [pscustomobject]@{
            Key=$key; JobId=$jobId; JobName=[string]$Job.Name; File=$relative
            LockedSinceUtc=if($null -ne $entry.PSObject.Properties['LockedSinceUtc']){[string]$entry.LockedSinceUtc}else{[string]$entry.LastAttemptUtc}
            LastAttemptUtc=[string]$entry.LastAttemptUtc
            LockRetryCount=if($null -ne $entry.PSObject.Properties['LockRetryCount']){[int]$entry.LockRetryCount}else{1}
        }
    }
    Refresh-SafeSyncLockedRows
    return @($script:LockedFiles.Values | Where-Object { [string]$_.JobId -eq $jobId }).Count
}

function Remove-SafeSyncLockedFilesForJob([string]$JobId) {
    $prefix = "$JobId|"
    foreach ($key in @($script:LockedFiles.Keys | Where-Object { ([string]$_).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) })) { [void]$script:LockedFiles.Remove($key) }
    [void]$script:LockedRetryAt.Remove($JobId)
    [void]$script:LockedRetryDelaySeconds.Remove($JobId)
    Refresh-SafeSyncLockedRows
}

function Initialize-SafeSyncLockedFiles {
    foreach ($job in @($script:Config.Jobs)) {
        $count = [int](Refresh-SafeSyncLockedFilesForJob $job)
        if ($count -gt 0) {
            $script:LockedRetryDelaySeconds[[string]$job.Id] = 30
            $script:LockedRetryAt[[string]$job.Id] = (Get-Date).AddSeconds(30)
        }
    }
}

function Set-SafeSyncConflictRowAction([object]$Row,[string]$Action) {
    if ($null -eq $Row) { return }
    $Row.Action = $Action
    $Row.ActionLabel = switch($Action){'Overwrite'{'선택: 원본으로 덮어쓰기'}'RenameThenCopy'{'선택: 기존 백업 이름 변경 후 복사'}default{'선택: 이번에는 변경 안 함'}}
}

function Remove-SafeSyncPendingConflictFiles([string]$JobId,[string[]]$Files) {
    $fileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Files)) { [void]$fileSet.Add((ConvertTo-SafeSyncRelativePath ([string]$file))) }
    $keptNotices = New-Object System.Collections.ArrayList
    foreach ($notice in @($script:PendingNotices)) {
        if ([string]$notice.Type -ne 'Conflict' -or [string]$notice.JobId -ne $JobId) { [void]$keptNotices.Add($notice); continue }
        $remaining = @($notice.Conflicts | Where-Object { -not $fileSet.Contains((ConvertTo-SafeSyncRelativePath ([string]$_.File))) })
        if ($remaining.Count -gt 0) {
            [void]$keptNotices.Add([pscustomobject]@{Type='Conflict';JobId=[string]$notice.JobId;JobName=[string]$notice.JobName;Conflicts=[object[]]$remaining;Errors=@();CreatedAt=[string]$notice.CreatedAt})
        }
    }
    $script:PendingNotices = $keptNotices
    Save-SafeSyncNotificationState
    Update-SafeSyncNoticeIndicator
}

function Get-ProgressStageText([string]$Stage) {
    switch ($Stage) {
        'Connecting to Dropbox' { return 'Dropbox 연결 중' }
        'Checking Dropbox recovery' { return 'Dropbox 이전 작업 확인 중' }
        'Scanning Dropbox files' { return 'Dropbox 파일 목록 확인 중' }
        'Preparing changed Dropbox files' { return 'Dropbox 변경 파일 확인 중' }
        'Reading Dropbox change feed' { return 'Dropbox 변경 기록 확인 중' }
        'Dropbox change feed reset' { return 'Dropbox 전체 검사 전환 중' }
        'Scanning source for Dropbox' { return 'Dropbox와 비교할 원본 폴더 확인 중' }
        'Comparing Dropbox files' { return 'Dropbox 파일 비교 중' }
        'Preparing Dropbox upload' { return 'Dropbox 업로드 준비 중' }
        'Uploading to Dropbox staging' { return 'Dropbox 전송 중' }
        'Verifying Dropbox upload' { return 'Dropbox 전송 검증 중' }
        'Publishing Dropbox file' { return 'Dropbox 파일 교체 중' }
        'Backing up to Dropbox' { return 'Dropbox에 백업 중' }
        'Cleaning Dropbox trash' { return 'Dropbox 휴지통 정리 중' }
        'Connecting to Google Drive' { return 'Google Drive 연결 중' }
        'Checking Google Drive recovery' { return 'Google Drive 이전 작업 확인 중' }
        'Preparing saved changes' { return '저장된 변경 목록 준비 중' }
        'Scanning Google Drive files' { return 'Google Drive 파일 목록 확인 중' }
        'Preparing changed Google Drive files' { return 'Google Drive 변경 파일 확인 중' }
        'Reading Google Drive change feed' { return 'Google Drive 변경 기록 확인 중' }
        'Google Drive change feed reset' { return 'Google Drive 전체 검사 전환 중' }
        'Scanning source for Google Drive' { return 'Google Drive와 비교할 원본 폴더 확인 중' }
        'Comparing Google Drive files' { return 'Google Drive 파일 비교 중' }
        'Preparing Google Drive upload' { return 'Google Drive 업로드 준비 중' }
        'Uploading to Google Drive staging' { return 'Google Drive 전송 중' }
        'Verifying Google Drive upload' { return 'Google Drive 전송 검증 중' }
        'Publishing Google Drive file' { return 'Google Drive 파일 교체 중' }
        'Backing up to Google Drive' { return 'Google Drive에 백업 중' }
        'Cleaning Google Drive trash' { return 'Google Drive 휴지통 정리 중' }
        default { return $Stage }
    }
}

function Get-ProgressDetailText([string]$Stage,[string]$Detail) {
    if(-not [string]::IsNullOrWhiteSpace($Detail)){return $Detail}
    switch($Stage){
        'Connecting to Dropbox' {return '저장된 계정 정보로 Dropbox 접근 권한을 요청하고 있습니다.'}
        'Checking Dropbox recovery' {return '중단된 전송이나 파일 교체 작업이 있는지 확인하고 있습니다.'}
        'Scanning Dropbox files' {return 'Dropbox 백업 폴더의 파일 목록을 불러오고 있습니다.'}
        'Preparing changed Dropbox files' {return '변경된 파일의 Dropbox 정보를 확인하고 있습니다.'}
        'Reading Dropbox change feed' {return '저장된 커서 이후 변경된 Dropbox 항목만 확인하고 있습니다.'}
        'Dropbox change feed reset' {return '변경 기록이 만료되어 안전한 전체 검사로 전환합니다.'}
        'Scanning source for Dropbox' {return 'Dropbox와 비교할 원본 파일을 현재 폴더에서 찾고 있습니다.'}
        'Comparing Dropbox files' {return '원본과 Dropbox 파일의 시간·크기를 비교하고 있습니다.'}
        'Preparing Dropbox upload' {return '원본 파일의 안전한 임시 사본과 체크섬을 만들고 있습니다.'}
        'Uploading to Dropbox staging' {return '검증 전용 임시 위치로 파일을 전송하고 있습니다.'}
        'Verifying Dropbox upload' {return '클라우드에 저장된 파일의 크기와 체크섬을 확인하고 있습니다.'}
        'Publishing Dropbox file' {return '기존 백업을 휴지통에 보관한 뒤 검증된 파일을 반영하고 있습니다.'}
        'Cleaning Dropbox trash' {return '삭제된 파일을 SafeSync 휴지통으로 옮기고 보관 기간을 확인합니다.'}
        'Connecting to Google Drive' {return '저장된 계정 정보로 Google Drive 접근 권한을 요청하고 있습니다.'}
        'Checking Google Drive recovery' {return '중단된 전송이나 파일 교체 작업이 있는지 확인하고 있습니다.'}
        'Preparing saved changes' {return '스냅샷에서 변경되었거나 이전에 실패한 파일만 빠르게 모으고 있습니다.'}
        'Scanning Google Drive files' {return 'Google Drive 백업 폴더의 파일 목록을 불러오고 있습니다.'}
        'Preparing changed Google Drive files' {return '변경된 파일의 Google Drive 정보를 확인하고 있습니다.'}
        'Reading Google Drive change feed' {return '저장된 토큰 이후 변경된 Google Drive 항목만 확인하고 있습니다.'}
        'Google Drive change feed reset' {return '변경 기록을 이어갈 수 없어 안전한 전체 검사로 전환합니다.'}
        'Scanning source for Google Drive' {return 'Google Drive와 비교할 원본 파일을 현재 폴더에서 찾고 있습니다.'}
        'Comparing Google Drive files' {return '원본과 Google Drive 파일의 시간·크기를 비교하고 있습니다.'}
        'Preparing Google Drive upload' {return '원본 파일의 안전한 임시 사본과 체크섬을 만들고 있습니다.'}
        'Uploading to Google Drive staging' {return '검증 전용 임시 위치로 파일을 전송하고 있습니다.'}
        'Verifying Google Drive upload' {return '클라우드에 저장된 파일의 크기와 체크섬을 확인하고 있습니다.'}
        'Publishing Google Drive file' {return '기존 백업을 휴지통에 보관한 뒤 검증된 파일을 반영하고 있습니다.'}
        'Cleaning Google Drive trash' {return '삭제된 파일을 SafeSync 휴지통으로 옮기고 보관 기간을 확인합니다.'}
        default{return ''}
    }
}

function Sync-ProgressWindowPlacement {
    if ($script:ProgressWindowPlaced -or $script:PositioningProgressWindow -or -not $script:Window.IsVisible) { return }
    $script:PositioningProgressWindow = $true
    try {
        $gap = 10.0
        $workLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
        $workTop = [System.Windows.SystemParameters]::VirtualScreenTop
        $workRight = $workLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
        $workBottom = $workTop + [System.Windows.SystemParameters]::VirtualScreenHeight
        $left = $script:Window.Left + $script:Window.ActualWidth + $gap
        if ($left + $script:ProgressWindow.Width -gt $workRight) { $left = [Math]::Max($workLeft, $script:Window.Left - $gap - $script:ProgressWindow.Width) }
        $script:ProgressWindow.Left = $left
        $script:ProgressWindow.Top = [Math]::Max($workTop, [Math]::Min($script:Window.Top, $workBottom - $script:ProgressWindow.MinHeight))
        $availableHeight = [System.Windows.SystemParameters]::VirtualScreenHeight - ($script:ProgressWindow.Top - [System.Windows.SystemParameters]::VirtualScreenTop) - 24
        $script:ProgressWindow.Height = [Math]::Max($script:ProgressWindow.MinHeight, [Math]::Min(420, $availableHeight))
        $script:ProgressWindowPlaced = $true
    }
    finally { $script:PositioningProgressWindow = $false }
}

function Update-SafeSyncProgressButton {
    if ($null -eq $script:ProgressButton) { return }
    $lockedText = if ($script:LockedFiles.Count -gt 0) { " · 사용 중 $($script:LockedFiles.Count)" } else { '' }
    $script:ProgressButton.Content = if ($script:ProgressWindow.IsVisible) { "동기화 상태 닫기$lockedText" } else { "동기화 상태 보기$lockedText" }
}

function Set-SafeSyncProgressWindowVisibility([bool]$Visible,[bool]$Activate=$false) {
    # Window.Show() pumps WPF messages. A timer or IsVisibleChanged handler can
    # therefore re-enter this code before Show() has finished and try to attach
    # the same VisualTarget twice. Serialize all progress-window transitions.
    if ($script:ProgressWindowTransitioning) { return }
    $script:ProgressWindowTransitioning = $true
    try {
        if ($Visible) {
            if (-not $script:ProgressWindow.IsVisible) {
                Sync-ProgressWindowPlacement
                $script:ProgressWindow.Show()
            }
            $script:ProgressWindow.Topmost = $false
            if ($Activate) { [void]$script:ProgressWindow.Activate() }
        }
        elseif ($script:ProgressWindow.IsVisible) {
            $script:ProgressWindow.Hide()
        }
    }
    finally {
        $script:ProgressWindowTransitioning = $false
        Update-SafeSyncProgressButton
    }
}

function Show-SafeSyncProgressWindow {
    $script:ProgressWindowUserHidden = $false
    $script:ProgressWindowOpenRequested = $true
    Set-SafeSyncProgressWindowVisibility $true $true
}

function Hide-SafeSyncProgressWindow {
    $script:ProgressWindowUserHidden = $true
    $script:ProgressWindowOpenRequested = $false
    Set-SafeSyncProgressWindowVisibility $false
}

function Toggle-SafeSyncProgressWindow {
    if ($script:ProgressWindow.IsVisible) { Hide-SafeSyncProgressWindow } else { Show-SafeSyncProgressWindow }
}

function Refresh-ProgressWindow {
    if ($script:RefreshingProgressWindow) { return }
    $script:RefreshingProgressWindow = $true
    try {
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $displayJobs = @{}
    $routeJob = $null
    foreach($id in @($script:ReconciliationJobs.Keys)){$displayJobs[$id]=$script:ReconciliationJobs[$id]}
    foreach($id in @($script:RunningJobs.Keys)){$displayJobs[$id]=$script:RunningJobs[$id]}
    foreach ($id in @($displayJobs.Keys)) {
        $running = $displayJobs[$id]
        if ($null -eq $routeJob) { $routeJob = $running.Job }
        $progress = $null
        $path = Join-Path $script:ProgressRoot "$id.json"
        if (Test-Path -LiteralPath $path) {
            try { $progress = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        }
        if ($null -eq $progress) {
            $preparingText = if($script:ReconciliationJobs.ContainsKey($id)){'시작 시 변경된 파일을 확인할 준비를 하고 있습니다.'}else{'백업 프로세스를 준비하고 있습니다.'}
            $items.Add([pscustomobject]@{ JobName=[string]$running.Job.Name;StageText='준비 중';DetailText=$preparingText;FolderText="원본: $([string]$running.Job.Source)";FileText='';LocationText='';ProgressText='준비 중';Percent=0.0 })
            continue
        }
        $total = [int]$progress.TotalFiles
        $completed = [int]$progress.CompletedFiles
        $progressText = if ($total -gt 0) { "$completed / $total  ·  $([Math]::Round([double]$progress.Percent))%" } else { '확인 중' }
        $stageText = Get-ProgressStageText ([string]$progress.Stage)
        $rawDetail = if($null -ne $progress.PSObject.Properties['Detail']){[string]$progress.Detail}else{''}
        $detailText = Get-ProgressDetailText ([string]$progress.Stage) $rawDetail
        $currentFolderValue=if($null -ne $progress.PSObject.Properties['CurrentFolder']){[string]$progress.CurrentFolder}else{''}
        if($currentFolderValue -eq '(root)'){$currentFolderValue='(최상위 폴더)'}
        $folderText = if(-not [string]::IsNullOrWhiteSpace($currentFolderValue)){"현재 폴더: $currentFolderValue"}else{''}
        $fileText = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$progress.CurrentFile)) {
            $fileText = "현재 파일: $($progress.CurrentFile) ($(Format-ProgressFileSize ([long]$progress.CurrentFileSize)))"
        }
        $sourceLocation=if($null -ne $progress.PSObject.Properties['SourceLocation']){[string]$progress.SourceLocation}else{[string]$running.Job.Source}
        $destinationLocation=if($null -ne $progress.PSObject.Properties['DestinationLocation']){[string]$progress.DestinationLocation}else{[string]$running.Job.Destination}
        $destinationType=if($null -ne $progress.PSObject.Properties['DestinationType']){[string]$progress.DestinationType}else{'Local'}
        $destinationLabel=switch($destinationType){'Dropbox'{'Dropbox'}'GoogleDrive'{'Google Drive'}default{'백업 위치'}}
        $locationText="원본: $sourceLocation`r`n$destinationLabel`: $destinationLocation"
        $items.Add([pscustomobject]@{JobName=[string]$progress.JobName;StageText=$stageText;DetailText=$detailText;FolderText=$folderText;FileText=$fileText;LocationText=$locationText;ProgressText=$progressText;Percent=[double]$progress.Percent})
    }
    $script:ProgressItems.ItemsSource = $items
    $script:ActiveSummaryText.Text = if ($items.Count -gt 0) { "$($items.Count)개 작업 실행 중" } else { '진행 중인 작업 없음' }
    $selectedConflict = $script:ProgressConflictGrid.SelectedItem
    $selectedLocked = $script:ProgressLockedGrid.SelectedItem
    if ($null -eq $routeJob -and $null -ne $selectedConflict) { $routeJob = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$selectedConflict.JobId } | Select-Object -First 1 }
    if ($null -eq $routeJob -and $null -ne $selectedLocked) { $routeJob = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$selectedLocked.JobId } | Select-Object -First 1 }
    if ($null -eq $routeJob -and $script:ProgressConflictRows.Count -gt 0) { $routeJob = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$script:ProgressConflictRows[0].JobId } | Select-Object -First 1 }
    if ($null -eq $routeJob -and $script:ProgressLockedRows.Count -gt 0) { $routeJob = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$script:ProgressLockedRows[0].JobId } | Select-Object -First 1 }
    Set-SafeSyncProgressRoute $routeJob
    $autoShow = ($items.Count -gt 0 -or $script:ProgressConflictRows.Count -gt 0) -and -not $script:ProgressWindowUserHidden
    $shouldShow = ($autoShow -or $script:ProgressWindowOpenRequested) -and $script:Window.IsVisible -and $script:Window.WindowState -ne [System.Windows.WindowState]::Minimized
    Set-SafeSyncProgressWindowVisibility $shouldShow
    }
    finally { $script:RefreshingProgressWindow = $false }
}

function Request-SafeSyncProgressRefresh {
    # Coalesce frequent progress notifications and run them below user input.
    # Backup workers remain separate processes; this keeps window move/minimize,
    # buttons, and tray commands responsive even during large cloud batches.
    if ($script:ProgressRefreshQueued) { return }
    $script:ProgressRefreshQueued = $true
    $refreshAction = [action]{
        $script:ProgressRefreshQueued = $false
        Refresh-ProgressWindow
    }
    try { [void]$script:Window.Dispatcher.BeginInvoke($refreshAction,[System.Windows.Threading.DispatcherPriority]::Background) }
    catch { $script:ProgressRefreshQueued = $false }
}

function Find-Control([string]$Name) { return $script:Window.FindName($Name) }
$script:JobsGrid = Find-Control 'JobsGrid'
$script:ActivityBox = Find-Control 'ActivityBox'
$script:FooterText = Find-Control 'FooterText'
$script:NotificationsButton = Find-Control 'NotificationsButton'
$script:EditButton = Find-Control 'EditButton'
$script:DeleteButton = Find-Control 'DeleteButton'
$script:PauseButton = Find-Control 'PauseButton'
$script:RunButton = Find-Control 'RunButton'
$script:FullScanButton = Find-Control 'FullScanButton'
$script:ProgressButton = Find-Control 'ProgressButton'
$script:TrashButton = Find-Control 'TrashButton'

function Add-Activity([string]$Text) {
    $line = "$(Get-Date -Format 'HH:mm:ss')  $Text"
    if ([string]::IsNullOrWhiteSpace($script:ActivityBox.Text)) { $script:ActivityBox.Text = $line }
    else { $script:ActivityBox.Text = "$line`r`n$($script:ActivityBox.Text)" }
    Write-AppLog $Text
}

function Get-TriggerText([object]$Job) {
    if ([string]$Job.TriggerType -eq 'Realtime') { return '파일 변경 시' }
    return "매일 $([string]$Job.ScheduleTime)"
}

function Test-SafeSyncJobPaused([object]$Job) {
    return $null -ne $Job -and $null -ne $Job.PSObject.Properties['Paused'] -and [bool]$Job.Paused
}

function Refresh-JobsGrid {
    $selectedId = if ($null -ne $script:JobsGrid.SelectedItem) { [string]$script:JobsGrid.SelectedItem.Id } else { '' }
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($job in @($script:Config.Jobs)) {
        $status = if (Test-SafeSyncJobPaused $job) { '일시정지' } elseif ($script:RunningJobs.ContainsKey([string]$job.Id)) { '백업 중' } elseif ($script:LastStatus.ContainsKey([string]$job.Id)) { $script:LastStatus[[string]$job.Id] } else { '대기 중' }
        $items.Add([pscustomobject]@{ Id=[string]$job.Id; Name=[string]$job.Name; Source=[string]$job.Source; Destination=[string]$job.Destination; TriggerText=(Get-TriggerText $job); Status=$status })
    }
    $script:JobsGrid.ItemsSource = $items
    if (-not [string]::IsNullOrWhiteSpace($selectedId)) {
        $script:JobsGrid.SelectedItem = @($items | Where-Object { [string]$_.Id -eq $selectedId } | Select-Object -First 1)[0]
    }
    $script:FooterText.Text = "등록된 작업 $($items.Count)개 · 휴지통 $($script:Config.TrashRetentionDays)일 보관"
    Update-JobActionButtons
}

function Get-SafeSyncVisualAncestor([object]$Element,[type]$TargetType) {
    $current = $Element
    while ($null -ne $current) {
        if ($current -is $TargetType) { return $current }
        if ($current -is [System.Windows.DependencyObject]) { $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current) } else { break }
    }
    return $null
}

function Open-SafeSyncJobFolder([object]$Job,[string]$Side) {
    if ($null -eq $Job) { return }
    $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
    if ($Side -eq 'Destination' -and $destinationType -ne 'Local') {
        [System.Windows.MessageBox]::Show($script:Window, 'Dropbox API와 Google Drive API 백업 위치는 Windows 탐색기 폴더가 아닙니다. 클라우드 계정과 폴더는 작업 수정 화면에서 확인할 수 있습니다.', '탐색기에서 열기', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }
    $path = if ($Side -eq 'Source') { [string]$Job.Source } else { [string]$Job.Destination }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        [System.Windows.MessageBox]::Show($script:Window, "폴더에 접근할 수 없습니다.`r`n$path", '탐색기에서 열기', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList @($path) | Out-Null }
    catch { [System.Windows.MessageBox]::Show($script:Window, $_.Exception.Message, '탐색기에서 열기 오류', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null }
}

function Show-ApplicationSettings {
    $settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SafeSync 환경설정" Width="560" Height="580" MinHeight="440" ResizeMode="CanResize" WindowStartupLocation="CenterOwner"
        Background="{DynamicResource SafeSyncWindowBrush}" FontFamily="Segoe UI, Malgun Gothic">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Padding" Value="18,8"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type CheckBox}"><Grid SnapsToDevicePixels="True"><Grid.ColumnDefinitions><ColumnDefinition Width="18"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Border x:Name="CheckBoxBorder" Width="14" Height="14" Margin="0,1,4,0" VerticalAlignment="Top" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="2"/><Path x:Name="CheckMark" Grid.Column="0" Data="M 3,7 L 6,10 L 12,3" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Top" Margin="0,1,4,0" Visibility="Collapsed"/><ContentPresenter Grid.Column="1" Margin="2,0,0,0" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentStringFormat="{TemplateBinding ContentStringFormat}" RecognizesAccessKey="True"/></Grid><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="CheckBoxBorder" Property="Background" Value="{DynamicResource SafeSyncAccentBrush}"/><Setter TargetName="CheckBoxBorder" Property="BorderBrush" Value="{DynamicResource SafeSyncAccentBrush}"/><Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="{DynamicResource SafeSyncInputBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/></Style>
    <Style TargetType="ScrollViewer"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="ScrollBar"><Setter Property="Background" Value="{DynamicResource SafeSyncSubtleBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ScrollBar}"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"><Track x:Name="PART_Track" IsDirectionReversed="True"><Track.Thumb><Thumb Background="{DynamicResource SafeSyncMutedBrush}"><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Border Background="{TemplateBinding Background}" Margin="2" CornerRadius="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Border></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="RadioButton"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="Margin" Value="0,0,12,0"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type GroupBox}"><Grid SnapsToDevicePixels="True"><Border Margin="0,8,0,0" Padding="{TemplateBinding Padding}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3"><ContentPresenter Margin="0,7,0,0" ContentSource="Content"/></Border><Border Background="{DynamicResource SafeSyncWindowBrush}" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="12,0,0,0" Padding="4,0"><ContentPresenter ContentSource="Header" RecognizesAccessKey="True"/></Border></Grid></ControlTemplate></Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="24">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,18">
      <TextBlock Text="환경설정" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource SafeSyncTextBrush}"/>
      <TextBlock Text="자동 실행, 파일 보호 정책 및 화면 모드를 관리합니다." Foreground="{DynamicResource SafeSyncMutedBrush}" Margin="0,5,0,0"/>
    </StackPanel>
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,0,0,8">
    <StackPanel>
    <GroupBox Header="보호 설정" Padding="16" Margin="0,0,0,14">
      <StackPanel>
        <CheckBox x:Name="AutoStartCheck" Content="Windows 로그인 시 SafeSync 자동 시작" Margin="0,2,0,14"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="150"/><ColumnDefinition Width="70"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="휴지통 보관 기간" VerticalAlignment="Center"/>
          <TextBox x:Name="RetentionBox" Grid.Column="1" Padding="7,5" HorizontalContentAlignment="Right"/>
          <TextBlock Grid.Column="2" Text="일 (1~3650일)" Margin="9,0,0,0" VerticalAlignment="Center" Foreground="{DynamicResource SafeSyncMutedBrush}"/>
        </Grid>
        <TextBlock Text="교체되거나 삭제된 백업 파일을 지정한 기간 동안 SafeSync 휴지통에 보관합니다." TextWrapping="Wrap" Foreground="{DynamicResource SafeSyncMutedBrush}" Margin="0,11,0,0"/>
        <CheckBox x:Name="SoundOnMinimizeCheck" Content="창을 최소화하거나 알림 영역으로 보낼 때 알림음 재생" Margin="0,14,0,5"/>
        <CheckBox x:Name="SoundOnBackupCompleteCheck" Content="백업이 정상적으로 완료됐을 때 알림음 재생" Margin="0,0,0,5"/>
        <CheckBox x:Name="SoundOnBackupErrorCheck" Content="백업 오류가 발생했을 때 알림음 재생" Margin="0,0,0,5"/>
        <Button x:Name="CloudAccountsButton" Content="클라우드 계정 연결 관리" HorizontalAlignment="Left" Margin="0,14,0,0"/>
      </StackPanel>
    </GroupBox>
    <GroupBox Header="화면 모드" Padding="16" Margin="0,0,0,14">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="105"/><ColumnDefinition Width="210"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <TextBlock Text="모양" VerticalAlignment="Center" Foreground="{DynamicResource SafeSyncMutedBrush}"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal"><RadioButton x:Name="ThemeLightRadio" Content="라이트 모드" GroupName="SafeSyncThemeMode"/><RadioButton x:Name="ThemeDarkRadio" Content="다크 모드" GroupName="SafeSyncThemeMode" Margin="0"/></StackPanel>
        <TextBlock Grid.Column="2" Text="저장하면 모든 SafeSync 창에 적용됩니다." TextWrapping="Wrap" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="{DynamicResource SafeSyncMutedBrush}"/>
      </Grid>
    </GroupBox>
    </StackPanel>
    </ScrollViewer>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="CloseButton" Content="닫기"/>
      <Button x:Name="SaveButton" Content="설정 저장" Background="{DynamicResource SafeSyncAccentBrush}" Foreground="White" BorderBrush="{DynamicResource SafeSyncAccentBrush}"/>
    </StackPanel>
  </Grid>
</Window>
'@
    $dialog = Load-Xaml $settingsXaml
    Apply-SafeSyncThemeToWindow $dialog
    $dialog.Owner = $script:Window
    $autoStartCheck = $dialog.FindName('AutoStartCheck')
    $retentionBox = $dialog.FindName('RetentionBox')
    $minimizeSoundCheck = $dialog.FindName('SoundOnMinimizeCheck')
    $backupCompleteSoundCheck = $dialog.FindName('SoundOnBackupCompleteCheck')
    $backupErrorSoundCheck = $dialog.FindName('SoundOnBackupErrorCheck')
    $themeLightRadio = $dialog.FindName('ThemeLightRadio')
    $themeDarkRadio = $dialog.FindName('ThemeDarkRadio')
    $autoStartCheck.IsChecked = [bool]$script:Config.AutoStart
    $retentionBox.Text = [string]$script:Config.TrashRetentionDays
    $minimizeSoundCheck.IsChecked = [bool]$script:Config.SoundOnMinimize
    $backupCompleteSoundCheck.IsChecked = [bool]$script:Config.SoundOnBackupComplete
    $backupErrorSoundCheck.IsChecked = [bool]$script:Config.SoundOnBackupError
    $themeLightRadio.IsChecked = (Get-SafeSyncThemeMode) -eq 'Light'
    $themeDarkRadio.IsChecked = (Get-SafeSyncThemeMode) -eq 'Dark'
    $dialog.FindName('CloudAccountsButton').Add_Click({ Show-CloudAccountSettings })
    $dialog.FindName('CloseButton').Add_Click({ $dialog.Close() })
    $dialog.FindName('SaveButton').Add_Click({
        $days = 0
        if (-not [int]::TryParse($retentionBox.Text, [ref]$days) -or $days -lt 1 -or $days -gt 3650) {
            [System.Windows.MessageBox]::Show($dialog, '보관 기간은 1~3650일 사이의 숫자로 입력하세요.', '설정 확인', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }
        try {
            $script:Config.TrashRetentionDays = $days
            $script:Config.AutoStart = [bool]$autoStartCheck.IsChecked
            $script:Config.SoundOnMinimize = [bool]$minimizeSoundCheck.IsChecked
            $script:Config.SoundOnBackupComplete = [bool]$backupCompleteSoundCheck.IsChecked
            $script:Config.SoundOnBackupError = [bool]$backupErrorSoundCheck.IsChecked
            $script:Config.ThemeMode = if ([bool]$themeDarkRadio.IsChecked) { 'Dark' } else { 'Light' }
            Save-Config $script:Config
            Set-AutoStart ([bool]$script:Config.AutoStart)
            Apply-SafeSyncTheme
            Apply-SafeSyncThemeToWindow $dialog
            Add-Activity '환경설정을 저장했습니다.'
            Refresh-JobsGrid
            $dialog.DialogResult = $true
        }
        catch { [System.Windows.MessageBox]::Show($dialog, $_.Exception.Message, '환경설정 저장 오류', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null }
    })
    [void]$dialog.ShowDialog()
}

function Get-SelectedJob {
    $selected = $script:JobsGrid.SelectedItem
    if ($null -eq $selected) { return $null }
    return @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$selected.Id } | Select-Object -First 1
}

function Update-JobActionButtons {
    $job = Get-SelectedJob
    $hasSelection = $null -ne $job
    $paused = $hasSelection -and (Test-SafeSyncJobPaused $job)
    $script:EditButton.IsEnabled = $hasSelection
    $script:DeleteButton.IsEnabled = $hasSelection
    $script:PauseButton.IsEnabled = $hasSelection
    $script:PauseButton.Content = if ($paused) { '다시 시작' } else { '일시정지' }
    $script:PauseButton.ToolTip = if ($paused) { '선택한 작업의 자동·예약 백업을 다시 시작합니다.' } else { '선택한 작업의 자동·예약 백업을 멈춥니다.' }
    $script:RunButton.IsEnabled = $hasSelection -and -not $paused
    $script:FullScanButton.IsEnabled = $hasSelection -and -not $paused
    $script:TrashButton.IsEnabled = $hasSelection
}

function Get-SafeSyncTrashDeletedAt([string]$BundleName, [datetime]$Fallback) {
    if ($BundleName -match '^(\d{8}-\d{9})') {
        try { return [datetime]::ParseExact($matches[1], 'yyyyMMdd-HHmmssfff', [Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    if ($BundleName -match '^(\d{8}-\d{6})') {
        try { return [datetime]::ParseExact($matches[1], 'yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture) } catch {}
    }
    return $Fallback
}

function Get-SafeSyncLocalTrashItems([object]$Job) {
    $destinationRoot = Get-NormalizedPath ([string]$Job.Destination)
    $trashRoot = Join-Path $destinationRoot '.safesync-trash'
    if (-not (Test-Path -LiteralPath $trashRoot -PathType Container)) { return @() }
    $trashRootFull = [System.IO.Path]::GetFullPath($trashRoot).TrimEnd('\','/')
    $prefix = $trashRootFull + [System.IO.Path]::DirectorySeparatorChar
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $trashRootFull -File -Recurse -Force -ErrorAction Stop)) {
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $insideTrash = $fullPath.Substring($prefix.Length)
        $parts = $insideTrash -split '[\\/]', 2
        $bundleName = if ($parts.Count -gt 1) { [string]$parts[0] } else { '' }
        $relativePath = if ($parts.Count -gt 1) { [string]$parts[1] } else { [string]$file.Name }
        $relativePath = ConvertTo-SafeSyncRelativePath $relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        $deletedAt = Get-SafeSyncTrashDeletedAt $bundleName $file.CreationTime
        $items.Add([pscustomobject]@{
            Provider = 'Local'
            Name = [System.IO.Path]::GetFileName($relativePath)
            DeletedAt = $deletedAt
            DeletedAtText = $deletedAt.ToString('yyyy-MM-dd HH:mm:ss')
            OriginalPath = Join-Path $destinationRoot $relativePath.Replace('/','\')
            RelativePath = $relativePath
            Size = [long]$file.Length
            SizeText = Format-ProgressFileSize ([long]$file.Length)
            TrashPath = $fullPath
            TrashRoot = $trashRootFull
            RemoteId = ''
            RemoteParentId = ''
        })
    }
    return @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Get-SafeSyncDropboxTrashItems([object]$Job) {
    $token = Get-SafeSyncCloudAccessToken 'Dropbox' $script:Config
    $trashRoot = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) '.safesync-trash'
    $prefix = $trashRoot.TrimEnd('/') + '/'
    $items = New-Object System.Collections.Generic.List[object]
    try { $entries = @(Get-SafeSyncDropboxEntries $token $trashRoot $true) }
    catch {
        $details = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
        if (($_.Exception.Message + ' ' + $details) -match 'not_found|path/not_found') { return @() }
        throw
    }
    foreach ($entry in $entries) {
        $tag = if ($null -ne $entry.PSObject.Properties['.tag']) { [string]$entry.PSObject.Properties['.tag'].Value } else { '' }
        if ($tag -eq 'folder') { continue }
        $remotePath = [string]$entry.path_display
        if (-not $remotePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $insideTrash = $remotePath.Substring($prefix.Length)
        $parts = $insideTrash -split '/', 2
        if ($parts.Count -lt 2) { continue }
        $relativePath = ConvertTo-SafeSyncRelativePath ([string]$parts[1])
        $fallback = Get-Date
        if ($null -ne $entry.PSObject.Properties['server_modified']) { [void][datetime]::TryParse([string]$entry.server_modified, [ref]$fallback) }
        $deletedAt = Get-SafeSyncTrashDeletedAt ([string]$parts[0]) $fallback.ToLocalTime()
        [long]$size = if ($null -ne $entry.PSObject.Properties['size']) { [long]$entry.size } else { 0 }
        $items.Add([pscustomobject]@{
            Provider='Dropbox';Name=[System.IO.Path]::GetFileName($relativePath);DeletedAt=$deletedAt;DeletedAtText=$deletedAt.ToString('yyyy-MM-dd HH:mm:ss')
            OriginalPath=([string]$Job.Destination).TrimEnd('/','\') + ' / ' + $relativePath;RelativePath=$relativePath;Size=$size;SizeText=(Format-ProgressFileSize $size)
            TrashPath=$remotePath;TrashRoot=$trashRoot;RemoteId=if($null -ne $entry.PSObject.Properties['id']){[string]$entry.id}else{$remotePath};RemoteParentId=''
        })
    }
    return @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Get-SafeSyncGoogleTrashItems([object]$Job) {
    $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $script:Config
    $trashFolder = @(Get-SafeSyncGoogleChildren $token ([string]$Job.CloudFolderId) | Where-Object { [string]$_.name -eq '.safesync-trash' -and [string]$_.mimeType -eq 'application/vnd.google-apps.folder' } | Select-Object -First 1)
    if ($trashFolder.Count -eq 0) { return @() }
    $tree = Get-SafeSyncGoogleTree $token ([string]$trashFolder[0].id)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($remote in @($tree.Files.Values)) {
        $insideTrash = [string]$remote.Relative
        $parts = $insideTrash -split '/', 2
        if ($parts.Count -lt 2) { continue }
        $relativePath = ConvertTo-SafeSyncRelativePath ([string]$parts[1])
        $fallback = Get-Date
        if ($null -ne $remote.Item.PSObject.Properties['modifiedTime']) { [void][datetime]::TryParse([string]$remote.Item.modifiedTime, [ref]$fallback) }
        $deletedAt = Get-SafeSyncTrashDeletedAt ([string]$parts[0]) $fallback.ToLocalTime()
        [long]$size = if ($null -ne $remote.Item.PSObject.Properties['size']) { [long]$remote.Item.size } else { 0 }
        $items.Add([pscustomobject]@{
            Provider='GoogleDrive';Name=[System.IO.Path]::GetFileName($relativePath);DeletedAt=$deletedAt;DeletedAtText=$deletedAt.ToString('yyyy-MM-dd HH:mm:ss')
            OriginalPath=([string]$Job.Destination).TrimEnd('/','\') + ' / ' + $relativePath;RelativePath=$relativePath;Size=$size;SizeText=(Format-ProgressFileSize $size)
            TrashPath=$insideTrash;TrashRoot=[string]$trashFolder[0].id;RemoteId=[string]$remote.Item.id;RemoteParentId=[string]$remote.ParentId
        })
    }
    return @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Get-SafeSyncTrashItems([object]$Job) {
    $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
    switch ($destinationType) {
        'Dropbox' { return @(Get-SafeSyncDropboxTrashItems $Job) }
        'GoogleDrive' { return @(Get-SafeSyncGoogleTrashItems $Job) }
        default { return @(Get-SafeSyncLocalTrashItems $Job) }
    }
}

function Remove-SafeSyncEmptyTrashParents([string]$ItemPath, [string]$TrashRoot) {
    $root = [System.IO.Path]::GetFullPath($TrashRoot).TrimEnd('\','/')
    $parent = Split-Path -Parent $ItemPath
    while (-not [string]::IsNullOrWhiteSpace($parent)) {
        $fullParent = [System.IO.Path]::GetFullPath($parent).TrimEnd('\','/')
        if ($fullParent.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { break }
        if (-not $fullParent.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { break }
        if (@(Get-ChildItem -LiteralPath $fullParent -Force -ErrorAction SilentlyContinue).Count -gt 0) { break }
        Remove-Item -LiteralPath $fullParent -Force -ErrorAction Stop
        $parent = Split-Path -Parent $fullParent
    }
}

function Update-SafeSyncStateAfterTrashRestore([object]$Job, [object]$State, [string]$RelativePath, [string]$RemoteId = '', [string]$RemoteParentId = '') {
    $relative = ConvertTo-SafeSyncRelativePath $RelativePath
    $sourceFile = $null
    try {
        $sourcePath = Join-Path (Get-NormalizedPath ([string]$Job.Source)) $relative.Replace('/','\')
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) { $sourceFile = Get-Item -LiteralPath $sourcePath -Force }
    }
    catch {}
    Set-SafeSyncStateEntry -State $State -RelativePath $relative -File $sourceFile -Status Conflict -ErrorMessage '휴지통에서 수동 복구됨. 다시 시작하기 전에 원본과 백업 파일을 확인하세요.' -RemoteId $RemoteId -RemoteParentId $RemoteParentId
    $pending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($State.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $pending[[string]$path] = [string]$path } }
    $pending[$relative] = $relative
    $State.PendingPaths = @($pending.Values)
    Add-SafeSyncChangedPath ([string]$Job.Id) 'D' $relative
}

function Restore-SafeSyncLocalTrashItems([object]$Job, [object[]]$Items) {
    $duplicates = @($Items | Group-Object { ([string]$_.RelativePath).ToLowerInvariant() } | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) { throw '같은 원래 경로의 여러 버전을 동시에 복구할 수 없습니다. 경로마다 한 파일만 선택하세요.' }
    $destinationRoot = Get-NormalizedPath ([string]$Job.Destination)
    $state = Get-SafeSyncState ([string]$Job.Id)
    $result = [ordered]@{ Restored=0; Errors=@() }
    foreach ($item in @($Items)) {
        try {
            $trashPath = [System.IO.Path]::GetFullPath([string]$item.TrashPath)
            $trashRoot = [System.IO.Path]::GetFullPath([string]$item.TrashRoot)
            Assert-SafeSyncPathWithin $trashRoot $trashPath
            if (-not (Test-Path -LiteralPath $trashPath -PathType Leaf)) { throw '휴지통 파일을 찾을 수 없습니다.' }
            $trashFile = Get-Item -LiteralPath $trashPath -Force
            if (($trashFile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw '연결 파일은 안전을 위해 복구할 수 없습니다.' }
            $relative = ConvertTo-SafeSyncRelativePath ([string]$item.RelativePath)
            $destinationPath = Join-Path $destinationRoot $relative.Replace('/','\')
            Assert-SafeSyncPathWithin $destinationRoot $destinationPath
            Copy-FileSafely -SourceFile $trashFile -DestinationPath $destinationPath -DestinationRoot $destinationRoot -RelativePath $relative
            Remove-Item -LiteralPath $trashPath -Force -ErrorAction Stop
            Remove-SafeSyncEmptyTrashParents $trashPath $trashRoot
            Update-SafeSyncStateAfterTrashRestore $Job $state $relative
            $result.Restored++
        }
        catch { $result.Errors += "$([string]$item.Name) : $($_.Exception.Message)" }
    }
    try { Save-SafeSyncState $state } catch { $result.Errors += "스냅샷 기록 : $($_.Exception.Message)" }
    return [pscustomobject]$result
}

function Restore-SafeSyncDropboxTrashItems([object]$Job, [object[]]$Items) {
    $token = Get-SafeSyncCloudAccessToken 'Dropbox' $script:Config
    $state = Get-SafeSyncState ([string]$Job.Id)
    $result = [ordered]@{ Restored=0; Errors=@() }
    $preserveBundle = ".safesync-trash/$(Get-Date -Format 'yyyyMMdd-HHmmssfff')-restore-replaced-$([guid]::NewGuid().ToString('N'))"
    foreach ($item in @($Items)) {
        $preservedPath = ''
        try {
            $relative = ConvertTo-SafeSyncRelativePath ([string]$item.RelativePath)
            $targetPath = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) $relative
            $current = Get-SafeSyncDropboxMetadata $token $targetPath
            if ($null -ne $current) {
                $preservedPath = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) "$preserveBundle/$relative"
                Move-SafeSyncDropboxItem $token ([string]$current.path_display) $preservedPath $false
            }
            try { Move-SafeSyncDropboxItem $token ([string]$item.TrashPath) $targetPath $false }
            catch {
                if (-not [string]::IsNullOrWhiteSpace($preservedPath)) {
                    try { Move-SafeSyncDropboxItem $token $preservedPath $targetPath $false } catch {}
                }
                throw
            }
            $restored = Get-SafeSyncDropboxMetadata $token $targetPath
            $restoredId = if ($null -ne $restored) { [string]$restored.id } else { $targetPath }
            Update-SafeSyncStateAfterTrashRestore $Job $state $relative $restoredId ''
            $result.Restored++
        }
        catch { $result.Errors += "$([string]$item.Name) : $($_.Exception.Message)" }
    }
    try { Save-SafeSyncState $state } catch { $result.Errors += "스냅샷 기록 : $($_.Exception.Message)" }
    return [pscustomobject]$result
}

function Restore-SafeSyncGoogleTrashItems([object]$Job, [object[]]$Items) {
    $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $script:Config
    $rootId = [string]$Job.CloudFolderId
    $tree = Get-SafeSyncGoogleTree $token $rootId
    $state = Get-SafeSyncState ([string]$Job.Id)
    $result = [ordered]@{ Restored=0; Errors=@() }
    $preserveBundle = ".safesync-trash/$(Get-Date -Format 'yyyyMMdd-HHmmssfff')-restore-replaced-$([guid]::NewGuid().ToString('N'))"
    foreach ($item in @($Items)) {
        $current = $null
        $preserveParent = ''
        $targetParent = ''
        try {
            $relative = ConvertTo-SafeSyncRelativePath ([string]$item.RelativePath)
            $parentRel = [string][System.IO.Path]::GetDirectoryName($relative)
            $parentRel = $parentRel.Replace('\','/')
            $targetParent = Ensure-SafeSyncGoogleFolderPath $token $rootId $parentRel $tree.Folders
            $key = $relative.ToLowerInvariant()
            if ($tree.Files.ContainsKey($key)) {
                $current = $tree.Files[$key]
                $preserveParentRel = if ([string]::IsNullOrWhiteSpace($parentRel)) { $preserveBundle } else { "$preserveBundle/$parentRel" }
                $preserveParent = Ensure-SafeSyncGoogleFolderPath $token $rootId $preserveParentRel $tree.Folders
                Move-SafeSyncGoogleItem $token ([string]$current.Item.id) ([string]$current.ParentId) $preserveParent
            }
            try { Move-SafeSyncGoogleItem $token ([string]$item.RemoteId) ([string]$item.RemoteParentId) $targetParent }
            catch {
                if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($preserveParent)) {
                    try { Move-SafeSyncGoogleItem $token ([string]$current.Item.id) $preserveParent $targetParent } catch {}
                }
                throw
            }
            Update-SafeSyncStateAfterTrashRestore $Job $state $relative ([string]$item.RemoteId) $targetParent
            $tree.Files[$key] = [pscustomobject]@{ Relative=$relative; Item=[pscustomobject]@{id=[string]$item.RemoteId}; ParentId=$targetParent }
            $result.Restored++
        }
        catch { $result.Errors += "$([string]$item.Name) : $($_.Exception.Message)" }
    }
    try { Save-SafeSyncState $state } catch { $result.Errors += "스냅샷 기록 : $($_.Exception.Message)" }
    return [pscustomobject]$result
}

function Restore-SafeSyncTrashItems([object]$Job, [object[]]$Items) {
    $duplicates = @($Items | Group-Object { ([string]$_.RelativePath).ToLowerInvariant() } | Where-Object Count -gt 1)
    if ($duplicates.Count -gt 0) { throw '같은 원래 경로의 여러 버전을 동시에 복구할 수 없습니다. 경로마다 한 파일만 선택하세요.' }
    $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
    switch ($destinationType) {
        'Dropbox' { return Restore-SafeSyncDropboxTrashItems $Job $Items }
        'GoogleDrive' { return Restore-SafeSyncGoogleTrashItems $Job $Items }
        default { return Restore-SafeSyncLocalTrashItems $Job $Items }
    }
}

function Get-SafeSyncTrashCachePath([object]$Job) {
    $jobId = [string]$Job.Id
    if ($jobId -notmatch '^[a-zA-Z0-9_-]{1,80}$') { throw '휴지통 작업 식별자가 안전하지 않습니다.' }
    return Join-Path (Join-Path $script:DataRoot 'trash-cache') "$jobId.json"
}

function Initialize-SafeSyncTrashBrowser {
    $ctx = $script:TrashBrowserContext
    if ($null -eq $ctx -or -not $ctx.Dialog.IsVisible) { return }
    $cacheIsFresh = $false
    try {
        $cachePath = Get-SafeSyncTrashCachePath $ctx.Job
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            $cacheFile = Get-Item -LiteralPath $cachePath
            $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cloudId = if ($null -ne $ctx.Job.PSObject.Properties['CloudFolderId']) { [string]$ctx.Job.CloudFolderId } else { '' }
            if ([string]$cache.JobId -eq [string]$ctx.Job.Id -and [string]$cache.DestinationType -eq $ctx.DestinationType -and
                [string]$cache.Destination -eq [string]$ctx.Job.Destination -and [string]$cache.CloudFolderId -eq $cloudId) {
                $items = @($cache.Items)
                $ctx.Grid.ItemsSource = $items
                $ctx.StatusText.Text = "저장된 휴지통 파일 $($items.Count)개를 표시했습니다."
                $maximumAge = if ($ctx.DestinationType -eq 'Local') { [TimeSpan]::FromMinutes(2) } else { [TimeSpan]::FromMinutes(15) }
                $cacheIsFresh = ([datetime]::UtcNow - $cacheFile.LastWriteTimeUtc) -lt $maximumAge
                $backupResult = Join-Path $script:ResultRoot "$([string]$ctx.Job.Id).json"
                if ((Test-Path -LiteralPath $backupResult -PathType Leaf) -and (Get-Item -LiteralPath $backupResult).LastWriteTimeUtc -gt $cacheFile.LastWriteTimeUtc) {
                    $cacheIsFresh = $false
                }
            }
        }
    }
    catch { $cacheIsFresh = $false }
    if ($cacheIsFresh) {
        $ctx.SelectAllButton.IsEnabled = @($ctx.Grid.ItemsSource).Count -gt 0
        & $script:TrashBrowserSetSelectionButtons
    }
    else {
        & $script:TrashBrowserStartWorker 'List' @()
    }
}

function Show-SelectedSafeSyncTrashBrowser {
    if ($null -ne $script:TrashBrowserContext -and $script:TrashBrowserContext.Dialog.IsVisible) {
        $script:TrashBrowserContext.Dialog.WindowState = [System.Windows.WindowState]::Normal
        [void]$script:TrashBrowserContext.Dialog.Activate()
        return
    }
    $job = Get-SelectedJob
    if ($null -eq $job) {
        [System.Windows.MessageBox]::Show($script:Window, '휴지통을 확인할 작업을 선택하세요.', 'SafeSync') | Out-Null
        return
    }
    $destinationType = if ($null -ne $job.PSObject.Properties['DestinationType']) { [string]$job.DestinationType } else { 'Local' }
    try {
        if ($destinationType -eq 'Local') {
            if (-not (Test-Path -LiteralPath $job.Destination -PathType Container)) { throw '선택한 백업 위치에 접근할 수 없습니다.' }
            $trashPath = Join-Path ([string]$job.Destination) '.safesync-trash'
            if (-not (Test-Path -LiteralPath $trashPath -PathType Container)) { [void](New-Item -ItemType Directory -Path $trashPath -Force) }
        }
        $trashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="SafeSync 휴지통" Width="1040" Height="650" MinWidth="820" MinHeight="460"
        WindowStartupLocation="CenterScreen" Background="{DynamicResource SafeSyncWindowBrush}" FontFamily="Segoe UI, Malgun Gothic">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Padding" Value="16,8"/><Setter Property="Margin" Value="8,0,0,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/></Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="DataGrid"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/></Style>
    <Style TargetType="DataGridRow"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="DataGridCell"><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/><Setter Property="BorderThickness" Value="0,0,1,1"/></Style>
    <Style TargetType="ScrollViewer"><Setter Property="Background" Value="{DynamicResource SafeSyncSurfaceBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/></Style>
    <Style TargetType="ScrollBar"><Setter Property="Background" Value="{DynamicResource SafeSyncSubtleBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncMutedBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderBrush}"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type ScrollBar}"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"><Track x:Name="PART_Track" IsDirectionReversed="True"><Track.Thumb><Thumb Background="{DynamicResource SafeSyncMutedBrush}"><Thumb.Template><ControlTemplate TargetType="{x:Type Thumb}"><Border Background="{TemplateBinding Background}" Margin="2" CornerRadius="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track></Border></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="DataGridColumnHeadersPresenter"><Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/></Style>
    <Style TargetType="DataGridColumnHeader"><Setter Property="Background" Value="{DynamicResource SafeSyncHeadingBrush}"/><Setter Property="Foreground" Value="{DynamicResource SafeSyncTextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource SafeSyncBorderSoftBrush}"/><Setter Property="BorderThickness" Value="0,0,1,1"/><Setter Property="Padding" Value="10"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="{x:Type DataGridColumnHeader}"><Grid SnapsToDevicePixels="True"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"><ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}" Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}" ContentStringFormat="{TemplateBinding ContentStringFormat}" RecognizesAccessKey="True"/></Border><Thumb x:Name="PART_LeftHeaderGripper" HorizontalAlignment="Left" Width="4" Background="{TemplateBinding Background}" Cursor="SizeWE"/><Thumb x:Name="PART_RightHeaderGripper" HorizontalAlignment="Right" Width="4" Background="{TemplateBinding Background}" Cursor="SizeWE"/><Border HorizontalAlignment="Right" Width="1" Background="{DynamicResource SafeSyncBorderSoftBrush}"/></Grid></ControlTemplate></Setter.Value></Setter></Style>
  </Window.Resources>
  <Grid Margin="22">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,14">
      <TextBlock Text="SafeSync 휴지통" FontSize="24" FontWeight="Bold" Foreground="{DynamicResource SafeSyncTextBrush}"/>
      <TextBlock x:Name="JobText" Margin="0,5,0,0" Foreground="{DynamicResource SafeSyncMutedBrush}" TextWrapping="Wrap"/>
      <TextBlock Text="파일은 폴더 구분 없이 표시됩니다. 복구하면 지워지기 전 백업 위치로 돌아가며, 그 위치에 있던 파일은 다시 SafeSync 휴지통에 보관됩니다. 복구한 파일을 확인할 때까지 작업은 일시정지 상태로 유지됩니다." Margin="0,5,0,0" Foreground="{DynamicResource SafeSyncMutedBrush}" TextWrapping="Wrap"/>
    </StackPanel>
    <Grid Grid.Row="1" Margin="0,0,0,10">
      <TextBlock x:Name="StatusText" Foreground="{DynamicResource SafeSyncMutedBrush}" VerticalAlignment="Center"/>
      <ProgressBar x:Name="BusyProgress" Width="190" Height="7" HorizontalAlignment="Right" VerticalAlignment="Center" IsIndeterminate="True" Visibility="Collapsed"/>
    </Grid>
    <Border Grid.Row="2" Background="{DynamicResource SafeSyncSurfaceBrush}" BorderBrush="{DynamicResource SafeSyncBorderSoftBrush}" BorderThickness="1" CornerRadius="7">
      <DataGrid x:Name="TrashGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" SelectionMode="Extended" SelectionUnit="FullRow" GridLinesVisibility="Horizontal" BorderThickness="0" RowHeight="40" EnableRowVirtualization="True" EnableColumnVirtualization="True" VirtualizingPanel.VirtualizationMode="Recycling" Background="{DynamicResource SafeSyncSurfaceBrush}" Foreground="{DynamicResource SafeSyncTextBrush}" RowBackground="{DynamicResource SafeSyncSurfaceBrush}" AlternatingRowBackground="{DynamicResource SafeSyncSubtleBrush}" HorizontalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}" VerticalGridLinesBrush="{DynamicResource SafeSyncBorderSoftBrush}">
        <DataGrid.Columns>
          <DataGridTextColumn Header="파일 이름" Binding="{Binding Name}" Width="1.2*"/>
          <DataGridTextColumn Header="삭제된 날짜와 시간" Binding="{Binding DeletedAtText}" Width="170"/>
          <DataGridTextColumn Header="지워지기 전 원본 경로" Binding="{Binding OriginalPath}" Width="3*"/>
          <DataGridTextColumn Header="크기" Binding="{Binding SizeText}" Width="95"/>
        </DataGrid.Columns>
      </DataGrid>
    </Border>
    <Grid Grid.Row="3" Margin="0,16,0,0">
      <StackPanel Orientation="Horizontal"><Button x:Name="RefreshButton" Content="새로고침"/><Button x:Name="SelectAllButton" Content="모두 선택"/></StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="CloseButton" Content="닫기"/><Button x:Name="DeleteButton" Content="선택 파일 완전 삭제" Background="{DynamicResource SafeSyncDangerBrush}" Foreground="White" BorderBrush="{DynamicResource SafeSyncDangerBrush}"/><Button x:Name="RestoreButton" Content="선택 파일 복구" Background="{DynamicResource SafeSyncAccentBrush}" Foreground="White" BorderBrush="{DynamicResource SafeSyncAccentBrush}"/></StackPanel>
    </Grid>
  </Grid>
</Window>
'@
        $dialog = Load-Xaml $trashXaml
        Apply-SafeSyncThemeToWindow $dialog
        $grid = $dialog.FindName('TrashGrid')
        $statusText = $dialog.FindName('StatusText')
        $restoreButton = $dialog.FindName('RestoreButton')
        $deleteButton = $dialog.FindName('DeleteButton')
        $refreshButton = $dialog.FindName('RefreshButton')
        $selectAllButton = $dialog.FindName('SelectAllButton')
        $busyProgress = $dialog.FindName('BusyProgress')
        $dialog.FindName('JobText').Text = "작업: $($job.Name)  ·  백업 위치: $($job.Destination)"
        $workerPath = Join-Path (Split-Path -Parent $script:ScriptPath) 'SafeSync.TrashWorker.ps1'
        $trashWorkerState = [pscustomobject]@{
            Busy=$false; Mode=''; Process=$null; ResultPath=''; RequestPath=''; ProgressPath=''; PartialRoot=''; PartialSeen=0; PartialStarted=$false; StartedAt=[datetime]::MinValue
        }
        $trashWorkerTimer = New-Object System.Windows.Threading.DispatcherTimer
        $trashWorkerTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:TrashBrowserContext = [pscustomobject]@{
            Job=$job; DestinationType=$destinationType; Dialog=$dialog; Grid=$grid; StatusText=$statusText
            RestoreButton=$restoreButton; DeleteButton=$deleteButton; RefreshButton=$refreshButton
            SelectAllButton=$selectAllButton; BusyProgress=$busyProgress; WorkerPath=$workerPath
            State=$trashWorkerState; Timer=$trashWorkerTimer
        }
        $script:TrashBrowserSetSelectionButtons = {
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            $selectedCount = @($ctx.Grid.SelectedItems).Count
            $ctx.RestoreButton.IsEnabled = -not $ctx.State.Busy -and $selectedCount -gt 0
            $ctx.DeleteButton.IsEnabled = -not $ctx.State.Busy -and $selectedCount -gt 0
        }
        $script:TrashBrowserSetBusy = {
            param([bool]$Busy, [string]$Message = '')
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            $ctx.State.Busy = $Busy
            $ctx.RefreshButton.IsEnabled = -not $Busy
            $ctx.SelectAllButton.IsEnabled = -not $Busy -and $null -ne $ctx.Grid.ItemsSource -and @($ctx.Grid.ItemsSource).Count -gt 0
            $ctx.BusyProgress.Visibility = if ($Busy) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
            if (-not [string]::IsNullOrWhiteSpace($Message)) { $ctx.StatusText.Text = $Message }
            & $script:TrashBrowserSetSelectionButtons
        }
        $script:TrashBrowserCleanupWorkerFiles = {
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            foreach ($path in @($ctx.State.ResultPath, $ctx.State.RequestPath, $ctx.State.ProgressPath)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                }
            }
            $partialRoot = [string]$ctx.State.PartialRoot
            if (-not [string]::IsNullOrWhiteSpace($partialRoot) -and (Test-Path -LiteralPath $partialRoot -PathType Container)) {
                $resultRootFull = [System.IO.Path]::GetFullPath($script:ResultRoot).TrimEnd('\','/') + [System.IO.Path]::DirectorySeparatorChar
                $partialFull = [System.IO.Path]::GetFullPath($partialRoot)
                if ($partialFull.StartsWith($resultRootFull, [StringComparison]::OrdinalIgnoreCase) -and
                    [System.IO.Path]::GetFileName($partialFull) -match '^trash-[a-f0-9]{32}-parts$') {
                    Remove-Item -LiteralPath $partialFull -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $script:TrashBrowserStartWorker = {
            param([ValidateSet('List','Delete')][string]$Mode, [object[]]$Items = @())
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx -or $ctx.State.Busy) { return }
            if (-not (Test-Path -LiteralPath $ctx.WorkerPath -PathType Leaf)) { throw 'SafeSync.TrashWorker.ps1 구성 파일을 찾을 수 없습니다. 설치 프로그램으로 다시 설치해 주세요.' }
            if (-not (Test-Path -LiteralPath $script:ResultRoot)) { [void](New-Item -ItemType Directory -Path $script:ResultRoot -Force) }
            $operationId = [guid]::NewGuid().ToString('N')
            $ctx.State.Mode = $Mode
            $ctx.State.ResultPath = Join-Path $script:ResultRoot "trash-$operationId-result.json"
            $ctx.State.RequestPath = if ($Mode -eq 'Delete') { Join-Path $script:ResultRoot "trash-$operationId-request.json" } else { '' }
            $ctx.State.ProgressPath = Join-Path $script:ResultRoot "trash-$operationId-progress.json"
            $ctx.State.PartialRoot = Join-Path $script:ResultRoot "trash-$operationId-parts"
            $ctx.State.PartialSeen = 0
            $ctx.State.PartialStarted = $false
            $ctx.State.StartedAt = [datetime]::UtcNow
            if ($Mode -eq 'Delete') {
                [pscustomobject]@{ Items=@($Items) } | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath $ctx.State.RequestPath -Encoding UTF8
            }
            $powershellPath = (Get-Command powershell.exe).Source
            $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($ctx.WorkerPath)`" -Mode `"$Mode`" -JobId `"$([string]$ctx.Job.Id)`" -DataRoot `"$script:DataRoot`" -ResultPath `"$($ctx.State.ResultPath)`" -ProgressPath `"$($ctx.State.ProgressPath)`""
            if ($Mode -eq 'Delete') { $arguments += " -RequestPath `"$($ctx.State.RequestPath)`"" }
            else { $arguments += " -PartialRoot `"$($ctx.State.PartialRoot)`"" }
            try {
                $ctx.State.Process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
                $busyMessage = if ($Mode -eq 'List') { '휴지통 목록을 불러오는 중입니다. 이 창은 계속 사용할 수 있습니다.' } else { "선택한 파일 $($Items.Count)개를 완전히 삭제하고 있습니다." }
                & $script:TrashBrowserSetBusy $true $busyMessage
                $ctx.Timer.Start()
            }
            catch {
                & $script:TrashBrowserCleanupWorkerFiles
                $ctx.State.Process = $null
                & $script:TrashBrowserSetBusy $false "휴지통 작업을 시작하지 못했습니다: $($_.Exception.Message)"
            }
        }
        $trashWorkerTimer.Add_Tick({
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            if (-not $ctx.State.Busy) { $ctx.Timer.Stop(); return }
            if ($ctx.State.Mode -eq 'List' -and (Test-Path -LiteralPath $ctx.State.PartialRoot -PathType Container)) {
                foreach ($part in @(Get-ChildItem -LiteralPath $ctx.State.PartialRoot -Filter '*.json' -File | Sort-Object Name)) {
                    $sequence = 0
                    if (-not [int]::TryParse($part.BaseName, [ref]$sequence) -or $sequence -le [int]$ctx.State.PartialSeen) { continue }
                    try {
                        $batch = Get-Content -LiteralPath $part.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                        if (-not $ctx.State.PartialStarted) {
                            $ctx.Grid.ItemsSource = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
                            $ctx.State.PartialStarted = $true
                        }
                        foreach ($item in @($batch.Items)) { $ctx.Grid.ItemsSource.Add($item) }
                        $ctx.State.PartialSeen = $sequence
                    }
                    catch { break }
                }
            }
            if (Test-Path -LiteralPath $ctx.State.ProgressPath -PathType Leaf) {
                try {
                    $progress = Get-Content -LiteralPath $ctx.State.ProgressPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($null -ne $progress -and -not [string]::IsNullOrWhiteSpace([string]$progress.Text)) { $ctx.StatusText.Text = [string]$progress.Text }
                }
                catch {}
            }
            elseif ($ctx.State.Mode -eq 'List') {
                $seconds = [Math]::Max(0, [int]([datetime]::UtcNow - $ctx.State.StartedAt).TotalSeconds)
                $ctx.StatusText.Text = "휴지통 목록을 불러오는 중입니다. (${seconds}초 경과)"
            }
            $hasResult = Test-Path -LiteralPath $ctx.State.ResultPath -PathType Leaf
            $hasExited = $null -ne $ctx.State.Process -and $ctx.State.Process.HasExited
            if (-not $hasResult -and -not $hasExited) { return }
            $ctx.Timer.Stop()
            $completedMode = [string]$ctx.State.Mode
            try {
                if (-not $hasResult) { throw '휴지통 작업이 결과를 남기지 않고 종료되었습니다.' }
                $response = Get-Content -LiteralPath $ctx.State.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$response.Status -ne 'Completed') { throw [string]$response.Error }
                if ($completedMode -eq 'List') {
                    $items = @($response.Items)
                    $ctx.Grid.ItemsSource = $items
                    $ctx.Grid.SelectedItem = $null
                    $ctx.StatusText.Text = if ($items.Count -eq 0) { '보관된 파일이 없습니다.' } else { "보관된 파일 $($items.Count)개 · Ctrl 또는 Shift 키로 여러 파일을 선택할 수 있습니다." }
                    & $script:TrashBrowserSetBusy $false
                }
                else {
                    [int]$deleted = $response.Deleted
                    $errors = @($response.Errors)
                    & $script:TrashBrowserSetBusy $false "선택 파일 완전 삭제가 끝났습니다."
                    $activityDeleteText = if ($ctx.DestinationType -eq 'Dropbox') { "'$($ctx.Job.Name)' SafeSync 휴지통 파일 ${deleted}개를 삭제했습니다. Dropbox 보존 기록은 남을 수 있습니다." } else { "'$($ctx.Job.Name)' 휴지통 파일 ${deleted}개를 완전히 삭제했습니다." }
                    Add-Activity $activityDeleteText
                    if ($errors.Count -gt 0) {
                        [System.Windows.MessageBox]::Show($ctx.Dialog, "삭제 ${deleted}개 완료, 실패 $($errors.Count)개`r`n`r`n$($errors -join "`r`n")", '완전 삭제 결과', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                    }
                    else {
                        $completedMessage = if ($ctx.DestinationType -eq 'Dropbox') { "${deleted}개 파일을 SafeSync 휴지통에서 삭제했습니다.`r`n`r`n개인용 Dropbox에서는 Dropbox의 보존 기간 동안 웹사이트에서 복구될 수 있습니다." } else { "${deleted}개 파일을 완전히 삭제했습니다." }
                        [System.Windows.MessageBox]::Show($ctx.Dialog, $completedMessage, '완전 삭제 완료', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
                    }
                }
            }
            catch {
                & $script:TrashBrowserSetBusy $false "휴지통 작업을 완료하지 못했습니다: $($_.Exception.Message)"
            }
            finally {
                if ($null -ne $ctx.State.Process) { $ctx.State.Process.Dispose(); $ctx.State.Process = $null }
                & $script:TrashBrowserCleanupWorkerFiles
            }
            if ($completedMode -eq 'Delete') { & $script:TrashBrowserStartWorker 'List' @() }
        })
        $refreshButton.Add_Click({ & $script:TrashBrowserStartWorker 'List' @() })
        $selectAllButton.Add_Click({ $ctx=$script:TrashBrowserContext; if($null -ne $ctx){$ctx.Grid.SelectAll(); & $script:TrashBrowserSetSelectionButtons} })
        $grid.Add_SelectionChanged({ & $script:TrashBrowserSetSelectionButtons })
        $dialog.FindName('CloseButton').Add_Click({ $ctx=$script:TrashBrowserContext; if($null -ne $ctx){$ctx.Dialog.Close()} })
        $deleteButton.Add_Click({
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            $selected = @($ctx.Grid.SelectedItems)
            if ($selected.Count -eq 0) { [System.Windows.MessageBox]::Show($ctx.Dialog, '완전히 삭제할 파일을 선택하세요.', 'SafeSync 휴지통') | Out-Null; return }
            $message = "선택한 파일 $($selected.Count)개를 완전히 삭제할까요?`r`n`r`n이 작업은 SafeSync에서 되돌릴 수 없습니다."
            if ($ctx.DestinationType -eq 'Dropbox') { $message += "`r`n`r`n개인용 Dropbox API는 서버의 복구 기록까지 영구 삭제할 수 없습니다. SafeSync 휴지통에서는 삭제되지만 Dropbox의 보존 기간 동안 웹사이트에서 복구될 수 있습니다." }
            if ([System.Windows.MessageBox]::Show($ctx.Dialog, $message, '선택 파일 완전 삭제', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning) -ne [System.Windows.MessageBoxResult]::Yes) { return }
            & $script:TrashBrowserStartWorker 'Delete' $selected
        })
        $restoreButton.Add_Click({
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            $job = $ctx.Job
            $dialog = $ctx.Dialog
            $grid = $ctx.Grid
            $selected = @($grid.SelectedItems)
            if ($selected.Count -eq 0) { [System.Windows.MessageBox]::Show($dialog, '복구할 파일을 선택하세요.', 'SafeSync 휴지통') | Out-Null; return }
            $duplicateCount = @($selected | Group-Object { ([string]$_.RelativePath).ToLowerInvariant() } | Where-Object Count -gt 1).Count
            if ($duplicateCount -gt 0) { [System.Windows.MessageBox]::Show($dialog, '같은 원래 경로의 여러 버전이 선택되었습니다. 경로마다 복구할 파일 하나만 선택하세요.', 'SafeSync 휴지통') | Out-Null; return }
            $existingCount = if ($ctx.DestinationType -eq 'Local') { @($selected | Where-Object { Test-Path -LiteralPath ([string]$_.OriginalPath) -PathType Leaf }).Count } else { 0 }
            $message = "선택한 파일 $($selected.Count)개를 지워지기 전 위치로 복구할까요?"
            if ($existingCount -gt 0) { $message += "`r`n`r`n기존 파일 ${existingCount}개는 삭제하지 않고 새 휴지통 항목으로 보관합니다." }
            $message += "`r`n`r`n복구 전에 이 백업 작업을 일시정지하며, 복구가 끝난 뒤에도 일시정지 상태를 유지합니다. 파일을 확인한 다음 메인 창에서 직접 다시 시작하세요."
            if ([System.Windows.MessageBox]::Show($dialog, $message, '파일 복구', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -ne [System.Windows.MessageBoxResult]::Yes) { return }
            try {
                $dialog.Cursor = [System.Windows.Input.Cursors]::Wait
                $ctx.RestoreButton.IsEnabled = $false
                $pauseFailures = @(Set-SafeSyncJobPaused $job $true)
                if ($pauseFailures.Count -gt 0) { throw "작업을 안전하게 일시정지하지 못했습니다.`r`n$($pauseFailures -join "`r`n")" }
                $result = Restore-SafeSyncTrashItems $job $selected
                Add-Activity "'$($job.Name)' 휴지통 파일 $($result.Restored)개를 복구했습니다. 작업은 일시정지 상태입니다."
                if (@($result.Errors).Count -gt 0) { [System.Windows.MessageBox]::Show($dialog, "복구 $($result.Restored)개 완료, 실패 $(@($result.Errors).Count)개`r`n`r`n$(@($result.Errors) -join "`r`n")`r`n`r`n작업은 일시정지 상태입니다. 파일을 확인한 뒤 직접 다시 시작하세요.", '휴지통 복구 결과', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null }
                else { [System.Windows.MessageBox]::Show($dialog, "$($result.Restored)개 파일을 복구했습니다.`r`n`r`n작업은 일시정지 상태입니다. 파일을 확인한 뒤 직접 다시 시작하세요.", '휴지통 복구 완료', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null }
                & $script:TrashBrowserStartWorker 'List' @()
            }
            catch { [System.Windows.MessageBox]::Show($dialog, $_.Exception.Message, '휴지통 복구 오류', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null }
            finally { $dialog.Cursor = $null; & $script:TrashBrowserSetSelectionButtons }
        })
        $dialog.Add_Closing({
            param($sender, $eventArgs)
            $ctx = $script:TrashBrowserContext
            if ($null -eq $ctx) { return }
            if ($ctx.State.Busy -and $ctx.State.Mode -eq 'Delete') {
                $eventArgs.Cancel = $true
                [System.Windows.MessageBox]::Show($ctx.Dialog, '완전 삭제가 끝날 때까지 잠시 기다려 주세요. 창을 최소화할 수 있으며 다른 UI는 계속 사용할 수 있습니다.', 'SafeSync 휴지통') | Out-Null
                return
            }
            $ctx.Timer.Stop()
            if ($null -ne $ctx.State.Process -and -not $ctx.State.Process.HasExited) {
                try { $ctx.State.Process.Kill() } catch {}
            }
            if ($null -ne $ctx.State.Process) { $ctx.State.Process.Dispose(); $ctx.State.Process = $null }
            & $script:TrashBrowserCleanupWorkerFiles
        })
        $dialog.Add_Closed({ $script:TrashBrowserContext = $null })
        & $script:TrashBrowserSetBusy $false '휴지통 목록을 준비하고 있습니다.'
        Add-Activity "'$($job.Name)' SafeSync 휴지통 관리 창을 열었습니다."
        $dialog.Show()
        [void]$dialog.Dispatcher.BeginInvoke([action]{ Initialize-SafeSyncTrashBrowser }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
    catch { [System.Windows.MessageBox]::Show($script:Window, $_.Exception.Message, '휴지통 열기 오류', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null }
}

function Select-Folder([string]$InitialPath = '') {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '폴더 또는 드라이브를 선택하세요. 네트워크 경로도 선택할 수 있습니다.'
    $dialog.ShowNewFolderButton = $true
    if (-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath)) { $dialog.SelectedPath = $InitialPath }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    return $null
}

function Find-CloudFolders {
    $found = New-Object System.Collections.Generic.List[string]
    $dropboxInfo = Join-Path $env:LOCALAPPDATA 'Dropbox\info.json'
    if (Test-Path -LiteralPath $dropboxInfo) {
        try {
            $info = Get-Content -LiteralPath $dropboxInfo -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($name in @('personal','business')) {
                $account = $info.PSObject.Properties[$name]
                if ($null -ne $account -and (Test-Path -LiteralPath $account.Value.path)) { $found.Add([string]$account.Value.path) }
            }
        } catch {}
    }
    foreach ($path in @((Join-Path $env:USERPROFILE 'Dropbox'), (Join-Path $env:USERPROFILE 'My Drive'), 'G:\My Drive', 'G:\내 드라이브')) {
        if ((Test-Path -LiteralPath $path) -and -not $found.Contains($path)) { $found.Add($path) }
    }
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.IsReady -and $drive.VolumeLabel -like '*Google Drive*') {
                foreach ($folderName in @('My Drive','내 드라이브')) {
                    $path = Join-Path $drive.RootDirectory.FullName $folderName
                    if ((Test-Path -LiteralPath $path) -and -not $found.Contains($path)) { $found.Add($path) }
                }
            }
        } catch {}
    }
    return @($found)
}

function Show-CloudAccountSettings {
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="클라우드 계정" Width="720" Height="590" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#F7F9FC" FontFamily="Segoe UI, Malgun Gothic">
 <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="24">
  <TextBlock Text="클라우드 API 계정" FontSize="23" FontWeight="Bold" Foreground="#172033"/>
  <TextBlock Text="인증 정보는 Windows 사용자 계정으로 암호화되어 이 PC에만 저장됩니다." Foreground="#64748B" Margin="0,5,0,18"/>
  <GroupBox Header="Dropbox — Full Dropbox" Padding="14" Margin="0,0,0,14">
   <StackPanel>
    <TextBlock Text="Dropbox App Console에서 Scoped access와 Full Dropbox를 선택하고 아래 Redirect URI를 등록하세요." TextWrapping="Wrap"/>
    <TextBlock Text="Redirect URI: http://127.0.0.1:53682/" FontFamily="Consolas" Margin="0,5,0,10" Foreground="#334155"/>
    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="App Key" VerticalAlignment="Center"/><TextBox x:Name="DropboxKey" Grid.Column="1" Padding="7"/></Grid>
    <StackPanel Orientation="Horizontal" Margin="0,10,0,0"><Button x:Name="DropboxConnect" Content="Dropbox 연결" Padding="13,7"/><Button x:Name="DropboxDisconnect" Content="연결 해제" Padding="13,7"/><TextBlock x:Name="DropboxStatus" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#475569"/></StackPanel>
   </StackPanel>
  </GroupBox>
  <GroupBox Header="Google Drive — 전체 Drive" Padding="14">
   <StackPanel>
    <TextBlock Text="Google Cloud에서 Drive API를 켜고 OAuth 클라이언트 유형을 데스크톱 앱으로 생성하세요. OAuth 동의 화면에는 본인 계정을 테스트 사용자로 등록합니다." TextWrapping="Wrap"/>
    <Grid Margin="0,10,0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Client ID" VerticalAlignment="Center"/><TextBox x:Name="GoogleClientId" Grid.Column="1" Padding="7"/></Grid>
    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="110"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="Client Secret" VerticalAlignment="Center"/><PasswordBox x:Name="GoogleSecret" Grid.Column="1" Padding="7"/></Grid>
    <TextBlock Text="Client Secret을 비워 두면 기존에 암호화 저장된 값을 유지합니다." Foreground="#64748B" Margin="110,4,0,0"/>
    <StackPanel Orientation="Horizontal" Margin="0,10,0,0"><Button x:Name="GoogleConnect" Content="Google Drive 연결" Padding="13,7"/><Button x:Name="GoogleDisconnect" Content="연결 해제" Padding="13,7"/><TextBlock x:Name="GoogleStatus" VerticalAlignment="Center" Margin="8,0,0,0" Foreground="#475569"/></StackPanel>
   </StackPanel>
  </GroupBox>
  <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0"><Button x:Name="SaveCredentials" Content="입력값 저장" Padding="16,8"/><Button x:Name="CloseButton" Content="닫기" Padding="20,8" Background="#246BFD" Foreground="White" BorderBrush="#246BFD"/></StackPanel>
 </StackPanel></ScrollViewer>
</Window>
'@
    $dialog = Load-Xaml $xaml; Apply-SafeSyncThemeToWindow $dialog; $dialog.Owner = $script:Window
    $dropboxKey = $dialog.FindName('DropboxKey'); $dropboxStatus = $dialog.FindName('DropboxStatus')
    $googleId = $dialog.FindName('GoogleClientId'); $googleSecret = $dialog.FindName('GoogleSecret'); $googleStatus = $dialog.FindName('GoogleStatus')
    $dropboxKey.Text = [string]$script:Config.CloudAccounts.Dropbox.AppKey
    $googleId.Text = [string]$script:Config.CloudAccounts.GoogleDrive.ClientId
    $refreshStatus = {
        $dropboxStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$script:Config.CloudAccounts.Dropbox.RefreshTokenProtected)) { '연결되지 않음' } else { "연결됨: $($script:Config.CloudAccounts.Dropbox.AccountName)" }
        $googleStatus.Text = if ([string]::IsNullOrWhiteSpace([string]$script:Config.CloudAccounts.GoogleDrive.RefreshTokenProtected)) { '연결되지 않음' } else { "연결됨: $($script:Config.CloudAccounts.GoogleDrive.AccountName)" }
    }
    $saveInputs = {
        $script:Config.CloudAccounts.Dropbox.AppKey = $dropboxKey.Text.Trim()
        $script:Config.CloudAccounts.GoogleDrive.ClientId = $googleId.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($googleSecret.Password)) { $script:Config.CloudAccounts.GoogleDrive.ClientSecretProtected = Protect-SafeSyncSecret $googleSecret.Password; $googleSecret.Clear() }
        Save-Config $script:Config
    }
    & $refreshStatus
    $dialog.FindName('SaveCredentials').Add_Click({ try { & $saveInputs; [System.Windows.MessageBox]::Show($dialog,'입력값을 안전하게 저장했습니다.','SafeSync')|Out-Null } catch { [System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'저장 오류')|Out-Null } })
    $dialog.FindName('DropboxConnect').Add_Click({
        try { & $saveInputs; $dropboxStatus.Text='브라우저에서 로그인 중…'; $dialog.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::Background); Connect-SafeSyncDropbox $script:Config.CloudAccounts.Dropbox | Out-Null; Save-Config $script:Config; & $refreshStatus; Add-Activity 'Dropbox API 계정을 연결했습니다.' }
        catch { $dropboxStatus.Text='연결 실패'; [System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'Dropbox 연결 오류')|Out-Null }
    })
    $dialog.FindName('GoogleConnect').Add_Click({
        try { & $saveInputs; $googleStatus.Text='브라우저에서 로그인 중…'; $dialog.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::Background); Connect-SafeSyncGoogleDrive $script:Config.CloudAccounts.GoogleDrive | Out-Null; Save-Config $script:Config; & $refreshStatus; Add-Activity 'Google Drive API 계정을 연결했습니다.' }
        catch { $googleStatus.Text='연결 실패'; [System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'Google Drive 연결 오류')|Out-Null }
    })
    $dialog.FindName('DropboxDisconnect').Add_Click({ $script:Config.CloudAccounts.Dropbox.RefreshTokenProtected='';$script:Config.CloudAccounts.Dropbox.AccountName='';$script:Config.CloudAccounts.Dropbox.AccountId='';Save-Config $script:Config;& $refreshStatus;Add-Activity 'Dropbox API 연결을 해제했습니다.' })
    $dialog.FindName('GoogleDisconnect').Add_Click({ $script:Config.CloudAccounts.GoogleDrive.RefreshTokenProtected='';$script:Config.CloudAccounts.GoogleDrive.AccountName='';$script:Config.CloudAccounts.GoogleDrive.AccountId='';Save-Config $script:Config;& $refreshStatus;Add-Activity 'Google Drive API 연결을 해제했습니다.' })
    $dialog.FindName('CloseButton').Add_Click({ $dialog.Close() })
    [void]$dialog.ShowDialog()
}

function Show-CloudFolderPicker([string]$Provider) {
    $account = if ($Provider -eq 'Dropbox') { $script:Config.CloudAccounts.Dropbox } else { $script:Config.CloudAccounts.GoogleDrive }
    if ([string]::IsNullOrWhiteSpace([string]$account.RefreshTokenProtected)) { throw "$Provider 계정을 먼저 연결하세요." }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="클라우드 폴더 선택" Width="570" Height="500" WindowStartupLocation="CenterOwner" Background="#F7F9FC" FontFamily="Segoe UI, Malgun Gothic">
 <Grid Margin="20"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Grid.Row="0" Text="백업 폴더 선택" FontSize="22" FontWeight="Bold"/>
  <TextBlock Grid.Row="1" x:Name="CurrentPath" Margin="0,8,0,10" Foreground="#475569" TextWrapping="Wrap"/>
  <ListBox Grid.Row="2" x:Name="FolderList" DisplayMemberPath="Name" FontSize="14" Padding="4"/>
  <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="0,12,0,0"><Button x:Name="UpButton" Content="위로" Padding="14,8"/><Button x:Name="OpenButton" Content="폴더 열기" Padding="14,8"/><StackPanel Width="20"/><Button x:Name="CancelButton" Content="취소" Padding="16,8"/><Button x:Name="SelectButton" Content="현재 폴더 선택" Padding="18,8" Background="#246BFD" Foreground="White" BorderBrush="#246BFD"/></StackPanel>
 </Grid>
</Window>
'@
    $dialog=Load-Xaml $xaml;Apply-SafeSyncThemeToWindow $dialog;$dialog.Owner=$script:Window;$list=$dialog.FindName('FolderList');$pathText=$dialog.FindName('CurrentPath')
    $pickerState=[pscustomobject]@{CurrentId=if($Provider -eq 'Dropbox'){'/'}else{'root'};CurrentLabel=if($Provider -eq 'Dropbox'){'Dropbox /'}else{'Google Drive / 내 드라이브'}}
    $history=New-Object System.Collections.ArrayList
    $loadFolders={
        $pathText.Text="$($pickerState.CurrentLabel) · 불러오는 중…";$dialog.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::Background)
        $list.ItemsSource=@(Get-SafeSyncCloudFolders $Provider $script:Config $pickerState.CurrentId);$pathText.Text=$pickerState.CurrentLabel
    }
    $openSelected={
        $selected=$list.SelectedItem;if($null -eq $selected){return}
        [void]$history.Add([pscustomobject]@{Id=$pickerState.CurrentId;Label=$pickerState.CurrentLabel});$pickerState.CurrentId=[string]$selected.Id;$pickerState.CurrentLabel="$($pickerState.CurrentLabel) / $($selected.Name)";& $loadFolders
    }
    $dialog.FindName('OpenButton').Add_Click({try{& $openSelected}catch{[System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'폴더 조회 오류')|Out-Null}})
    $list.Add_MouseDoubleClick({try{& $openSelected}catch{[System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'폴더 조회 오류')|Out-Null}})
    $dialog.FindName('UpButton').Add_Click({if($history.Count -gt 0){$previous=$history[$history.Count-1];$history.RemoveAt($history.Count-1);$pickerState.CurrentId=[string]$previous.Id;$pickerState.CurrentLabel=[string]$previous.Label;try{& $loadFolders}catch{[System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'폴더 조회 오류')|Out-Null}}})
    $dialog.FindName('SelectButton').Add_Click({$dialog.Tag=[pscustomobject]@{Id=$pickerState.CurrentId;Label=$pickerState.CurrentLabel};$dialog.DialogResult=$true;$dialog.Close()})
    $dialog.FindName('CancelButton').Add_Click({$dialog.DialogResult=$false;$dialog.Close()})
    try{& $loadFolders}catch{[System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'폴더 조회 오류')|Out-Null;return $null}
    if($dialog.ShowDialog()){return $dialog.Tag};return $null
}

function Show-JobEditor([object]$ExistingJob = $null) {
    $editorXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="백업 작업" Width="680" Height="545" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" Background="#F7F9FC" FontFamily="Segoe UI, Malgun Gothic">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Grid.Row="0" Text="백업 작업 설정" FontSize="23" FontWeight="Bold" Foreground="#172033" Margin="0,0,0,18"/>
  <Grid Grid.Row="1" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="105"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="작업 이름" VerticalAlignment="Center"/><TextBox x:Name="NameBox" Grid.Column="1" Padding="8"/></Grid>
  <Grid Grid.Row="2" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="105"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions><TextBlock Text="원본 위치" VerticalAlignment="Center"/><TextBox x:Name="SourceBox" Grid.Column="1" Padding="8"/><Button x:Name="SourceBrowse" Grid.Column="2" Content="찾아보기" Margin="8,0,0,0"/></Grid>
  <Grid Grid.Row="3" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="105"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="백업 방식" VerticalAlignment="Center"/><ComboBox x:Name="DestinationTypeBox" Grid.Column="1" Padding="7"><ComboBoxItem Content="로컬 / 네트워크 / 동기화 폴더" Tag="Local"/><ComboBoxItem Content="Dropbox API" Tag="Dropbox"/><ComboBoxItem Content="Google Drive API" Tag="GoogleDrive"/></ComboBox></Grid>
  <Grid Grid.Row="4" Margin="0,0,0,12"><Grid.ColumnDefinitions><ColumnDefinition Width="105"/><ColumnDefinition Width="*"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions><TextBlock Text="백업 위치" VerticalAlignment="Center"/><TextBox x:Name="DestinationBox" Grid.Column="1" Padding="8" IsReadOnly="True"/><Button x:Name="DestinationBrowse" Grid.Column="2" Content="위치 선택" Margin="8,0,0,0"/></Grid>
  <GroupBox Grid.Row="5" Header="실행 방식" Padding="12" Margin="0,0,0,12"><StackPanel><RadioButton x:Name="RealtimeRadio" Content="파일시스템에 변화가 있으면 자동 백업" Margin="0,3,0,9"/><StackPanel Orientation="Horizontal"><RadioButton x:Name="ScheduleRadio" Content="매일 정해진 시간에 백업" VerticalAlignment="Center"/><TextBox x:Name="TimeBox" Width="70" Margin="14,0,0,0" Padding="5" ToolTip="예: 23:30"/></StackPanel></StackPanel></GroupBox>
  <CheckBox Grid.Row="6" x:Name="MirrorCheck" Content="원본에서 사라진 파일은 백업 위치의 SafeSync 휴지통으로 이동" VerticalAlignment="Top" Margin="0,4,0,0"/>
  <StackPanel Grid.Row="7" Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="CancelButton" Content="취소" Padding="18,8" Margin="0,0,8,0"/><Button x:Name="SaveButton" Content="저장" Padding="22,8" Background="#246BFD" Foreground="White" BorderBrush="#246BFD"/></StackPanel>
 </Grid>
</Window>
'@
    $dialog = Load-Xaml $editorXaml
    Apply-SafeSyncThemeToWindow $dialog
    $dialog.Owner = $script:Window
    $nameBox = $dialog.FindName('NameBox'); $sourceBox = $dialog.FindName('SourceBox'); $destinationBox = $dialog.FindName('DestinationBox')
    $destinationTypeBox = $dialog.FindName('DestinationTypeBox')
    $realtimeRadio = $dialog.FindName('RealtimeRadio'); $scheduleRadio = $dialog.FindName('ScheduleRadio'); $timeBox = $dialog.FindName('TimeBox'); $mirrorCheck = $dialog.FindName('MirrorCheck')
    $selectionState = [pscustomobject]@{ CloudFolderId='' }
    if ($null -ne $ExistingJob) {
        $nameBox.Text = [string]$ExistingJob.Name; $sourceBox.Text = [string]$ExistingJob.Source; $destinationBox.Text = [string]$ExistingJob.Destination
        $existingType = if ($null -ne $ExistingJob.PSObject.Properties['DestinationType']) { [string]$ExistingJob.DestinationType } else { 'Local' }
        for($index=0;$index -lt $destinationTypeBox.Items.Count;$index++){if([string]$destinationTypeBox.Items[$index].Tag -eq $existingType){$destinationTypeBox.SelectedIndex=$index;break}}
        if($null -ne $ExistingJob.PSObject.Properties['CloudFolderId']){$selectionState.CloudFolderId=[string]$ExistingJob.CloudFolderId}
        $timeBox.Text = [string]$ExistingJob.ScheduleTime; $mirrorCheck.IsChecked = [bool]$ExistingJob.MirrorDeletes
        if ([string]$ExistingJob.TriggerType -eq 'Scheduled') { $scheduleRadio.IsChecked = $true } else { $realtimeRadio.IsChecked = $true }
    } else { $destinationTypeBox.SelectedIndex=0;$realtimeRadio.IsChecked = $true; $timeBox.Text = '23:00'; $mirrorCheck.IsChecked = $true }
    $dialog.FindName('SourceBrowse').Add_Click({ $chosen = Select-Folder $sourceBox.Text; if ($null -ne $chosen) { $sourceBox.Text = $chosen } })
    $destinationTypeBox.Add_SelectionChanged({$selectionState.CloudFolderId='';$destinationBox.Text=''})
    $dialog.FindName('DestinationBrowse').Add_Click({
        try{
            $type=[string]$destinationTypeBox.SelectedItem.Tag
            if($type -eq 'Local'){$chosen=Select-Folder $destinationBox.Text;if($null -ne $chosen){$destinationBox.Text=$chosen}}
            else{$chosen=Show-CloudFolderPicker $type;if($null -ne $chosen){$selectionState.CloudFolderId=[string]$chosen.Id;$destinationBox.Text="$type · $($chosen.Label)"}}
        }catch{[System.Windows.MessageBox]::Show($dialog,$_.Exception.Message,'위치 선택 오류')|Out-Null}
    })
    $dialog.FindName('CancelButton').Add_Click({ $dialog.DialogResult = $false; $dialog.Close() })
    $dialog.FindName('SaveButton').Add_Click({
        try {
            if ([string]::IsNullOrWhiteSpace($nameBox.Text)) { throw '작업 이름을 입력하세요.' }
            if (-not (Test-Path -LiteralPath $sourceBox.Text -PathType Container)) { throw '원본 위치에 접근할 수 없습니다.' }
            if ([string]::IsNullOrWhiteSpace($destinationBox.Text)) { throw '백업 위치를 입력하세요.' }
            $destinationType=[string]$destinationTypeBox.SelectedItem.Tag
            if($destinationType -eq 'Local' -and (Test-PathRelationship $sourceBox.Text $destinationBox.Text)){throw '원본과 백업 위치는 서로의 하위 폴더일 수 없습니다.'}
            if($destinationType -ne 'Local' -and [string]::IsNullOrWhiteSpace($selectionState.CloudFolderId)){throw '클라우드 폴더를 선택하세요.'}
            if ($scheduleRadio.IsChecked -and $timeBox.Text -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw '예약 시간은 00:00~23:59 형식으로 입력하세요.' }
            $dialog.Tag = [pscustomobject]@{
                Id = if ($null -ne $ExistingJob) { [string]$ExistingJob.Id } else { [guid]::NewGuid().ToString() }
                Name = $nameBox.Text.Trim(); Source = (Get-NormalizedPath $sourceBox.Text)
                DestinationType = $destinationType
                Destination = if($destinationType -eq 'Local'){Get-NormalizedPath $destinationBox.Text}else{$destinationBox.Text}
                CloudFolderId = if($destinationType -eq 'Local'){''}else{[string]$selectionState.CloudFolderId}
                TriggerType = if ($scheduleRadio.IsChecked) { 'Scheduled' } else { 'Realtime' }
                ScheduleTime = if ($scheduleRadio.IsChecked) { $timeBox.Text } else { '23:00' }
                MirrorDeletes = [bool]$mirrorCheck.IsChecked
                Paused = if ($null -ne $ExistingJob -and $null -ne $ExistingJob.PSObject.Properties['Paused']) { [bool]$ExistingJob.Paused } else { $false }
                LastScheduledRun = if ($null -ne $ExistingJob -and $null -ne $ExistingJob.LastScheduledRun) { [string]$ExistingJob.LastScheduledRun } else { '' }
            }
            $dialog.DialogResult = $true; $dialog.Close()
        } catch { [System.Windows.MessageBox]::Show($dialog, $_.Exception.Message, '입력 확인') | Out-Null }
    })
    if ($dialog.ShowDialog()) { return $dialog.Tag }
    return $null
}

function Stop-Watchers {
    foreach ($watcher in @($script:Watchers.Values)) { try { $watcher.Dispose() } catch {} }
    $script:Watchers = @{}
}

function Add-SafeSyncChangedPath([string]$JobId, [string]$Side, [string]$RelativePath) {
    $now = Get-Date
    $script:ChangedPaths["$JobId|$Side|$RelativePath"] = $now
    $script:PendingChanges[$JobId] = $now
}

function Queue-SafeSyncStartupReconciliation([object]$Job) {
    $result = Invoke-SafeSyncStartupReconciliation $Job
    if (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) { throw ([string]$result.Error) }
    if ([bool]$result.FullScanRequired) { Add-SafeSyncChangedPath ([string]$Job.Id) 'F' '*' }
    foreach ($change in @($result.Changes)) { Add-SafeSyncChangedPath ([string]$Job.Id) ([string]$change.Side) ([string]$change.RelativePath) }
}

function Start-SafeSyncReconciliationProcess([object]$Job, [switch]$ForceMetadata) {
    $jobId = [string]$Job.Id
    if ($script:ReconciliationJobs.ContainsKey($jobId)) { return }
    $resultPath = Join-Path $script:ResultRoot "reconcile-$jobId.json"
    $progressPath = Join-Path $script:ProgressRoot "$jobId.json"
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
    $powershellPath = (Get-Command powershell.exe).Source
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:ScriptPath`" -ReconcileJobId `"$jobId`" -DataRoot `"$script:DataRoot`""
    if ($ForceMetadata) { $arguments += ' -ReconcileForce' }
    try {
        $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $script:ReconciliationJobs[$jobId] = [pscustomobject]@{Process=$process;Job=$Job;ResultPath=$resultPath;ProgressPath=$progressPath}
    }
    catch { Add-Activity "'$($Job.Name)' 시작 스냅샷 확인을 실행하지 못했습니다: $($_.Exception.Message)" }
}

function Complete-SafeSyncReconciliationProcesses {
    foreach ($jobId in @($script:ReconciliationJobs.Keys)) {
        $running = $script:ReconciliationJobs[$jobId]
        if (-not $running.Process.HasExited) { continue }
        $script:ReconciliationJobs.Remove($jobId)
        $running.Process.Dispose()
        if (-not (Test-Path -LiteralPath $running.ResultPath -PathType Leaf)) { Add-Activity "'$($running.Job.Name)' 시작 스냅샷 확인 결과를 읽지 못했습니다."; continue }
        try {
            $result = Get-Content -LiteralPath $running.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) { Add-Activity "'$($running.Job.Name)' 시작 스냅샷 확인 실패: $($result.Error)"; continue }
            if ([bool]$result.SourceUnavailable) { Add-Activity "'$($running.Job.Name)' 원본에 접근할 수 없어 다음 연결 때 전체 검사를 예약했습니다."; continue }
            $triggerType = [string]$running.Job.TriggerType
            $changeCount = @($result.Changes).Count
            foreach ($change in @($result.Changes)) {
                if ([string]$change.Side -eq 'D') { Add-SafeSyncChangedPath $jobId 'D' ([string]$change.RelativePath) }
            }
            if ($triggerType -eq 'Realtime' -and ([bool]$result.FullScanRequired -or $changeCount -gt 0)) { $script:PendingChanges[$jobId] = Get-Date }
            if ([bool]$result.FullScanRequired) { Add-Activity "'$($running.Job.Name)' 시작 확인 완료 · 안전을 위해 전체 검사가 필요합니다." }
            elseif ($changeCount -gt 0) { Add-Activity "'$($running.Job.Name)' 시작 확인 완료 · 변경 파일 ${changeCount}개" }
            $reconciledState = Get-SafeSyncState $jobId
            [void](Set-SafeSyncUsnCursor $running.Job $reconciledState)
            Save-SafeSyncState $reconciledState
        }
        catch { Add-Activity "'$($running.Job.Name)' 시작 스냅샷 결과 처리 실패: $($_.Exception.Message)" }
        finally { Remove-Item -LiteralPath $running.ResultPath -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $running.ProgressPath -Force -ErrorAction SilentlyContinue }
    }
}

function Start-Watchers {
    Stop-Watchers
    foreach ($job in @($script:Config.Jobs)) {
        $jobId = [string]$job.Id
        if (Test-Path -LiteralPath $job.Source -PathType Container) {
            try {
                $sourceWatcher = [SafeSyncWatcher]::new([string]$job.Source, $jobId, $script:PendingChanges, $script:ChangedPaths, 'S', $false)
                $script:Watchers["source:$jobId"] = $sourceWatcher
            } catch { Add-Activity "'$($job.Name)' 원본 감시 시작 실패: $($_.Exception.Message)" }
        }
        $destinationType = if ($null -ne $job.PSObject.Properties['DestinationType']) { [string]$job.DestinationType } else { 'Local' }
        if ($destinationType -eq 'Local' -and (Test-Path -LiteralPath $job.Destination -PathType Container)) {
            try {
                $destinationWatcher = [SafeSyncWatcher]::new([string]$job.Destination, $jobId, $script:PendingChanges, $script:ChangedPaths, 'D', $true)
                $script:Watchers["destination:$jobId"] = $destinationWatcher
            } catch { Add-Activity "'$($job.Name)' 백업 위치 감시 시작 실패: $($_.Exception.Message)" }
        }
        if (-not (Test-SafeSyncJobPaused $job)) {
            $offline = Invoke-SafeSyncOfflineChangeDetection $job
            if ([string]$offline.Mode -eq 'Reconcile') {
                Start-SafeSyncReconciliationProcess $job -ForceMetadata
            }
            else {
                if ([int]$offline.Changes -gt 0) { Add-Activity "'$($job.Name)' 프로그램이 꺼져 있던 동안 변경된 파일 $($offline.Changes)개를 찾았습니다." }
                Queue-SafeSyncSnapshotRetries $job
            }
        }
    }
}

function Restore-MissingSourceWatchers {
    foreach ($job in @($script:Config.Jobs)) {
        $key = "source:$([string]$job.Id)"
        if (-not $script:Watchers.ContainsKey($key) -and (Test-Path -LiteralPath $job.Source -PathType Container)) {
            Start-Watchers
            return
        }
    }
}

function Save-PendingFileChanges([object]$Job) {
    $jobId = [string]$Job.Id
    $prefix = "$jobId|"
    $keys = @($script:ChangedPaths.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })
    if ($keys.Count -eq 0) { return 0 }
    $state = Get-SafeSyncState $jobId
    $pending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($state.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $pending[[string]$path] = [string]$path } }
    foreach ($key in $keys) {
        $parts = $key -split '\|', 3
        if ($parts.Count -lt 3) { continue }
        if ($parts[1] -eq 'F') { $state.FullScanRequired = $true }
        elseif (-not [string]::IsNullOrWhiteSpace($parts[2])) { $pending[$parts[2]] = $parts[2] }
    }
    $state.PendingPaths = @($pending.Values)
    Save-SafeSyncState $state
    foreach ($key in $keys) { $removed = [datetime]::MinValue; [void]$script:ChangedPaths.TryRemove($key, [ref]$removed) }
    return $keys.Count
}

function Test-ImmediateFileChange([object]$Job) {
    if ([string]$Job.TriggerType -eq 'Realtime') { return $true }
    $prefix = "$([string]$Job.Id)|D|"
    return @($script:ChangedPaths.Keys | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) }).Count -gt 0
}

function Start-BackupProcess([object]$Job, [string]$Reason = '수동', [switch]$ForceFull, [string[]]$ConflictBackupPaths=@(), [string[]]$ConflictRenamePaths=@()) {
    $id = [string]$Job.Id
    if (Test-SafeSyncJobPaused $Job) { return $false }
    if ($script:RunningJobs.ContainsKey($id) -or $script:ReconciliationJobs.ContainsKey($id)) { return $false }
    $resultPath = Join-Path $script:ResultRoot "$id.json"
    $progressPath = Join-Path $script:ProgressRoot "$id.json"
    $conflictPlanPath = ''
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
    $powershellPath = (Get-Command powershell.exe).Source
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:ScriptPath`" -WorkerJobId `"$id`" -DataRoot `"$script:DataRoot`""
    if ($ForceFull) { $arguments += ' -WorkerForceFull' }
    try {
        if(@($ConflictBackupPaths).Count -gt 0 -or @($ConflictRenamePaths).Count -gt 0){
            $conflictPlanPath=Join-Path $script:ResultRoot ("conflict-plan-$id-$([guid]::NewGuid().ToString('N')).json")
            $allBackupPaths = @($ConflictBackupPaths) + @($ConflictRenamePaths) | Select-Object -Unique
            [pscustomobject]@{JobId=$id;BackupPaths=[string[]]$allBackupPaths;RenamePaths=[string[]]@($ConflictRenamePaths)}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $conflictPlanPath -Encoding UTF8
            $arguments += " -ConflictPlanPath `"$conflictPlanPath`""
        }
        [void](Save-PendingFileChanges $Job)
        $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $lockedCountBefore = @($script:LockedFiles.Values | Where-Object { [string]$_.JobId -eq $id }).Count
        $script:RunningJobs[$id] = [pscustomobject]@{ Process=$process; Job=$Job; Reason=$Reason; ResultPath=$resultPath;ConflictPlanPath=$conflictPlanPath;LockedCountBefore=$lockedCountBefore }
        $script:LastStatus[$id] = '백업 중'
        Add-Activity "'$($Job.Name)' 백업을 시작했습니다. ($Reason)"
        Refresh-JobsGrid
        Refresh-ProgressWindow
        return $true
    } catch {
        if(-not [string]::IsNullOrWhiteSpace($conflictPlanPath)){Remove-Item -LiteralPath $conflictPlanPath -Force -ErrorAction SilentlyContinue}
        Add-Activity "'$($Job.Name)' 실행 실패: $($_.Exception.Message)"
        return $false
    }
}

function Show-Conflicts([object]$Result) {
    $job=@($script:Config.Jobs)|Where-Object{[string]$_.Id -eq [string]$Result.JobId}|Select-Object -First 1
    if($null -eq $job){[System.Windows.MessageBox]::Show($script:Window,"'$($Result.JobName)'의 작업 설정을 찾을 수 없어 충돌을 처리할 수 없습니다.",'백업 충돌')|Out-Null;return}
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="SafeSync 충돌 파일 처리" Width="980" Height="620" MinWidth="820" MinHeight="480" WindowStartupLocation="CenterOwner" Background="#F5F7FB" FontFamily="Segoe UI, Malgun Gothic">
  <Grid Margin="20"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel Margin="0,0,0,14"><TextBlock Text="확인이 필요한 파일" FontSize="23" FontWeight="Bold" Foreground="#162033"/><TextBlock Text="각 파일의 처리 방법을 선택하세요. ‘원본으로 백업’은 현재 백업 파일을 SafeSync 휴지통에 보관한 뒤 원본 파일로 교체합니다." Foreground="#64748B" Margin="0,5,0,0" TextWrapping="Wrap"/></StackPanel>
    <DataGrid Grid.Row="1" x:Name="ConflictGrid" AutoGenerateColumns="False" CanUserAddRows="False" IsReadOnly="False" HeadersVisibility="Column" GridLinesVisibility="Horizontal" RowHeight="58" Background="White" BorderBrush="#DCE3EE">
      <DataGrid.Columns>
        <DataGridTextColumn Header="파일" Binding="{Binding File}" Width="2*" IsReadOnly="True"/>
        <DataGridTextColumn Header="충돌 이유" Binding="{Binding Reason}" Width="1.6*" IsReadOnly="True"/>
        <DataGridTextColumn Header="원본" Binding="{Binding SourceInfo}" Width="155" IsReadOnly="True"/>
        <DataGridTextColumn Header="현재 백업" Binding="{Binding BackupInfo}" Width="155" IsReadOnly="True"/>
        <DataGridTemplateColumn Header="처리 방법" Width="155"><DataGridTemplateColumn.CellTemplate><DataTemplate><ComboBox ItemsSource="{Binding Choices}" DisplayMemberPath="Label" SelectedValuePath="Value" SelectedValue="{Binding Action,Mode=TwoWay,UpdateSourceTrigger=PropertyChanged}" Margin="5" Padding="5"/></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn>
      </DataGrid.Columns>
    </DataGrid>
    <Grid Grid.Row="2" Margin="0,14,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal"><Button x:Name="AllBackupButton" Content="모두 원본으로 백업" Padding="13,8" Margin="0,0,8,0"/><Button x:Name="AllIgnoreButton" Content="모두 이번에는 무시" Padding="13,8"/></StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal"><Button x:Name="CloseButton" Content="나중에 결정" Padding="16,8" Margin="0,0,8,0"/><Button x:Name="ApplyButton" Content="선택한 처리 적용" Padding="18,8" Background="#246BFD" Foreground="White" BorderBrush="#246BFD"/></StackPanel>
    </Grid>
  </Grid>
</Window>
'@
    $dialog=Load-Xaml $xaml;Apply-SafeSyncThemeToWindow $dialog;$dialog.Owner=$script:Window
    $choices=@([pscustomobject]@{Label='이번에는 무시';Value='Ignore'},[pscustomobject]@{Label='원본으로 백업';Value='Backup'})
    $rows=New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach($item in @($Result.Conflicts)){
        $reason=switch([string]$item.Reason){'Modified time matches but cloud file size differs.'{'수정 시간은 같지만 클라우드 파일의 크기가 다릅니다.'}'Cloud file is newer than the source.'{'클라우드 파일이 원본보다 최신입니다.'}'Source and cloud file metadata differs.'{'원본과 클라우드 파일의 시간 또는 크기가 다릅니다.'}default{[string]$item.Reason}}
        $rows.Add([pscustomobject]@{File=[string]$item.File;Reason=$reason;SourceInfo="$(Format-ProgressFileSize ([long]$item.SourceSize))`r`n$([string]$item.SourceModified)";BackupInfo="$(Format-ProgressFileSize ([long]$item.BackupSize))`r`n$([string]$item.BackupModified)";Action='Ignore';Choices=$choices})
    }
    $grid=$dialog.FindName('ConflictGrid');$grid.ItemsSource=$rows
    $dialog.FindName('AllBackupButton').Add_Click({foreach($row in $rows){$row.Action='Backup'};$grid.Items.Refresh()})
    $dialog.FindName('AllIgnoreButton').Add_Click({foreach($row in $rows){$row.Action='Ignore'};$grid.Items.Refresh()})
    $dialog.FindName('CloseButton').Add_Click({$dialog.Close()})
    $dialog.FindName('ApplyButton').Add_Click({
        $backupPaths=@($rows|Where-Object{[string]$_.Action -eq 'Backup'}|ForEach-Object{[string]$_.File})
        $ignored=$rows.Count-$backupPaths.Count
        if($backupPaths.Count -eq 0){Add-Activity "'$($Result.JobName)' 충돌 파일 ${ignored}개를 이번에는 무시했습니다.";$dialog.Close();return}
        if(Start-BackupProcess $job '충돌 처리' -ConflictBackupPaths $backupPaths){Add-Activity "'$($Result.JobName)' 충돌 처리: 원본으로 백업 $($backupPaths.Count)개, 이번에는 무시 ${ignored}개";$dialog.Close()}
        else{[System.Windows.MessageBox]::Show($dialog,'충돌 처리 백업을 시작하지 못했습니다. 현재 작업이 끝난 뒤 다시 시도하세요.','충돌 처리')|Out-Null}
    })
    [void]$dialog.ShowDialog()
}

function Test-SafeSyncCanShowNotices {
    return $script:Window.IsVisible -and $script:Window.WindowState -ne [System.Windows.WindowState]::Minimized
}

function Show-SafeSyncPendingNotices {
    if($script:ShowingPendingNotices -or -not (Test-SafeSyncCanShowNotices)){Update-SafeSyncNoticeIndicator;return}
    $script:ShowingPendingNotices=$true
    try{
        while($script:PendingNotices.Count -gt 0 -and (Test-SafeSyncCanShowNotices)){
            $notice=@($script:PendingNotices|Where-Object{[string]$_.Type -eq 'Error'}|Select-Object -First 1)
            if($notice.Count -eq 0){break}
            $notice=$notice[0]
            [void]$script:PendingNotices.Remove($notice)
            Save-SafeSyncNotificationState
            Update-SafeSyncNoticeIndicator
            Play-SafeSyncNotificationSound 'BackupError'
            # Notification dialogs are intentionally silent; the tray indicator and
            # the in-app notice list provide the visual cue without a system beep.
            [System.Windows.MessageBox]::Show($script:Window,(@($notice.Errors)-join "`r`n"),"'$([string]$notice.JobName)' 오류",[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::None)|Out-Null
        }
    }finally{$script:ShowingPendingNotices=$false;Refresh-ProgressConflictRows;Refresh-ProgressWindow;Update-SafeSyncNoticeIndicator}
}

function Complete-FinishedJobs {
    foreach ($id in @($script:RunningJobs.Keys)) {
        $running = $script:RunningJobs[$id]
        if (-not $running.Process.HasExited) { continue }
        $script:RunningJobs.Remove($id)
        Remove-Item -LiteralPath (Join-Path $script:ProgressRoot "$id.json") -Force -ErrorAction SilentlyContinue
        if($null -ne $running.PSObject.Properties['ConflictPlanPath'] -and -not [string]::IsNullOrWhiteSpace([string]$running.ConflictPlanPath)){Remove-Item -LiteralPath $running.ConflictPlanPath -Force -ErrorAction SilentlyContinue}
        if (Test-Path -LiteralPath $running.ResultPath) {
            try {
                $result = Get-Content -LiteralPath $running.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $lockedResultCount = if ($null -ne $result.PSObject.Properties['LockedFiles']) { @($result.LockedFiles).Count } else { 0 }
                [void](Remove-SafeSyncLockedFileErrors $result)
                if ([string]$result.Status -eq 'CompletedWithErrors' -and @($result.Errors).Count -eq 0 -and $lockedResultCount -gt 0) {
                    $result.Status = 'CompletedWithLockedFiles'
                }
                $statusText = switch ([string]$result.Status) { 'Completed' {'완료'} 'CompletedWithConflicts' {'충돌 확인 필요'} 'CompletedWithErrors' {'일부 오류'} 'CompletedWithLockedFiles' {'사용 중 파일 대기'} default {'실패'} }
                $scanText = if ($null -ne $result.PSObject.Properties['ScanMode'] -and [string]$result.ScanMode -eq 'Incremental') { '변경 파일만 검사' } elseif ($null -ne $result.PSObject.Properties['ScanMode'] -and [string]$result.ScanMode -eq 'Full') { '전체 검사' } else { '검사 방식 미확인' }
                $script:LastStatus[$id] = $statusText
                Add-Activity "'$($result.JobName)' $statusText · $scanText · 복사 $($result.Copied), 건너뜀 $($result.Skipped), 휴지통 $($result.Trashed), 사용 중 대기 $lockedResultCount"
                $newNoticeCount=[int](Add-SafeSyncResultNotices $result)
                if(Test-SafeSyncCanShowNotices){Show-SafeSyncPendingNotices}
                elseif($newNoticeCount -gt 0){Play-SafeSyncNotificationSound 'BackupError'}
                elseif($newNoticeCount -eq 0 -and @($result.Conflicts).Count -eq 0 -and @($result.Errors).Count -eq 0 -and $lockedResultCount -eq 0){ Play-SafeSyncNotificationSound 'BackupComplete'; Update-SafeSyncTrayIcon }
                if ([string]$result.Status -ne 'Failed') {
                    $completedState = Get-SafeSyncState $id
                    [void](Set-SafeSyncUsnCursor $running.Job $completedState)
                    Save-SafeSyncState $completedState
                }
                $lockedCount = [int](Refresh-SafeSyncLockedFilesForJob $running.Job)
                if ($lockedCount -gt 0) {
                    $previousDelay = if ($script:LockedRetryDelaySeconds.ContainsKey($id)) { [int]$script:LockedRetryDelaySeconds[$id] } else { 30 }
                    $madeProgress = [int]$running.LockedCountBefore -gt 0 -and $lockedCount -lt [int]$running.LockedCountBefore
                    $delay = if ([string]$running.Reason -eq '사용 중 파일 자동 재시도' -and -not $madeProgress) { [Math]::Min(300,[Math]::Max(30,$previousDelay * 2)) } else { 30 }
                    $script:LockedRetryDelaySeconds[$id] = $delay
                    $script:LockedRetryAt[$id] = (Get-Date).AddSeconds($delay)
                }
                else {
                    [void]$script:LockedRetryDelaySeconds.Remove($id)
                    [void]$script:LockedRetryAt.Remove($id)
                }
            } catch { $script:LastStatus[$id] = '결과 읽기 실패'; Add-Activity "백업 결과를 읽지 못했습니다: $($_.Exception.Message)" }
        } else { $script:LastStatus[$id] = '실패'; Add-Activity "'$($running.Job.Name)' 백업 프로세스가 결과 없이 종료되었습니다." }
        Refresh-JobsGrid
        Refresh-ProgressWindow
    }
}

function Stop-SafeSyncJobProcesses([object]$Job) {
    $id = [string]$Job.Id
    $failures = New-Object System.Collections.Generic.List[string]
    if ($script:RunningJobs.ContainsKey($id)) {
        $running = $script:RunningJobs[$id]
        try {
            if (-not $running.Process.HasExited) {
                $running.Process.Kill()
                if (-not $running.Process.WaitForExit(10000)) { throw '백업 프로세스가 제한 시간 안에 종료되지 않았습니다.' }
            }
            $running.Process.Dispose()
            [void]$script:RunningJobs.Remove($id)
            Remove-Item -LiteralPath (Join-Path $script:ProgressRoot "$id.json") -Force -ErrorAction SilentlyContinue
            if ($null -ne $running.PSObject.Properties['ConflictPlanPath'] -and -not [string]::IsNullOrWhiteSpace([string]$running.ConflictPlanPath)) { Remove-Item -LiteralPath $running.ConflictPlanPath -Force -ErrorAction SilentlyContinue }
            Add-Activity "'$($Job.Name)' 실행 중인 백업을 일시정지했습니다. 다음 실행에서 안전하게 다시 확인합니다."
        }
        catch { $failures.Add("$($Job.Name): $($_.Exception.Message)") }
    }
    if ($script:ReconciliationJobs.ContainsKey($id)) {
        $running = $script:ReconciliationJobs[$id]
        try {
            if (-not $running.Process.HasExited) {
                $running.Process.Kill()
                if (-not $running.Process.WaitForExit(10000)) { throw '스냅샷 확인 프로세스가 제한 시간 안에 종료되지 않았습니다.' }
            }
            $running.Process.Dispose()
            [void]$script:ReconciliationJobs.Remove($id)
            Remove-Item -LiteralPath $running.ResultPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $running.PSObject.Properties['ProgressPath']) { Remove-Item -LiteralPath $running.ProgressPath -Force -ErrorAction SilentlyContinue }
            Add-Activity "'$($Job.Name)' 시작 스냅샷 확인을 일시정지했습니다."
        }
        catch { $failures.Add("$($Job.Name) 스냅샷 확인: $($_.Exception.Message)") }
    }
    Refresh-ProgressWindow
    return @($failures)
}

function Set-SafeSyncJobPaused([object]$Job, [bool]$Paused) {
    if ((Test-SafeSyncJobPaused $Job) -eq $Paused) { return @() }
    $Job.Paused = $Paused
    Save-Config $script:Config
    if ($Paused) {
        $failures = @(Stop-SafeSyncJobProcesses $Job)
        try {
            [void](Save-PendingFileChanges $Job)
            $state = Get-SafeSyncState ([string]$Job.Id)
            # The worker persists a resumable checkpoint while processing files.
            # Do not force a source-wide scan merely because the user paused it.
            # A failed/in-flight file remains in PendingPaths and is retried safely.
            Save-SafeSyncState $state
        }
        catch { $failures += "다음 실행 준비: $($_.Exception.Message)" }
        $script:LastStatus[[string]$Job.Id] = '일시정지'
        Add-Activity "'$($Job.Name)' 작업을 일시정지했습니다. 파일 변화는 계속 기록합니다."
        Refresh-JobsGrid
        return @($failures)
    }
    if ([string]$Job.TriggerType -eq 'Realtime') {
        $script:PendingChanges[[string]$Job.Id] = Get-Date
        $script:LastStatus[[string]$Job.Id] = '다시 시작 대기'
        Add-Activity "'$($Job.Name)' 작업을 다시 시작했습니다. 잠시 후 안전 확인을 시작합니다."
    }
    else {
        try {
            $now = Get-Date
            $scheduledToday = [datetime]::ParseExact("$($now.ToString('yyyy-MM-dd')) $($Job.ScheduleTime)", 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            if ($now -ge $scheduledToday) {
                $Job.LastScheduledRun = $now.ToString('yyyy-MM-dd')
                Save-Config $script:Config
            }
        }
        catch { Write-AppLog "'$($Job.Name)' 예약 재개 시각 확인 실패: $($_.Exception.Message)" 'WARN' }
        $script:LastStatus[[string]$Job.Id] = '다음 예약 대기'
        Add-Activity "'$($Job.Name)' 작업을 다시 시작했습니다. 다음 예약 시간에 실행합니다."
    }
    Refresh-JobsGrid
    return @()
}

function Stop-RunningBackupProcesses {
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($id in @($script:RunningJobs.Keys)) {
        $running = $script:RunningJobs[$id]
        try {
            if (-not $running.Process.HasExited) {
                $running.Process.Kill()
                if (-not $running.Process.WaitForExit(10000)) { throw '프로세스가 제한 시간 안에 종료되지 않았습니다.' }
            }
            $running.Process.Dispose()
            $script:RunningJobs.Remove($id)
            Remove-Item -LiteralPath (Join-Path $script:ProgressRoot "$id.json") -Force -ErrorAction SilentlyContinue
            if($null -ne $running.PSObject.Properties['ConflictPlanPath'] -and -not [string]::IsNullOrWhiteSpace([string]$running.ConflictPlanPath)){Remove-Item -LiteralPath $running.ConflictPlanPath -Force -ErrorAction SilentlyContinue}
            Add-Activity "'$($running.Job.Name)' 백업 작업을 프로그램 종료 요청에 따라 중지했습니다. 다음 실행에서 미완료 작업을 복구합니다."
        }
        catch { $failures.Add("$($running.Job.Name): $($_.Exception.Message)") }
    }
    foreach ($id in @($script:ReconciliationJobs.Keys)) {
        $running = $script:ReconciliationJobs[$id]
        try {
            if (-not $running.Process.HasExited) {
                $running.Process.Kill()
                if (-not $running.Process.WaitForExit(10000)) { throw '스냅샷 확인 프로세스가 제한 시간 안에 종료되지 않았습니다.' }
            }
            $running.Process.Dispose()
            $script:ReconciliationJobs.Remove($id)
            Remove-Item -LiteralPath $running.ResultPath -Force -ErrorAction SilentlyContinue
            if($null -ne $running.PSObject.Properties['ProgressPath']){Remove-Item -LiteralPath $running.ProgressPath -Force -ErrorAction SilentlyContinue}
            Add-Activity "'$($running.Job.Name)' 시작 스냅샷 확인 작업을 종료했습니다."
        }
        catch { $failures.Add("$($running.Job.Name) 스냅샷 확인: $($_.Exception.Message)") }
    }
    return @($failures)
}

function Stop-SafeSyncApplication {
    if ($null -ne $script:TrashBrowserContext -and $script:TrashBrowserContext.State.Busy -and $script:TrashBrowserContext.State.Mode -eq 'Delete') {
        [System.Windows.MessageBox]::Show($script:TrashBrowserContext.Dialog, '휴지통 파일 삭제가 끝난 뒤 프로그램을 종료해 주세요.', 'SafeSync 종료 대기') | Out-Null
        return
    }
    if ($null -ne $script:TrashBrowserContext -and $script:TrashBrowserContext.Dialog.IsVisible) { $script:TrashBrowserContext.Dialog.Close() }
    if ($null -ne $script:AutomationTimer) { $script:AutomationTimer.Stop() }
    if ($null -ne $script:ProgressTimer) { $script:ProgressTimer.Stop() }
    $failures = @(Stop-RunningBackupProcesses)
    if ($failures.Count -gt 0) {
        if ($null -ne $script:AutomationTimer) { $script:AutomationTimer.Start() }
        if ($null -ne $script:ProgressTimer) { $script:ProgressTimer.Start() }
        [System.Windows.MessageBox]::Show($script:Window, "다음 백업 프로세스를 종료하지 못했습니다.`r`n`r`n$($failures -join "`r`n")", 'SafeSync 종료 실패', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
        return
    }
    $script:AllowExit = $true
    $script:Window.Close()
}

function Start-SafeSyncLockedRetry([object]$Job, [switch]$Immediate) {
    if ($null -eq $Job -or (Test-SafeSyncJobPaused $Job)) { return $false }
    $jobId = [string]$Job.Id
    if ($script:RunningJobs.ContainsKey($jobId) -or $script:ReconciliationJobs.ContainsKey($jobId)) { return $false }
    $state = Get-SafeSyncState $jobId
    $locked = @($state.Entries.Values | Where-Object { [string]$_.Status -eq 'Locked' })
    if ($locked.Count -eq 0) {
        [void](Refresh-SafeSyncLockedFilesForJob $Job)
        [void]$script:LockedRetryAt.Remove($jobId)
        [void]$script:LockedRetryDelaySeconds.Remove($jobId)
        return $false
    }
    $pending = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($state.PendingPaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$path)) { $pending[[string]$path] = [string]$path } }
    foreach ($entry in $locked) { $pending[[string]$entry.RelativePath] = [string]$entry.RelativePath }
    $state.PendingPaths = @($pending.Values)
    Save-SafeSyncState $state
    if (Start-BackupProcess $Job '사용 중 파일 자동 재시도') {
        # Completion chooses the next adaptive delay from the number left locked.
        $script:LockedRetryAt[$jobId] = (Get-Date).AddMinutes(10)
        return $true
    }
    $script:LockedRetryAt[$jobId] = (Get-Date).AddSeconds(30)
    return $false
}

function Invoke-SafeSyncLockedRetries {
    $now = Get-Date
    foreach ($job in @($script:Config.Jobs)) {
        $jobId = [string]$job.Id
        if (-not $script:LockedRetryAt.ContainsKey($jobId) -or $now -lt [datetime]$script:LockedRetryAt[$jobId]) { continue }
        [void](Start-SafeSyncLockedRetry $job)
    }
}

function Check-Automation {
    Complete-SafeSyncReconciliationProcesses
    Complete-FinishedJobs
    Request-SafeSyncProgressRefresh
    Restore-MissingSourceWatchers
    Invoke-SafeSyncLockedRetries
    $now = Get-Date
    foreach ($job in @($script:Config.Jobs)) {
        if (Test-SafeSyncJobPaused $job) { continue }
        $id = [string]$job.Id
        $changedAt = [datetime]::MinValue
        if ($script:PendingChanges.TryGetValue($id, [ref]$changedAt) -and ($now - $changedAt).TotalSeconds -ge 3 -and (Test-ImmediateFileChange $job)) {
            $reason = if ([string]$job.TriggerType -eq 'Realtime') { '원본 또는 백업 위치 변경' } else { '백업 위치 변경' }
            if (Start-BackupProcess $job $reason) { $discard = [datetime]::MinValue; $script:PendingChanges.TryRemove($id, [ref]$discard) | Out-Null }
        }
        if ([string]$job.TriggerType -ne 'Realtime') {
            try {
                $scheduled = [datetime]::ParseExact("$($now.ToString('yyyy-MM-dd')) $($job.ScheduleTime)", 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            } catch { continue }
            $today = $now.ToString('yyyy-MM-dd')
            if ($now -ge $scheduled -and [string]$job.LastScheduledRun -ne $today) {
                if (Start-BackupProcess $job '예약') { $job.LastScheduledRun = $today; Save-Config $script:Config; $discard = [datetime]::MinValue; $script:PendingChanges.TryRemove($id, [ref]$discard) | Out-Null }
            }
        }
    }
}

(Find-Control 'AddButton').Add_Click({
    $newJob = Show-JobEditor
    if ($null -ne $newJob) { $script:Config.Jobs = @($script:Config.Jobs) + @($newJob); Save-Config $script:Config; Start-Watchers; Refresh-JobsGrid; Add-Activity "'$($newJob.Name)' 작업을 추가했습니다." }
})
(Find-Control 'EditButton').Add_Click({
    $job = Get-SelectedJob; if ($null -eq $job) { [System.Windows.MessageBox]::Show('수정할 작업을 선택하세요.', 'SafeSync') | Out-Null; return }
    $edited = Show-JobEditor $job
    if ($null -ne $edited) { $script:Config.Jobs = @($script:Config.Jobs | Where-Object { [string]$_.Id -ne [string]$edited.Id }) + @($edited); Save-Config $script:Config; [void](Refresh-SafeSyncLockedFilesForJob $edited); Start-Watchers; Refresh-JobsGrid; Add-Activity "'$($edited.Name)' 작업을 수정했습니다." }
})
(Find-Control 'DeleteButton').Add_Click({
    $job = Get-SelectedJob; if ($null -eq $job) { [System.Windows.MessageBox]::Show('삭제할 작업을 선택하세요.', 'SafeSync') | Out-Null; return }
    if ([System.Windows.MessageBox]::Show("'$($job.Name)' 작업을 삭제할까요? 백업 파일은 삭제되지 않습니다.", '작업 삭제', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -eq [System.Windows.MessageBoxResult]::Yes) {
        $script:Config.Jobs = @($script:Config.Jobs | Where-Object { [string]$_.Id -ne [string]$job.Id }); Save-Config $script:Config; Remove-SafeSyncLockedFilesForJob ([string]$job.Id); Start-Watchers; Refresh-JobsGrid; Add-Activity "'$($job.Name)' 작업을 삭제했습니다."
    }
})
$script:PauseButton.Add_Click({
    $job = Get-SelectedJob
    if ($null -eq $job) { [System.Windows.MessageBox]::Show('일시정지하거나 다시 시작할 작업을 선택하세요.', 'SafeSync') | Out-Null; return }
    $pause = -not (Test-SafeSyncJobPaused $job)
    if ($pause -and ($script:RunningJobs.ContainsKey([string]$job.Id) -or $script:ReconciliationJobs.ContainsKey([string]$job.Id))) {
        $answer = [System.Windows.MessageBox]::Show($script:Window, "'$($job.Name)' 작업이 실행 중입니다. 현재 실행을 중단하고 일시정지할까요?`r`n`r`n완료되지 않은 파일은 다시 시작할 때 안전하게 다시 확인합니다.", '작업 일시정지', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    try {
        $failures = @(Set-SafeSyncJobPaused $job $pause)
        if ($failures.Count -gt 0) { [System.Windows.MessageBox]::Show($script:Window, "작업은 일시정지 상태로 저장했지만 다음 항목을 완전히 정리하지 못했습니다.`r`n`r`n$($failures -join "`r`n")", '일시정지 확인 필요', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null }
    }
    catch { [System.Windows.MessageBox]::Show($script:Window, $_.Exception.Message, '작업 상태 변경 오류', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null }
})
$script:RunButton.Add_Click({ $job = Get-SelectedJob; if ($null -eq $job) { [System.Windows.MessageBox]::Show('실행할 작업을 선택하세요.', 'SafeSync') | Out-Null } else { [void](Start-BackupProcess $job '빠른 수동') } })
(Find-Control 'RunAllButton').Add_Click({ foreach ($job in @($script:Config.Jobs | Where-Object { -not (Test-SafeSyncJobPaused $_) })) { [void](Start-BackupProcess $job '모든 작업 빠른 백업') } })
$script:FullScanButton.Add_Click({
    $job = Get-SelectedJob
    if ($null -eq $job) { [System.Windows.MessageBox]::Show('전체 검사할 작업을 선택하세요.', 'SafeSync') | Out-Null; return }
    if ([System.Windows.MessageBox]::Show($script:Window, "'$($job.Name)' 작업의 모든 파일을 다시 비교할까요?`r`n`r`n파일이 많거나 네트워크·클라우드 백업인 경우 시간이 오래 걸릴 수 있습니다.", '전체 검사', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question) -eq [System.Windows.MessageBoxResult]::Yes) { [void](Start-BackupProcess $job '사용자 전체 검사' -ForceFull) }
})
$script:TrashButton.Add_Click({ Show-SelectedSafeSyncTrashBrowser })
(Find-Control 'SettingsButton').Add_Click({ Show-ApplicationSettings })
$script:ProgressWindow.FindName('ConflictAllOverwriteButton').Add_Click({ foreach($row in @($script:ProgressConflictRows)){Set-SafeSyncConflictRowAction $row 'Overwrite'};$script:ProgressConflictGrid.Items.Refresh() })
$script:ProgressWindow.FindName('ConflictAllRenameButton').Add_Click({ foreach($row in @($script:ProgressConflictRows)){Set-SafeSyncConflictRowAction $row 'RenameThenCopy'};$script:ProgressConflictGrid.Items.Refresh() })
$script:ProgressWindow.FindName('ConflictAllIgnoreButton').Add_Click({ foreach($row in @($script:ProgressConflictRows)){Set-SafeSyncConflictRowAction $row 'Ignore'};$script:ProgressConflictGrid.Items.Refresh() })
$script:ProgressConflictButtonHandler=[System.Windows.RoutedEventHandler]{
    param($sender,$eventArgs)
    $button=$eventArgs.OriginalSource
    while($null -ne $button -and $button -isnot [System.Windows.Controls.Button]){$button=[System.Windows.Media.VisualTreeHelper]::GetParent($button)}
    if($button -is [System.Windows.Controls.Button] -and $null -ne $button.DataContext -and @('Overwrite','RenameThenCopy','Ignore') -contains [string]$button.Tag){
        Set-SafeSyncConflictRowAction $button.DataContext ([string]$button.Tag)
        $script:ProgressConflictGrid.Items.Refresh()
        $eventArgs.Handled=$true
    }
}
$script:ProgressConflictGrid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,$script:ProgressConflictButtonHandler,$true)
$script:ProgressConflictGrid.Add_SelectionChanged({
    $row=$script:ProgressConflictGrid.SelectedItem
    if($null -ne $row){$job=@($script:Config.Jobs)|Where-Object{[string]$_.Id -eq [string]$row.JobId}|Select-Object -First 1;Set-SafeSyncProgressRoute $job}
})
$script:ProgressLockedGrid.Add_SelectionChanged({
    $row=$script:ProgressLockedGrid.SelectedItem
    if($null -ne $row){$job=@($script:Config.Jobs)|Where-Object{[string]$_.Id -eq [string]$row.JobId}|Select-Object -First 1;Set-SafeSyncProgressRoute $job}
})
$script:ProgressWindow.FindName('RetryLockedButton').Add_Click({
    $jobIds = @($script:ProgressLockedRows | ForEach-Object { [string]$_.JobId } | Sort-Object -Unique)
    foreach ($jobId in $jobIds) {
        $job = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq $jobId } | Select-Object -First 1
        if ($null -ne $job) { [void](Start-SafeSyncLockedRetry $job -Immediate) }
    }
})
$script:ProgressWindow.FindName('ApplyConflictActionsButton').Add_Click({
    $rows=@($script:ProgressConflictRows)
    foreach($group in @($rows|Group-Object JobId)){
        $job=@($script:Config.Jobs)|Where-Object{[string]$_.Id -eq [string]$group.Name}|Select-Object -First 1
        if($null -eq $job){continue}
        $overwrite=@($group.Group|Where-Object{[string]$_.Action -eq 'Overwrite'}|ForEach-Object{[string]$_.File})
        $rename=@($group.Group|Where-Object{[string]$_.Action -eq 'RenameThenCopy'}|ForEach-Object{[string]$_.File})
        $ignored=@($group.Group|Where-Object{[string]$_.Action -eq 'Ignore'}|ForEach-Object{[string]$_.File})
        $started=$true
        if($overwrite.Count -gt 0 -or $rename.Count -gt 0){$started=Start-BackupProcess $job '진행 창 충돌 처리' -ConflictBackupPaths $overwrite -ConflictRenamePaths $rename}
        if($started){
            $processed=@($overwrite)+@($rename)+@($ignored)
            Remove-SafeSyncPendingConflictFiles ([string]$job.Id) $processed
            Add-Activity "'$($job.Name)' 충돌 처리: 덮어쓰기 $($overwrite.Count)개, 기존 백업 이름 변경 후 복사 $($rename.Count)개, 이번에는 변경 안 함 $($ignored.Count)개"
        }else{
            [System.Windows.MessageBox]::Show($script:ProgressWindow,"'$($job.Name)' 작업이 이미 실행 중이거나 일시정지되어 충돌 처리를 시작하지 못했습니다. 작업이 끝난 뒤 다시 시도하세요.",'충돌 처리',[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information)|Out-Null
        }
    }
    Refresh-ProgressConflictRows
    Refresh-ProgressWindow
})
$script:NotificationsButton.Add_Click({Show-SafeSyncPendingNotices})
$script:ProgressButton.Add_Click({ Toggle-SafeSyncProgressWindow })
(Find-Control 'MenuAddJobItem').Add_Click({
    $button = Find-Control 'AddButton'
    if ($null -ne $button -and $button.IsEnabled) { $button.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
})
(Find-Control 'MenuProgressItem').Add_Click({ Toggle-SafeSyncProgressWindow })
(Find-Control 'MenuMessagesItem').Add_Click({ Show-SafeSyncPendingNotices })
(Find-Control 'MenuCloudAccountsItem').Add_Click({ Show-CloudAccountSettings })
(Find-Control 'MenuExitItem').Add_Click({ Stop-SafeSyncApplication })
(Find-Control 'MenuAboutItem').Add_Click({
    [System.Windows.MessageBox]::Show($script:Window, "SafeSync $script:AppVersion`r`n`r`n개인용 자동 백업 관리자`r`n제작자: 임호`r`nlimfrog75@gmail.com", 'SafeSync 정보', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
})
$script:JobsGrid.Add_SelectionChanged({ Update-JobActionButtons })
$script:JobsGrid.Add_MouseDoubleClick({
    $cell = Get-SafeSyncVisualAncestor $args[1].OriginalSource ([System.Windows.Controls.DataGridCell])
    if ($null -ne $cell -and @('원본 위치','백업 위치') -contains [string]$cell.Column.Header) {
        $row = $cell.DataContext
        $job = @($script:Config.Jobs) | Where-Object { [string]$_.Id -eq [string]$row.Id } | Select-Object -First 1
        if ($null -ne $job) { Open-SafeSyncJobFolder $job $(if([string]$cell.Column.Header -eq '원본 위치'){'Source'}else{'Destination'}) }
        return
    }
    $job = Get-SelectedJob
    if ($null -ne $job) {
        $edited = Show-JobEditor $job
        if ($null -ne $edited) { $script:Config.Jobs = @($script:Config.Jobs | Where-Object { [string]$_.Id -ne [string]$edited.Id }) + @($edited); Save-Config $script:Config; Start-Watchers; Refresh-JobsGrid }
    }
})

if ($null -eq ('SafeSyncTrayNativeMethods' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SafeSyncTrayNativeMethods {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@
}
$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$iconPath = Join-Path (Split-Path -Parent $script:ScriptPath) 'SafeSync.ico'
if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
    try { $script:AppIcon = New-Object System.Drawing.Icon($iconPath) } catch { $script:AppIcon = $null }
}
$script:NotifyIcon.Icon = if ($null -ne $script:AppIcon) { $script:AppIcon } else { [System.Drawing.SystemIcons]::Shield }
$script:NotifyIcon.Text = 'SafeSync - 자동 백업 실행 중'
$script:NotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::None
$script:NotifyIcon.Visible = $true

function Get-SafeSyncTrayMenuLocation([System.Drawing.Point]$Cursor, [System.Drawing.Rectangle]$WorkingArea, [System.Drawing.Size]$MenuSize) {
    $width = [Math]::Max(1, $MenuSize.Width)
    $height = [Math]::Max(1, $MenuSize.Height)
    # Prefer the area above and to the left of the tray pointer. This also works
    # when the icon is inside Windows' overflow flyout instead of the taskbar.
    $x = $Cursor.X - $width
    $y = $Cursor.Y - $height
    if ($Cursor.X -le $WorkingArea.Left) { $x = $WorkingArea.Left }
    elseif ($Cursor.X -ge $WorkingArea.Right) { $x = $WorkingArea.Right - $width }
    if ($Cursor.Y -le $WorkingArea.Top) { $y = $WorkingArea.Top }
    elseif ($Cursor.Y -ge $WorkingArea.Bottom) { $y = $WorkingArea.Bottom - $height }
    $maxX = [Math]::Max($WorkingArea.Left, $WorkingArea.Right - $width)
    $maxY = [Math]::Max($WorkingArea.Top, $WorkingArea.Bottom - $height)
    $x = [Math]::Min($maxX, [Math]::Max($WorkingArea.Left, $x))
    $y = [Math]::Min($maxY, [Math]::Max($WorkingArea.Top, $y))
    return [System.Drawing.Point]::new($x, $y)
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openItem = $trayMenu.Items.Add('SafeSync 열기')
$runAllItem = $trayMenu.Items.Add('전체 백업 실행')
[void]$trayMenu.Items.Add('-')
$exitItem = $trayMenu.Items.Add('프로그램 종료')
$script:NotifyIcon.ContextMenuStrip = $trayMenu
$trayMenu.add_Opened({
    try {
        # NotifyIcon's automatic position can mix physical pixels with WPF DIPs
        # on a scaled display. Always re-anchor to the real pointer and monitor.
        $cursor = [System.Windows.Forms.Control]::MousePosition
        $workingArea = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
        $menuSize = $trayMenu.Size
        if ($menuSize.Width -le 1 -or $menuSize.Height -le 1) { $menuSize = $trayMenu.GetPreferredSize([System.Drawing.Size]::Empty) }
        $trayMenu.Location = Get-SafeSyncTrayMenuLocation $cursor $workingArea $menuSize
    }
    catch {}
})
function Show-SafeSyncMainWindow {
    # Tray events can arrive back-to-back (for example a double-click followed by
    # a queued menu event). Prevent a second Show() while WPF is still attaching
    # the first window's visual tree.
    if ($script:MainWindowTransitioning) { return }
    $script:MainWindowTransitioning = $true
    try {
        $script:Window.ShowInTaskbar = $true
        if (-not $script:Window.IsVisible) { $script:Window.Show() }
        $script:Window.WindowState = [System.Windows.WindowState]::Normal
        [void]$script:Window.Activate()
    }
    finally { $script:MainWindowTransitioning = $false }
    Refresh-ProgressWindow
    [void]$script:Window.Dispatcher.BeginInvoke([action]{Show-SafeSyncPendingNotices},[System.Windows.Threading.DispatcherPriority]::Background)
}
$showWindow = { Show-SafeSyncMainWindow }
$openItem.add_Click($showWindow)
$script:NotifyIcon.add_MouseDoubleClick({ param($sender,$eventArgs); if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $showWindow } })
$runAllItem.add_Click({ $script:Window.Dispatcher.Invoke([action]{ foreach ($job in @($script:Config.Jobs | Where-Object { -not (Test-SafeSyncJobPaused $_) })) { [void](Start-BackupProcess $job '알림 영역 빠른 백업') } }) })
$exitItem.add_Click({ $script:Window.Dispatcher.Invoke([action]{ Stop-SafeSyncApplication }) })
$script:ProgressWindow.Add_Closing({ param($sender,$eventArgs); if (-not $script:AllowExit) { $eventArgs.Cancel=$true; Hide-SafeSyncProgressWindow } })
$script:Window.Add_ContentRendered({ Apply-SafeSyncTheme })
$script:ProgressWindow.Add_ContentRendered({ Apply-SafeSyncThemeToWindow $script:ProgressWindow })
$script:Window.Add_StateChanged({
    Request-SafeSyncProgressRefresh
    if ($script:Window.WindowState -eq [System.Windows.WindowState]::Minimized -and $script:Window.IsVisible) { Play-SafeSyncNotificationSound 'Minimize' }
    if($script:Window.WindowState -eq [System.Windows.WindowState]::Normal){[void]$script:Window.Dispatcher.BeginInvoke([action]{Show-SafeSyncPendingNotices},[System.Windows.Threading.DispatcherPriority]::Background)}
})
$script:Window.Add_IsVisibleChanged({ Request-SafeSyncProgressRefresh })
$script:Window.Add_Activated({ if ($script:ProgressWindow.IsVisible) { $script:ProgressWindow.Topmost = $false } })
$script:Window.Add_SizeChanged({ Request-SafeSyncWindowLayoutSave })
$script:ProgressWindow.Add_SizeChanged({ Request-SafeSyncWindowLayoutSave })
$script:MainLayoutSplitter.Add_DragCompleted({ Request-SafeSyncWindowLayoutSave })
$script:ProgressLayoutSplitter.Add_DragCompleted({ Request-SafeSyncWindowLayoutSave })
$script:Window.Add_Closing({ param($sender,$eventArgs); if (-not $script:AllowExit) { $eventArgs.Cancel = $true; Play-SafeSyncNotificationSound 'Minimize'; Set-SafeSyncProgressWindowVisibility $false; $script:Window.Hide(); $script:Window.ShowInTaskbar = $false; Update-SafeSyncTrayIcon } })
$script:Window.Add_Closed({ Save-SafeSyncWindowLayout; if ($null -ne $script:LayoutSaveTimer) { $script:LayoutSaveTimer.Stop() }; Stop-Watchers; $script:ProgressWindow.Close(); if ($null -ne $script:TrayAnimationTimer) { $script:TrayAnimationTimer.Stop() }; $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose(); $trayMenu.Dispose(); Dispose-SafeSyncTrayAnimation; if ($null -ne $script:AppIcon) { $script:AppIcon.Dispose(); $script:AppIcon = $null }; $script:AutomationTimer.Stop(); $script:ProgressTimer.Stop(); $mutex.ReleaseMutex(); $mutex.Dispose(); if ($null -ne [System.Windows.Application]::Current) { [System.Windows.Application]::Current.Shutdown() } })

$script:AutomationTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
$script:AutomationTimer.Interval = [TimeSpan]::FromSeconds(2)
$script:AutomationTimer.Add_Tick({ Check-Automation })
$script:ProgressTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
$script:ProgressTimer.Interval = [TimeSpan]::FromMilliseconds(750)
$script:ProgressTimer.Add_Tick({ Request-SafeSyncProgressRefresh })
$script:TrayAnimationTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
$script:TrayAnimationTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:TrayAnimationTimer.Add_Tick({ Update-SafeSyncTrayIcon })
Refresh-ProgressConflictRows
Update-SafeSyncNoticeIndicator
Refresh-JobsGrid
Initialize-SafeSyncLockedFiles
Start-Watchers
Add-Activity '자동 백업 엔진이 시작되었습니다.'
$script:AutomationTimer.Start()
$script:ProgressTimer.Start()
$script:TrayAnimationTimer.Start()

if ($ExitAfterStartupForTest) {
    $script:ExitTestTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ExitTestTimer.Interval = [TimeSpan]::FromMilliseconds(600)
    $script:ExitTestTimer.Add_Tick({ $script:ExitTestTimer.Stop(); Stop-SafeSyncApplication })
    $script:ExitTestTimer.Start()
}

$script:WpfApplication = New-Object System.Windows.Application
$script:WpfApplication.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:WpfApplication.add_DispatcherUnhandledException({
    param($sender,$eventArgs)
    # Do not expose PowerShell/.NET's raw exception dialog to the user. Record the
    # complete stack for diagnosis and keep the backup engine alive when a UI
    # event fails. The known VisualTarget error is also cleared for the next
    # serialized window transition.
    try {
        $exception = $eventArgs.Exception
        $detail = if ($null -ne $exception) { "$($exception.Message)`r`n$($exception.StackTrace)" } else { '알 수 없는 WPF 화면 오류' }
        Write-AppLog "화면 처리 오류를 복구했습니다: $detail" 'ERROR'
        if ($null -ne $exception -and $exception.Message -match 'VisualTarget|root Visual|루트 Visual') {
            $script:ProgressWindowTransitioning = $false
            $script:MainWindowTransitioning = $false
        }
        Add-Activity '프로그램 화면 처리 오류를 복구했습니다. 자세한 내용은 로그에 기록했습니다.'
    } catch {}
    $eventArgs.Handled = $true
})
$script:Window.ShowInTaskbar = $false
if ($StartVisible -and -not $Minimized) { & $showWindow }
[void]$script:WpfApplication.Run()
