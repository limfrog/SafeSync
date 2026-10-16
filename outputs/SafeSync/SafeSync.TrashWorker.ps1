[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('List','Delete')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$JobId,
    [Parameter(Mandatory=$true)][string]$DataRoot,
    [string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [Parameter(Mandatory=$true)][string]$ProgressPath,
    [string]$PartialRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:DataRoot = [System.IO.Path]::GetFullPath($DataRoot)
$script:ConfigPath = Join-Path $script:DataRoot 'config.json'
$script:LastProgressWriteUtc = [datetime]::MinValue
$script:WorkerLifetimeMutex = $null
$script:PartialItems = New-Object System.Collections.Generic.List[object]
$script:PartialSequence = 0
$script:LastPartialWriteUtc = [datetime]::UtcNow
$script:GoogleTrashFolders = @{}
$script:GoogleTrashRootId = ''
$script:GoogleChangeToken = ''

function Write-TrashWorkerJson([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    $temporary = "$Path.$PID.tmp"
    $Value | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-TrashWorkerProgress([string]$Text, [int]$Folders = 0, [int]$Files = 0, [switch]$Force) {
    $now = [datetime]::UtcNow
    if (-not $Force -and ($now - $script:LastProgressWriteUtc).TotalMilliseconds -lt 300) { return }
    $script:LastProgressWriteUtc = $now
    try {
        Write-TrashWorkerJson $ProgressPath ([pscustomobject]@{ Text=$Text; Folders=$Folders; Files=$Files; UpdatedAt=$now.ToString('o') })
    }
    catch {}
}

function Publish-TrashWorkerPartial([object[]]$NewItems = @(), [switch]$Force) {
    if ([string]::IsNullOrWhiteSpace($PartialRoot)) { return }
    foreach ($item in @($NewItems)) { $script:PartialItems.Add($item) }
    if ($script:PartialItems.Count -eq 0) { return }
    if (-not $Force -and $script:PartialItems.Count -lt 50 -and ([datetime]::UtcNow - $script:LastPartialWriteUtc).TotalSeconds -lt 1) { return }
    [void][System.IO.Directory]::CreateDirectory($PartialRoot)
    $script:PartialSequence++
    $path = Join-Path $PartialRoot ('{0:D6}.json' -f $script:PartialSequence)
    Write-TrashWorkerJson $path ([pscustomobject]@{ Items=$script:PartialItems.ToArray() })
    $script:PartialItems.Clear()
    $script:LastPartialWriteUtc = [datetime]::UtcNow
}

function Get-TrashCachePath([object]$Job) {
    $jobId = [string]$Job.Id
    if ($jobId -notmatch '^[a-zA-Z0-9_-]{1,80}$') { throw '휴지통 작업 식별자가 안전하지 않습니다.' }
    return Join-Path (Join-Path $script:DataRoot 'trash-cache') "$jobId.json"
}

function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -eq $root.Length) { return $root }
    return $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function ConvertTo-SafeSyncRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return $Path.Replace('\','/').TrimStart('/')
}

function Format-ProgressFileSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
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

function New-TrashItem([string]$Provider, [string]$RelativePath, [datetime]$DeletedAt, [long]$Size, [string]$OriginalPath,
                       [string]$TrashPath, [string]$TrashRoot, [string]$RemoteId = '', [string]$RemoteParentId = '') {
    $relative = ConvertTo-SafeSyncRelativePath $RelativePath
    return [pscustomobject]@{
        Provider=$Provider; Name=[System.IO.Path]::GetFileName($relative); DeletedAt=$DeletedAt
        DeletedAtText=$DeletedAt.ToString('yyyy-MM-dd HH:mm:ss'); OriginalPath=$OriginalPath
        RelativePath=$relative; Size=$Size; SizeText=(Format-ProgressFileSize $Size)
        TrashPath=$TrashPath; TrashRoot=$TrashRoot; RemoteId=$RemoteId; RemoteParentId=$RemoteParentId
    }
}

function Get-LocalTrashItems([object]$Job) {
    $destinationRoot = Get-NormalizedPath ([string]$Job.Destination)
    $trashRoot = Join-Path $destinationRoot '.safesync-trash'
    if (-not (Test-Path -LiteralPath $trashRoot -PathType Container)) { return @() }
    $trashRootFull = [System.IO.Path]::GetFullPath($trashRoot).TrimEnd('\','/')
    $prefix = $trashRootFull + [System.IO.Path]::DirectorySeparatorChar
    $items = New-Object System.Collections.Generic.List[object]
    $count = 0
    foreach ($file in Get-ChildItem -LiteralPath $trashRootFull -File -Recurse -Force -ErrorAction Stop) {
        $count++
        if (($count % 100) -eq 0) { Write-TrashWorkerProgress "로컬 휴지통 파일을 확인하고 있습니다. (${count}개)" 0 $count }
        $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
        if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $insideTrash = $fullPath.Substring($prefix.Length)
        $parts = $insideTrash -split '[\\/]', 2
        $bundleName = if ($parts.Count -gt 1) { [string]$parts[0] } else { '' }
        $relativePath = if ($parts.Count -gt 1) { [string]$parts[1] } else { [string]$file.Name }
        $relativePath = ConvertTo-SafeSyncRelativePath $relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) { continue }
        $deletedAt = Get-SafeSyncTrashDeletedAt $bundleName $file.CreationTime
        $item = New-TrashItem 'Local' $relativePath $deletedAt ([long]$file.Length) (Join-Path $destinationRoot $relativePath.Replace('/','\')) $fullPath $trashRootFull
        $items.Add($item)
        Publish-TrashWorkerPartial @($item)
    }
    Publish-TrashWorkerPartial -Force
    Write-TrashWorkerProgress "로컬 휴지통 파일 ${count}개를 확인했습니다." 0 $count -Force
    return @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Get-DropboxTrashItems([object]$Job, [object]$Config) {
    $token = Get-SafeSyncCloudAccessToken 'Dropbox' $Config
    $trashRoot = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) '.safesync-trash'
    $prefix = $trashRoot.TrimEnd('/') + '/'
    $path = if ($trashRoot -eq '/') { '' } else { $trashRoot }
    try { $response = Invoke-SafeSyncDropboxRpc $token 'files/list_folder' @{ path=$path; recursive=$true; include_deleted=$false; include_non_downloadable_files=$true } }
    catch {
        $details = if ($null -ne $_.ErrorDetails) { [string]$_.ErrorDetails.Message } else { '' }
        if (($_.Exception.Message + ' ' + $details) -match 'not_found|path/not_found') { return @() }
        throw
    }
    $entries = New-Object System.Collections.Generic.List[object]
    do {
        foreach ($entry in @($response.entries)) { $entries.Add($entry) }
        Write-TrashWorkerProgress "Dropbox 휴지통 정보를 받고 있습니다. ($($entries.Count)개)" 0 $entries.Count
        if (-not [bool]$response.has_more) { break }
        $response = Invoke-SafeSyncDropboxRpc $token 'files/list_folder/continue' @{ cursor=[string]$response.cursor }
    } while ($true)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $tag = if ($null -ne $entry.PSObject.Properties['.tag']) { [string]$entry.PSObject.Properties['.tag'].Value } else { '' }
        if ($tag -eq 'folder') { continue }
        $remotePath = [string]$entry.path_display
        if (-not $remotePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $insideTrash = $remotePath.Substring($prefix.Length)
        $parts = $insideTrash -split '/', 2
        if ($parts.Count -lt 2) { continue }
        $relative = ConvertTo-SafeSyncRelativePath ([string]$parts[1])
        $fallback = Get-Date
        if ($null -ne $entry.PSObject.Properties['server_modified']) { [void][datetime]::TryParse([string]$entry.server_modified, [ref]$fallback) }
        $deletedAt = Get-SafeSyncTrashDeletedAt ([string]$parts[0]) $fallback.ToLocalTime()
        [long]$size = if ($null -ne $entry.PSObject.Properties['size']) { [long]$entry.size } else { 0 }
        $remoteId = if ($null -ne $entry.PSObject.Properties['id']) { [string]$entry.id } else { $remotePath }
        $original = ([string]$Job.Destination).TrimEnd('/','\') + ' / ' + $relative
        $item = New-TrashItem 'Dropbox' $relative $deletedAt $size $original $remotePath $trashRoot $remoteId ''
        $items.Add($item)
        Publish-TrashWorkerPartial @($item)
    }
    Publish-TrashWorkerPartial -Force
    Write-TrashWorkerProgress "Dropbox 휴지통 파일 $($items.Count)개를 확인했습니다." 0 $items.Count -Force
    return @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Get-TrashGoogleChildren([string]$Token, [string]$ParentId, [string]$Name = '') {
    $items = New-Object System.Collections.Generic.List[object]
    $pageToken = ''
    do {
        $query = "'$($ParentId.Replace("'","\'"))' in parents and trashed = false"
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $query += " and name = '$($Name.Replace("'","\'"))'" }
        $values = @{ q=$query; spaces='drive'; pageSize='1000'; fields='nextPageToken,files(id,name,mimeType,parents,modifiedTime,createdTime,size)' }
        if (-not [string]::IsNullOrWhiteSpace($pageToken)) { $values.pageToken = $pageToken }
        $uri = 'https://www.googleapis.com/drive/v3/files?' + (ConvertTo-SafeSyncQuery $values)
        $response = Invoke-SafeSyncGoogleRequest $Token { param($activeToken) Invoke-RestMethod -Method Get -Uri $uri -Headers @{Authorization="Bearer $activeToken"} }
        foreach ($item in @($response.files)) { $items.Add($item) }
        $pageToken = if ($null -ne $response.PSObject.Properties['nextPageToken']) { [string]$response.nextPageToken } else { '' }
    } while (-not [string]::IsNullOrWhiteSpace($pageToken))
    return $items.ToArray()
}

function Get-GoogleTrashFolder([string]$Token, [object]$Job) {
    return @(Get-TrashGoogleChildren $Token ([string]$Job.CloudFolderId) '.safesync-trash' | Where-Object {
        [string]$_.name -eq '.safesync-trash' -and [string]$_.mimeType -eq 'application/vnd.google-apps.folder'
    } | Select-Object -First 1)
}

function Get-GoogleTrashItems([object]$Job, [object]$Config) {
    $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $Config
    $trashFolder = @(Get-GoogleTrashFolder $token $Job)
    if ($trashFolder.Count -eq 0) { return @() }
    $script:GoogleTrashRootId = [string]$trashFolder[0].id
    $script:GoogleTrashFolders = @{ $script:GoogleTrashRootId = '' }
    $items = New-Object System.Collections.Generic.List[object]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Id=[string]$trashFolder[0].id; Relative='' })
    $folderCount = 0
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $folderCount++
        foreach ($remote in @(Get-TrashGoogleChildren $token ([string]$current.Id))) {
            $insideTrash = if ([string]::IsNullOrWhiteSpace([string]$current.Relative)) { [string]$remote.name } else { "$($current.Relative)/$($remote.name)" }
            if ([string]$remote.mimeType -eq 'application/vnd.google-apps.folder') {
                $script:GoogleTrashFolders[[string]$remote.id] = $insideTrash
                $queue.Enqueue([pscustomobject]@{ Id=[string]$remote.id; Relative=$insideTrash })
                continue
            }
            $parts = $insideTrash -split '/', 2
            if ($parts.Count -lt 2) { continue }
            $relative = ConvertTo-SafeSyncRelativePath ([string]$parts[1])
            $fallback = Get-Date
            if ($null -ne $remote.PSObject.Properties['modifiedTime']) { [void][datetime]::TryParse([string]$remote.modifiedTime, [ref]$fallback) }
            $deletedAt = Get-SafeSyncTrashDeletedAt ([string]$parts[0]) $fallback.ToLocalTime()
            [long]$size = if ($null -ne $remote.PSObject.Properties['size']) { [long]$remote.size } else { 0 }
            $original = ([string]$Job.Destination).TrimEnd('/','\') + ' / ' + $relative
            $item = New-TrashItem 'GoogleDrive' $relative $deletedAt $size $original $insideTrash ([string]$trashFolder[0].id) ([string]$remote.id) ([string]$current.Id)
            $items.Add($item)
            Publish-TrashWorkerPartial @($item)
        }
        Write-TrashWorkerProgress "Google Drive 휴지통을 확인하고 있습니다. (폴더 ${folderCount}개, 파일 $($items.Count)개)" $folderCount $items.Count
    }
    Publish-TrashWorkerPartial -Force
    Write-TrashWorkerProgress "Google Drive 휴지통 파일 $($items.Count)개를 확인했습니다." $folderCount $items.Count -Force
    return @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Get-CachedGoogleTrashItems([object]$Job, [object]$Config, [object]$Cache) {
    if ([string]::IsNullOrWhiteSpace([string]$Cache.GoogleChangeToken) -or
        [string]::IsNullOrWhiteSpace([string]$Cache.GoogleTrashRootId)) { throw '저장된 Google Drive 변경 기준점이 없습니다.' }
    $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $Config
    $trashFolder = @(Get-GoogleTrashFolder $token $Job)
    if ($trashFolder.Count -eq 0 -or [string]$trashFolder[0].id -ne [string]$Cache.GoogleTrashRootId) {
        throw 'Google Drive 휴지통 폴더가 변경되었습니다.'
    }
    $script:GoogleTrashRootId = [string]$Cache.GoogleTrashRootId
    $script:GoogleTrashFolders = @{}
    foreach ($property in @($Cache.GoogleFolders.PSObject.Properties)) { $script:GoogleTrashFolders[[string]$property.Name] = [string]$property.Value }
    if (-not $script:GoogleTrashFolders.ContainsKey($script:GoogleTrashRootId)) { throw '휴지통 폴더 색인이 손상되었습니다.' }
    $byId = @{}
    foreach ($item in @($Cache.Items)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$item.RemoteId)) { $byId[[string]$item.RemoteId] = $item }
    }
    $feed = Get-SafeSyncGoogleChanges $token ([string]$Cache.GoogleChangeToken)
    $changes = @($feed.Changes)
    $processed = 0
    foreach ($change in $changes) {
        $id = [string]$change.fileId
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $processed++
        if (($processed % 100) -eq 0) { Write-TrashWorkerProgress "Google Drive 변경 사항을 확인하고 있습니다. ($processed/$($changes.Count))" 0 $byId.Count }
        if ([bool]$change.removed -or $null -eq $change.file) {
            if ($script:GoogleTrashFolders.ContainsKey($id)) { throw '휴지통 폴더가 삭제되어 목록을 다시 확인해야 합니다.' }
            [void]$byId.Remove($id)
            continue
        }
        $remote = $change.file
        $parentId = if (@($remote.parents).Count -gt 0) { [string]@($remote.parents)[0] } else { '' }
        if ([string]$remote.mimeType -eq 'application/vnd.google-apps.folder') {
            if ($script:GoogleTrashFolders.ContainsKey($id)) {
                $oldPath = [string]$script:GoogleTrashFolders[$id]
                if ([bool]$remote.trashed -or -not $script:GoogleTrashFolders.ContainsKey($parentId)) { throw '휴지통 폴더가 이동되어 목록을 다시 확인해야 합니다.' }
                $newPath = if ($parentId -eq $script:GoogleTrashRootId) { [string]$remote.name } else { "$($script:GoogleTrashFolders[$parentId])/$([string]$remote.name)" }
                if ($newPath -ne $oldPath) { throw '휴지통 폴더 이름이 변경되어 목록을 다시 확인해야 합니다.' }
            }
            elseif (-not [bool]$remote.trashed -and $script:GoogleTrashFolders.ContainsKey($parentId)) {
                $newPath = if ($parentId -eq $script:GoogleTrashRootId) { [string]$remote.name } else { "$($script:GoogleTrashFolders[$parentId])/$([string]$remote.name)" }
                $created = [datetime]::MinValue
                if (-not [datetime]::TryParse([string]$remote.createdTime, [ref]$created) -or $created.ToUniversalTime() -lt ([datetime]$Cache.IndexedAtUtc).AddMinutes(-1)) {
                    throw '기존 폴더가 휴지통으로 이동되어 목록을 다시 확인해야 합니다.'
                }
                $script:GoogleTrashFolders[$id] = $newPath
            }
            continue
        }
        [void]$byId.Remove($id)
        if ([bool]$remote.trashed -or -not $script:GoogleTrashFolders.ContainsKey($parentId)) { continue }
        $insideTrash = if ($parentId -eq $script:GoogleTrashRootId) { [string]$remote.name } else { "$($script:GoogleTrashFolders[$parentId])/$([string]$remote.name)" }
        $parts = $insideTrash -split '/', 2
        if ($parts.Count -lt 2) { continue }
        $relative = ConvertTo-SafeSyncRelativePath ([string]$parts[1])
        $fallback = Get-Date
        if ($null -ne $remote.PSObject.Properties['modifiedTime']) { [void][datetime]::TryParse([string]$remote.modifiedTime, [ref]$fallback) }
        $deletedAt = Get-SafeSyncTrashDeletedAt ([string]$parts[0]) $fallback.ToLocalTime()
        [long]$size = if ($null -ne $remote.PSObject.Properties['size']) { [long]$remote.size } else { 0 }
        $original = ([string]$Job.Destination).TrimEnd('/','\') + ' / ' + $relative
        $byId[$id] = New-TrashItem 'GoogleDrive' $relative $deletedAt $size $original $insideTrash $script:GoogleTrashRootId $id $parentId
    }
    $script:GoogleChangeToken = [string]$feed.Token
    Write-TrashWorkerProgress "Google Drive 변경 사항 ${processed}개를 확인했습니다." 0 $byId.Count -Force
    return @($byId.Values | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
}

function Assert-NoReparseWithin([string]$Root, [string]$Path) {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full = [System.IO.Path]::GetFullPath($Path)
    Assert-SafeSyncPathWithin $rootFull $full
    for ($current = $full; -not [string]::IsNullOrWhiteSpace($current); $current = Split-Path -Parent $current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw '연결 파일 또는 연결 폴더는 안전을 위해 삭제할 수 없습니다.'
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
    }
}

function Remove-EmptyTrashParents([string]$ItemPath, [string]$TrashRoot) {
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

function Remove-SelectedTrashItems([object]$Job, [object]$Config, [object[]]$Items) {
    $result = [ordered]@{ Deleted=0; Errors=@() }
    $destinationType = if ($null -ne $Job.PSObject.Properties['DestinationType']) { [string]$Job.DestinationType } else { 'Local' }
    $token = ''
    $actualTrashRoot = ''
    if ($destinationType -eq 'Dropbox') {
        $token = Get-SafeSyncCloudAccessToken 'Dropbox' $Config
        $actualTrashRoot = Join-SafeSyncDropboxPath ([string]$Job.CloudFolderId) '.safesync-trash'
    }
    elseif ($destinationType -eq 'GoogleDrive') {
        $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $Config
        $folder = @(Get-GoogleTrashFolder $token $Job)
        if ($folder.Count -eq 0) { throw 'Google Drive의 SafeSync 휴지통을 찾을 수 없습니다.' }
        $actualTrashRoot = [string]$folder[0].id
    }
    else {
        $actualTrashRoot = Join-Path (Get-NormalizedPath ([string]$Job.Destination)) '.safesync-trash'
    }
    $completed = 0
    foreach ($item in @($Items)) {
        try {
            if ($destinationType -eq 'Dropbox') {
                $path = [string]$item.TrashPath
                $prefix = $actualTrashRoot.TrimEnd('/') + '/'
                if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '선택한 항목이 이 작업의 휴지통 밖에 있습니다.' }
                [void](Invoke-SafeSyncDropboxRpc $token 'files/delete_v2' @{ path=$path })
            }
            elseif ($destinationType -eq 'GoogleDrive') {
                $remoteId = [string]$item.RemoteId
                if ([string]::IsNullOrWhiteSpace($remoteId) -or $remoteId -eq [string]$Job.CloudFolderId -or $remoteId -eq $actualTrashRoot) { throw '삭제할 Google Drive 파일 식별자가 안전하지 않습니다.' }
                if ([string]$item.TrashRoot -ne $actualTrashRoot) { throw '선택한 항목이 이 작업의 Google Drive 휴지통에 속하지 않습니다.' }
                $escaped = [Uri]::EscapeDataString($remoteId)
                $uri = "https://www.googleapis.com/drive/v3/files/$escaped`?supportsAllDrives=true"
                [void](Invoke-SafeSyncGoogleRequest $token { param($activeToken) Invoke-RestMethod -Method Delete -Uri $uri -Headers @{Authorization="Bearer $activeToken"} })
            }
            else {
                $path = [System.IO.Path]::GetFullPath([string]$item.TrashPath)
                Assert-NoReparseWithin $actualTrashRoot $path
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '휴지통 파일을 찾을 수 없습니다.' }
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                Remove-EmptyTrashParents $path $actualTrashRoot
            }
            $result.Deleted++
        }
        catch { $result.Errors += "$([string]$item.Name) : $($_.Exception.Message)" }
        $completed++
        Write-TrashWorkerProgress "선택한 파일을 완전히 삭제하고 있습니다. ($completed/$($Items.Count))" 0 $completed -Force
    }
    return [pscustomobject]$result
}

try {
    $mainScriptPath = Join-Path $PSScriptRoot 'SafeSync.ps1'
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = [System.IO.Path]::GetFullPath($mainScriptPath).ToLowerInvariant()
        $hash = [System.BitConverter]::ToString($hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '').ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
    $script:WorkerLifetimeMutex = [System.Threading.Mutex]::new($false, "Local\SafeSync.Workers.$hash")
    . (Join-Path $PSScriptRoot 'SafeSync.Integrity.ps1')
    . (Join-Path $PSScriptRoot 'SafeSync.Cloud.ps1')
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { throw 'SafeSync 설정 파일을 찾을 수 없습니다.' }
    $config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $job = @($config.Jobs) | Where-Object { [string]$_.Id -eq $JobId } | Select-Object -First 1
    if ($null -eq $job) { throw '선택한 백업 작업을 찾을 수 없습니다.' }
    Write-TrashWorkerProgress '휴지통 정보를 준비하고 있습니다.' 0 0 -Force
    if ($Mode -eq 'List') {
        $destinationType = if ($null -ne $job.PSObject.Properties['DestinationType']) { [string]$job.DestinationType } else { 'Local' }
        $cachedItems = $null
        if ($destinationType -eq 'GoogleDrive') {
            $cachePath = Get-TrashCachePath $job
            if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
                try {
                    $cache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$cache.JobId -eq [string]$job.Id -and [string]$cache.DestinationType -eq 'GoogleDrive' -and
                        [string]$cache.Destination -eq [string]$job.Destination -and [string]$cache.CloudFolderId -eq [string]$job.CloudFolderId) {
                        Write-TrashWorkerProgress 'Google Drive 변경된 파일만 확인하고 있습니다.' 0 @($cache.Items).Count -Force
                        $cachedItems = @(Get-CachedGoogleTrashItems $job $config $cache)
                    }
                }
                catch {
                    Write-TrashWorkerProgress '변경 기록을 적용할 수 없어 Google Drive 휴지통을 다시 확인하고 있습니다.' 0 0 -Force
                    $cachedItems = $null
                    $script:GoogleTrashFolders = @{}
                    $script:GoogleTrashRootId = ''
                    $script:GoogleChangeToken = ''
                }
            }
        }
        if ($null -ne $cachedItems) { $items = $cachedItems }
        else {
            if ($destinationType -eq 'GoogleDrive') {
                try {
                    $token = Get-SafeSyncCloudAccessToken 'GoogleDrive' $config
                    $script:GoogleChangeToken = Get-SafeSyncGoogleStartPageToken $token
                }
                catch { $script:GoogleChangeToken = '' }
            }
            $items = switch ($destinationType) {
                'Dropbox' { @(Get-DropboxTrashItems $job $config); break }
                'GoogleDrive' { @(Get-GoogleTrashItems $job $config); break }
                default { @(Get-LocalTrashItems $job); break }
            }
        }
        $sortedItems = @($items | Sort-Object @{Expression='DeletedAt';Descending=$true}, @{Expression='OriginalPath';Ascending=$true})
        Write-TrashWorkerJson (Get-TrashCachePath $job) ([pscustomobject]@{
            Version=1; JobId=[string]$job.Id; DestinationType=$destinationType; Destination=[string]$job.Destination
            CloudFolderId=if ($null -ne $job.PSObject.Properties['CloudFolderId']) { [string]$job.CloudFolderId } else { '' }
            IndexedAtUtc=[datetime]::UtcNow.ToString('o'); Items=$sortedItems
            GoogleChangeToken=$script:GoogleChangeToken; GoogleTrashRootId=$script:GoogleTrashRootId; GoogleFolders=$script:GoogleTrashFolders
        })
        Write-TrashWorkerJson $ResultPath ([pscustomobject]@{ Status='Completed'; Mode='List'; Items=$sortedItems; Error='' })
    }
    else {
        if ([string]::IsNullOrWhiteSpace($RequestPath) -or -not (Test-Path -LiteralPath $RequestPath -PathType Leaf)) { throw '삭제 요청 파일을 찾을 수 없습니다.' }
        $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($request.Items)
        if ($items.Count -eq 0) { throw '삭제할 항목이 없습니다.' }
        $deleteResult = Remove-SelectedTrashItems $job $config $items
        Write-TrashWorkerJson $ResultPath ([pscustomobject]@{ Status='Completed'; Mode='Delete'; Deleted=$deleteResult.Deleted; Errors=@($deleteResult.Errors); Error='' })
    }
}
catch {
    try { Write-TrashWorkerJson $ResultPath ([pscustomobject]@{ Status='Failed'; Mode=$Mode; Items=@(); Deleted=0; Errors=@(); Error=$_.Exception.Message }) } catch {}
    exit 1
}
finally {
    if ($null -ne $script:WorkerLifetimeMutex) { $script:WorkerLifetimeMutex.Dispose() }
}
