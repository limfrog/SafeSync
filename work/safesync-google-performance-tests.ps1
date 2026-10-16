$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:DataRoot = Join-Path (Resolve-Path '.\work').Path 'google-performance-test-data'
. '.\outputs\SafeSync\SafeSync.Cloud.ps1'

$script:Passed = 0
function Assert-Test([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message};$script:Passed++ }

$script:RefreshCount = 0
function Request-SafeSyncGoogleAccessToken([object]$Config) {
    $script:RefreshCount++
    $script:SafeSyncGoogleTokenContext = [pscustomobject]@{Token='renewed-token';ExpiresUtc=[datetime]::UtcNow.AddHours(1);Config=$Config}
    return 'renewed-token'
}
$script:SafeSyncGoogleTokenContext = [pscustomobject]@{Token='expired-token';ExpiresUtc=[datetime]::UtcNow.AddSeconds(-1);Config=[pscustomobject]@{}}
$used = Invoke-SafeSyncGoogleRequest 'expired-token' { param($token) return $token }
Assert-Test ($used -eq 'renewed-token' -and $script:RefreshCount -eq 1) 'An expired Google access token was not refreshed before the request.'

$script:SafeSyncGoogleTokenContext = [pscustomobject]@{Token='rejected-token';ExpiresUtc=[datetime]::UtcNow.AddHours(1);Config=[pscustomobject]@{}}
$script:RefreshCount = 0
$script:AttemptCount = 0
$retried = Invoke-SafeSyncGoogleRequest 'rejected-token' {
    param($token)
    $script:AttemptCount++
    if($script:AttemptCount -eq 1){throw '401 Unauthorized'}
    return $token
}
Assert-Test ($retried -eq 'renewed-token' -and $script:RefreshCount -eq 1 -and $script:AttemptCount -eq 2) 'A Google 401 response was not refreshed and retried exactly once.'

function Invoke-SafeSyncGoogleRequest([string]$Token,[scriptblock]$Request) { return & $Request 'batch-token' }
 $script:ResponseIdStyle = 'wrapped'
 $script:OmitSecond = $false
 $script:BatchAsBytes = $false
 $script:FallbackCalls = 0
function Get-SafeSyncGoogleMetadataOrNull([string]$Token,[string]$FileId) { $script:FallbackCalls++; return $null }
function Invoke-WebRequest {
    param([switch]$UseBasicParsing,$Method,$Uri,$Headers,$ContentType,$Body)
    $boundary='response_batch_test'
    $firstId = switch ($script:ResponseIdStyle) { 'bare' { 'response-item-0' }; 'prefix' { 'response-<item-0>' }; default { '<response-item-0>' } }
    $secondId = switch ($script:ResponseIdStyle) { 'bare' { 'response-item-1' }; 'prefix' { 'response-<item-1>' }; default { '<response-item-1>' } }
    $content=@"
--$boundary
Content-Type: application/http
Content-ID: $firstId

HTTP/1.1 200 OK
Content-Type: application/json

{"id":"remote-a","name":"a.txt","parents":["root"],"size":"12","trashed":false}
--$boundary
Content-Type: application/http
Content-ID: $secondId

HTTP/1.1 404 Not Found
Content-Type: application/json

{"error":{"code":404}}
--$boundary--
"@ -replace '\\r\\n',"`r`n"
    if ($script:OmitSecond) { $content = $content.Substring(0, $content.IndexOf("--$boundary", 3)) + "--$boundary--`r`n" }
    if ($script:BatchAsBytes) { $content = [System.Text.Encoding]::UTF8.GetBytes($content) }
    return [pscustomobject]@{Headers=@{'Content-Type'="multipart/mixed; boundary=$boundary"};Content=$content}
}
$requests=@(
    [pscustomobject]@{Key='a';Relative='a.txt';RemoteId='remote-a';RemoteParentId='root'},
    [pscustomobject]@{Key='b';Relative='b.txt';RemoteId='remote-b';RemoteParentId='root'}
)
$batch=Get-SafeSyncGoogleMetadataBatch token $requests
Assert-Test ($batch.ContainsKey('a') -and [string]$batch['a'].id -eq 'remote-a') 'Google batch metadata did not parse a successful item.'
Assert-Test ($batch.ContainsKey('b') -and $null -eq $batch['b']) 'Google batch metadata did not preserve a missing item as null.'

foreach ($style in @('bare','prefix')) {
    $script:ResponseIdStyle = $style
    $script:BatchAsBytes = $true
    $batch = Get-SafeSyncGoogleMetadataBatch token $requests
    Assert-Test ($batch.Count -eq 2 -and [string]$batch['a'].id -eq 'remote-a') "Google response ID style $style or byte-array content was not parsed."
}
Assert-Test ($script:FallbackCalls -eq 0) 'Valid Google batch formats unexpectedly fell back to individual requests.'
$script:BatchAsBytes = $false
$script:OmitSecond = $true
$batch = Get-SafeSyncGoogleMetadataBatch token $requests
Assert-Test ($script:FallbackCalls -eq 1 -and $batch.ContainsKey('b')) 'Only an unmatched Google batch item must be looked up individually.'

Write-Host "PASS: $script:Passed Google performance assertions"
