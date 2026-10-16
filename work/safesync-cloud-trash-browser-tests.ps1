$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }

$script:TestRoot = Join-Path (Resolve-Path '.\work').Path ('cloud-trash-test-' + [guid]::NewGuid().ToString('N'))
$script:DataRoot = Join-Path $script:TestRoot 'data'
$script:ManifestRoot = Join-Path $script:DataRoot 'manifests'
$script:ChangedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:PendingChanges = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:Config = [pscustomobject]@{}
[void][System.IO.Directory]::CreateDirectory($script:ManifestRoot)

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path, [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'SafeSync.ps1 does not parse.'
$functions = @('ConvertTo-SafeSyncRelativePath','Format-ProgressFileSize','Get-SafeSyncTrashDeletedAt','Get-SafeSyncDropboxTrashItems','Get-SafeSyncGoogleTrashItems','Get-SafeSyncTrashItems','Update-SafeSyncStateAfterTrashRestore','Restore-SafeSyncDropboxTrashItems','Restore-SafeSyncGoogleTrashItems','Restore-SafeSyncTrashItems')
foreach ($node in $ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $functions) { Invoke-Expression $node.Extent.Text }
}

function Get-NormalizedPath([string]$Path) { return [System.IO.Path]::GetFullPath($Path) }
function Get-SafeSyncCloudAccessToken([string]$Provider,[object]$Config) { return "token-$Provider" }
function Join-SafeSyncDropboxPath([string]$Root,[string]$Relative) { return (($Root.TrimEnd('/') + '/' + $Relative.Replace('\','/').TrimStart('/')).TrimEnd('/')) }
function Add-SafeSyncChangedPath([string]$JobId,[string]$Side,[string]$RelativePath) { $script:ChangedPaths["$JobId|$Side|$RelativePath"] = Get-Date }
function Get-SafeSyncState([string]$JobId) { return [pscustomobject]@{JobId=$JobId;PendingPaths=@();Entries=@{};Exists=$true;LastFullScanUtc='';LastRunUtc='';FullScanRequired=$false} }
function Set-SafeSyncStateEntry {
    param([object]$State,[string]$RelativePath,[System.IO.FileInfo]$File,[string]$Status,[string]$ErrorMessage='',[string]$RemoteId='',[string]$RemoteParentId='')
    $State.Entries[$RelativePath.ToLowerInvariant()] = [pscustomobject]@{RelativePath=$RelativePath;Status=$Status;RemoteId=$RemoteId;RemoteParentId=$RemoteParentId}
}
function Save-SafeSyncState([object]$State) { $script:SavedStates[[string]$State.JobId] = $State }
$script:SavedStates = @{}

$script:DropboxFiles = @{}
function Add-DropboxFile([string]$Path,[string]$Id,[long]$Size) {
    $script:DropboxFiles[$Path.ToLowerInvariant()] = [pscustomobject]@{'.tag'='file';id=$Id;path_display=$Path;size=$Size;server_modified='2026-10-02T06:30:45Z'}
}
function Get-SafeSyncDropboxEntries([string]$Token,[string]$Root,[bool]$Recursive=$true) { return @($script:DropboxFiles.Values | Where-Object { $_.path_display.StartsWith($Root + '/', [StringComparison]::OrdinalIgnoreCase) }) }
function Get-SafeSyncDropboxMetadata([string]$Token,[string]$Path) { $key=$Path.ToLowerInvariant(); if($script:DropboxFiles.ContainsKey($key)){return $script:DropboxFiles[$key]}; return $null }
function Move-SafeSyncDropboxItem([string]$Token,[string]$FromPath,[string]$ToPath,[bool]$AutoRename=$true) {
    $fromKey=$FromPath.ToLowerInvariant();$toKey=$ToPath.ToLowerInvariant()
    if(-not $script:DropboxFiles.ContainsKey($fromKey)){throw "Dropbox source missing: $FromPath"}
    if($script:DropboxFiles.ContainsKey($toKey)){throw "Dropbox target exists: $ToPath"}
    $entry=$script:DropboxFiles[$fromKey];$script:DropboxFiles.Remove($fromKey);$entry.path_display=$ToPath;$script:DropboxFiles[$toKey]=$entry
}

$script:GoogleParents = @{'trash-a'='old-a-parent';'trash-b'='old-b-parent';'current-a'='docs-parent'}
$script:GooglePreserveParents = @{}
function Get-SafeSyncGoogleChildren([string]$Token,[string]$ParentId) {
    if($ParentId -eq 'google-root'){return @([pscustomobject]@{id='trash-root';name='.safesync-trash';mimeType='application/vnd.google-apps.folder'})}
    return @()
}
function Get-SafeSyncGoogleTree([string]$Token,[string]$RootId) {
    if($RootId -eq 'trash-root'){
        return [pscustomobject]@{Files=@{
            '20261002-153045123-deleted/docs/a.txt'=[pscustomobject]@{Relative='20261002-153045123-deleted/docs/a.txt';ParentId='old-a-parent';Item=[pscustomobject]@{id='trash-a';name='a.txt';size='11';modifiedTime='2026-10-02T06:30:45Z'}}
            '20261001-101112456-deleted/b.txt'=[pscustomobject]@{Relative='20261001-101112456-deleted/b.txt';ParentId='old-b-parent';Item=[pscustomobject]@{id='trash-b';name='b.txt';size='12';modifiedTime='2026-10-01T01:11:12Z'}}
        };Folders=@{'_'='trash-root'}}
    }
    return [pscustomobject]@{Files=@{'docs/a.txt'=[pscustomobject]@{Relative='docs/a.txt';ParentId='docs-parent';Item=[pscustomobject]@{id='current-a';name='a.txt'}}};Folders=@{'_'='google-root';'docs'='docs-parent'}}
}
function Ensure-SafeSyncGoogleFolderPath([string]$Token,[string]$RootId,[string]$RelativePath,[hashtable]$FolderMap) {
    if([string]::IsNullOrWhiteSpace($RelativePath)){return $RootId}
    $key=$RelativePath.ToLowerInvariant();if($FolderMap.ContainsKey($key)){return [string]$FolderMap[$key]}
    $id='folder-' + [guid]::NewGuid().ToString('N');$FolderMap[$key]=$id;$script:GooglePreserveParents[$key]=$id;return $id
}
function Move-SafeSyncGoogleItem([string]$Token,[string]$FileId,[string]$OldParentId,[string]$NewParentId) {
    if(-not $script:GoogleParents.ContainsKey($FileId) -or $script:GoogleParents[$FileId] -ne $OldParentId){throw "Google source parent mismatch: $FileId"}
    $script:GoogleParents[$FileId]=$NewParentId
}

$source = Join-Path $script:TestRoot 'source'
[void][System.IO.Directory]::CreateDirectory($source)
$dropboxJob = [pscustomobject]@{Id='dropbox-trash';Name='Dropbox';Source=$source;Destination='Dropbox / Backup';DestinationType='Dropbox';CloudFolderId='/backup'}
$googleJob = [pscustomobject]@{Id='google-trash';Name='Google';Source=$source;Destination='Google Drive / Backup';DestinationType='GoogleDrive';CloudFolderId='google-root'}
Add-DropboxFile '/backup/.safesync-trash/20261002-153045123-deleted/docs/a.txt' 'trash-a' 11
Add-DropboxFile '/backup/.safesync-trash/20261001-101112456-deleted/b.txt' 'trash-b' 12
Add-DropboxFile '/backup/docs/a.txt' 'current-a' 20

try {
    $dropboxItems = @(Get-SafeSyncTrashItems $dropboxJob)
    Assert-Test ($dropboxItems.Count -eq 2) 'Dropbox trash was not flattened.'
    Assert-Test ($dropboxItems[0].Provider -eq 'Dropbox' -and @($dropboxItems | Where-Object RelativePath -eq 'docs/a.txt').Count -eq 1) 'Dropbox item metadata is incorrect.'
    $dropboxResult = Restore-SafeSyncTrashItems $dropboxJob $dropboxItems
    Assert-Test ($dropboxResult.Restored -eq 2 -and @($dropboxResult.Errors).Count -eq 0) 'Dropbox multi-file restore failed.'
    Assert-Test ((Get-SafeSyncDropboxMetadata x '/backup/docs/a.txt').id -eq 'trash-a' -and (Get-SafeSyncDropboxMetadata x '/backup/b.txt').id -eq 'trash-b') 'Dropbox files did not return to their original backup paths.'
    Assert-Test (@($script:DropboxFiles.Values | Where-Object id -eq 'current-a' | Where-Object path_display -match 'restore-replaced').Count -eq 1) 'Dropbox existing target was not preserved.'
    Assert-Test ($script:SavedStates['dropbox-trash'].Entries['docs/a.txt'].Status -eq 'Conflict') 'Dropbox restore was not marked for snapshot review.'

    $googleItems = @(Get-SafeSyncTrashItems $googleJob)
    Assert-Test ($googleItems.Count -eq 2) 'Google Drive trash was not flattened.'
    Assert-Test (@($googleItems | Where-Object { $_.RemoteId -eq 'trash-a' -and $_.RelativePath -eq 'docs/a.txt' }).Count -eq 1) 'Google Drive item metadata is incorrect.'
    $googleResult = Restore-SafeSyncTrashItems $googleJob $googleItems
    Assert-Test ($googleResult.Restored -eq 2 -and @($googleResult.Errors).Count -eq 0) 'Google Drive multi-file restore failed.'
    Assert-Test ($script:GoogleParents['trash-a'] -eq 'docs-parent' -and $script:GoogleParents['trash-b'] -eq 'google-root') 'Google Drive files did not return to their original backup folders.'
    Assert-Test ($script:GoogleParents['current-a'] -ne 'docs-parent') 'Google Drive existing target was not preserved.'
    Assert-Test ($script:SavedStates['google-trash'].Entries['docs/a.txt'].RemoteParentId -eq 'docs-parent') 'Google Drive snapshot was not updated with the restored parent.'
}
finally {
    if(Test-Path -LiteralPath $script:TestRoot){Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue}
}

Write-Host "PASS: $script:Passed cloud trash-browser assertions"
