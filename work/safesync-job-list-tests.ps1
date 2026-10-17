$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$sourcePath = (Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
foreach ($name in @('New-SafeSyncJobListDocument','Save-SafeSyncJobListDocument','Read-SafeSyncJobListDocument','Get-NormalizedPath','Test-PathRelationship')) {
    $node = @($ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $true))[0]
    if ($null -eq $node) { throw "Missing function: $name" }
    Invoke-Expression $node.Extent.Text
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SafeSync-job-list-test-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
try {
    $path = Join-Path $testRoot 'jobs.safesync-jobs.json'
    $koreanName = ([string][char]0xD55C) + ([string][char]0xAE00) + ' job'
    $job = [pscustomobject]@{
        Id=[guid]::NewGuid().ToString(); Name=$koreanName; Source='C:\source'; DestinationType='Local'
        Destination='D:\backup'; CloudFolderId=''; TriggerType='Scheduled'; ScheduleTime='23:10'
        MirrorDeletes=$true; Paused=$true; LastScheduledRun='2026-10-16'; RefreshTokenProtected='must-not-export'
    }
    Save-SafeSyncJobListDocument @($job) $path
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($raw.Contains('must-not-export') -or $raw.Contains('LastScheduledRun')) { throw 'Export included private or transient fields.' }
    $restored = @(Read-SafeSyncJobListDocument $path)
    if ($restored.Count -ne 1 -or $restored[0].Name -ne $koreanName -or -not $restored[0].Paused -or $restored[0].LastScheduledRun -ne '') { throw 'Round-trip failed.' }

    Save-SafeSyncJobListDocument @() $path
    if (@(Read-SafeSyncJobListDocument $path).Count -ne 0) { throw 'Empty job list failed.' }

    Save-SafeSyncJobListDocument @($job,$job) $path
    $rejected = $false
    try { [void]@(Read-SafeSyncJobListDocument $path) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Duplicate job IDs were accepted.' }

    '{"Format":"SafeSyncJobList","Version":1,"Jobs":"bad"}' | Set-Content -LiteralPath $path -Encoding UTF8
    $rejected = $false
    try { [void]@(Read-SafeSyncJobListDocument $path) } catch { $rejected = $true }
    if (-not $rejected) { throw 'Malformed job list was accepted.' }

    $text = [System.IO.File]::ReadAllText($sourcePath, [System.Text.Encoding]::UTF8)
    if (-not $text.Contains('MenuExportJobsItem') -or -not $text.Contains('MenuImportJobsItem')) { throw 'Import/export menu is missing.' }
    'SafeSync job-list tests OK'
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
