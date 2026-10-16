$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }
$script:DataRoot = (Resolve-Path '.\work').Path
$script:PartialItems = New-Object System.Collections.Generic.List[object]
$script:PartialRoot = ''
$script:GoogleTrashFolders = @{}
$script:GoogleTrashRootId = ''
$script:GoogleChangeToken = ''

$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.TrashWorker.ps1').Path,[ref]$tokens,[ref]$errors)
Assert-Test ($errors.Count -eq 0) 'Trash worker does not parse.'
$needed=@('ConvertTo-SafeSyncRelativePath','Format-ProgressFileSize','Get-SafeSyncTrashDeletedAt','New-TrashItem','Get-GoogleTrashFolder','Get-GoogleTrashItems','Get-CachedGoogleTrashItems')
foreach($node in $ast.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)){
    if($node.Name -in $needed){Invoke-Expression $node.Extent.Text}
}
function Get-SafeSyncCloudAccessToken([string]$Provider,[object]$Config){return 'test-token'}
function Write-TrashWorkerProgress { param([string]$Text,[int]$Folders=0,[int]$Files=0,[switch]$Force) }
function Publish-TrashWorkerPartial { param([object[]]$NewItems=@(),[switch]$Force) }
function Get-TrashGoogleChildren([string]$Token,[string]$ParentId,[string]$Name=''){
    switch($ParentId){
        'destination' {return [pscustomobject]@{id='trash-root';name='.safesync-trash';mimeType='application/vnd.google-apps.folder'}}
        'trash-root' {return [pscustomobject]@{id='bundle';name='20261003-010203000-deleted';mimeType='application/vnd.google-apps.folder'}}
        'bundle' {return [pscustomobject]@{id='folder';name='folder';mimeType='application/vnd.google-apps.folder'}}
        'folder' {return [pscustomobject]@{id='old-file';name='old.txt';mimeType='application/octet-stream';size='3';modifiedTime='2026-10-03T01:02:03Z'}}
    }
}
$script:Changes=@()
function Get-SafeSyncGoogleChanges([string]$Token,[string]$PageToken){return [pscustomobject]@{Changes=$script:Changes;Token='next-token'}}
$job=[pscustomobject]@{Id='google-cache';Destination='Google Drive Backup';CloudFolderId='destination';DestinationType='GoogleDrive'}
$config=[pscustomobject]@{}

$full=@(Get-GoogleTrashItems $job $config)
Assert-Test ($full.Count -eq 1 -and $full[0].RemoteId -eq 'old-file') 'Initial Google trash traversal missed a file.'
Assert-Test ($script:GoogleTrashRootId -eq 'trash-root' -and $script:GoogleTrashFolders['folder'] -eq '20261003-010203000-deleted/folder') 'Initial traversal did not retain folder ancestry.'
$cache=[pscustomobject]@{
    GoogleChangeToken='previous-token';GoogleTrashRootId='trash-root';IndexedAtUtc='2026-10-03T00:00:00Z'
    GoogleFolders=[pscustomobject]@{'trash-root'='';bundle='20261003-010203000-deleted';folder='20261003-010203000-deleted/folder'}
    Items=@($full)
}
$script:Changes=@(
    [pscustomobject]@{fileId='old-file';removed=$true;file=$null},
    [pscustomobject]@{fileId='new-file';removed=$false;file=[pscustomobject]@{id='new-file';name='new.txt';mimeType='application/octet-stream';parents=@('folder');size='4';modifiedTime='2026-10-03T01:05:00Z';trashed=$false}},
    [pscustomobject]@{fileId='unrelated';removed=$false;file=[pscustomobject]@{id='unrelated';name='elsewhere.txt';mimeType='application/octet-stream';parents=@('outside');size='5';trashed=$false}}
)
$updated=@(Get-CachedGoogleTrashItems $job $config $cache)
Assert-Test ($updated.Count -eq 1 -and $updated[0].RemoteId -eq 'new-file' -and $updated[0].RelativePath -eq 'folder/new.txt') 'Change feed did not add/remove the correct trash files.'
Assert-Test ($script:GoogleChangeToken -eq 'next-token') 'Change feed token was not advanced.'

$script:Changes=@([pscustomobject]@{fileId='folder';removed=$true;file=$null})
$fallback=$false
try { [void](Get-CachedGoogleTrashItems $job $config $cache) } catch { $fallback=$true }
Assert-Test $fallback 'A removed trash folder did not force a safe full rebuild.'
Write-Host "PASS: $script:Passed Google trash-cache assertions"
