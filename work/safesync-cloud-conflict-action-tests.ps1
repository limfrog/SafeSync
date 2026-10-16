$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$script:Passed=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++}

. '.\outputs\SafeSync\SafeSync.Cloud.ps1'

$dropboxPath=Get-SafeSyncDropboxConflictPath '/Backup/folder/report.txt'
Assert-Test ($dropboxPath -match '^/Backup/folder/report\.SafeSync-conflict-\d{8}-\d{9}-[0-9a-f]{6}\.txt$') 'Dropbox conflict-copy path is not a unique sibling name.'

$script:LastGoogleRequest=$null
function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body)
    $script:LastGoogleRequest=[pscustomobject]@{Method=$Method;Uri=$Uri;Body=[System.Text.Encoding]::UTF8.GetString([byte[]]$Body)}
    return [pscustomobject]@{id='file-1';name='renamed.txt';parents=@('parent-1');size='12';modifiedTime='2026-10-03T00:00:00Z';version='7';trashed=$false}
}
$renamed=Rename-SafeSyncGoogleItem token 'file-1' 'report.SafeSync-conflict-20261003.txt'
Assert-Test ($script:LastGoogleRequest.Method -eq 'Patch') 'Google conflict copy does not use a metadata PATCH.'
Assert-Test ($script:LastGoogleRequest.Uri -match '/drive/v3/files/file-1\?fields=') 'Google rename targets the wrong file endpoint.'
Assert-Test ($script:LastGoogleRequest.Body -match 'report\.SafeSync-conflict-20261003\.txt') 'Google rename request does not contain the requested sibling name.'
Assert-Test ($renamed.id -eq 'file-1') 'Google rename response was not returned.'

$source=[System.IO.File]::ReadAllText((Resolve-Path '.\outputs\SafeSync\SafeSync.Cloud.ps1'),[System.Text.Encoding]::UTF8)
Assert-Test ($source.Contains('RenameExistingPaths')) 'Cloud backup entry points do not accept rename-and-copy plans.'
Assert-Test ($source.Contains('Move-SafeSyncDropboxItem $token ([string]$current.id) $renamedPath $false')) 'Dropbox conflict action does not preserve the current object under a new name.'
Assert-Test ($source.Contains('Rename-SafeSyncGoogleItem $token ([string]$item.id) $renamedName')) 'Google conflict action does not preserve the current object under a new name.'
Assert-Test ($source.Contains("fields='id,name,parents,size,modifiedTime,createdTime")) 'Incremental Google metadata lacks the timestamp required for comparison.'

Write-Host "PASS: $script:Passed cloud conflict-action assertions"
