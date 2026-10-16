$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$script:Passed=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++}

. '.\outputs\SafeSync\SafeSync.Cloud.ps1'

function Invoke-SafeSyncDropboxRpc([string]$Token,[string]$Endpoint,[object]$Body){
    if($Endpoint -eq 'files/list_folder/get_latest_cursor'){return [pscustomobject]@{cursor='db-latest'}}
    if($Endpoint -ne 'files/list_folder/continue'){throw "unexpected Dropbox endpoint: $Endpoint"}
    if([string]$Body.cursor -eq 'db-start'){
        return [pscustomobject]@{entries=@([pscustomobject]@{'.tag'='file';id='id-a';path_display='/Backup/a.txt'});has_more=$true;cursor='db-next'}
    }
    return [pscustomobject]@{entries=@([pscustomobject]@{'.tag'='deleted';path_display='/Backup/b.txt'});has_more=$false;cursor='db-finish'}
}

function Invoke-RestMethod {
    param($Method,$Uri,$Headers,$ContentType,$Body)
    if($Uri -match '/changes/startPageToken\?'){return [pscustomobject]@{startPageToken='g-start'}}
    if($Uri -match 'pageToken=g-start'){
        return [pscustomobject]@{changes=@([pscustomobject]@{fileId='gid-a';removed=$false;file=[pscustomobject]@{id='gid-a';name='a.txt';parents=@('root');trashed=$false}});nextPageToken='g-next'}
    }
    if($Uri -match 'pageToken=g-next'){
        return [pscustomobject]@{changes=@([pscustomobject]@{fileId='gid-b';removed=$true});newStartPageToken='g-finish'}
    }
    throw "unexpected Google URI: $Uri"
}

$latest=Get-SafeSyncDropboxLatestCursor token '/Backup'
Assert-Test ($latest -eq 'db-latest') 'Dropbox latest cursor was not read.'
$dropbox=Get-SafeSyncDropboxChanges token 'db-start'
Assert-Test (@($dropbox.Entries).Count -eq 2) 'Dropbox change-feed pagination lost entries.'
Assert-Test ($dropbox.Cursor -eq 'db-finish') 'Dropbox final cursor was not preserved.'
Assert-Test ([string]$dropbox.Entries[1].PSObject.Properties['.tag'].Value -eq 'deleted') 'Dropbox deletions were not preserved in the feed.'

$start=Get-SafeSyncGoogleStartPageToken token
Assert-Test ($start -eq 'g-start') 'Google Drive start page token was not read.'
$google=Get-SafeSyncGoogleChanges token $start
Assert-Test (@($google.Changes).Count -eq 2) 'Google Drive change-feed pagination lost entries.'
Assert-Test ($google.Token -eq 'g-finish') 'Google Drive new start page token was not preserved.'
Assert-Test ([bool]$google.Changes[1].removed) 'Google Drive removal records were not preserved.'

Write-Host "PASS: $script:Passed cloud change-feed assertions"
