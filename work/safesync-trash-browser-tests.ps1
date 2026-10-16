$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }

$script:TestRoot = Join-Path (Resolve-Path '.\work').Path ('trash-browser-test-' + [guid]::NewGuid().ToString('N'))
$script:DataRoot = Join-Path $script:TestRoot 'data'
$script:LogRoot = Join-Path $script:DataRoot 'logs'
$script:ManifestRoot = Join-Path $script:DataRoot 'manifests'
$script:ResultRoot = Join-Path $script:DataRoot 'results'
$script:ProgressRoot = Join-Path $script:DataRoot 'progress'
$script:ChangedPaths = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
$script:PendingChanges = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()
[void][System.IO.Directory]::CreateDirectory($script:TestRoot)
. '.\outputs\SafeSync\SafeSync.Integrity.ps1'

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path, [ref]$tokens, [ref]$parseErrors)
Assert-Test ($parseErrors.Count -eq 0) 'SafeSync.ps1 does not parse.'
$functions = @('Get-NormalizedPath','ConvertTo-SafeSyncRelativePath','Format-ProgressFileSize','Copy-FileSafely','Get-SafeSyncTrashDeletedAt','Get-SafeSyncLocalTrashItems','Get-SafeSyncTrashItems','Remove-SafeSyncEmptyTrashParents','Update-SafeSyncStateAfterTrashRestore','Restore-SafeSyncLocalTrashItems','Restore-SafeSyncTrashItems')
foreach ($node in $ast.FindAll({ param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $functions) { Invoke-Expression $node.Extent.Text }
}
function Add-SafeSyncChangedPath([string]$JobId,[string]$Side,[string]$RelativePath) {
    $script:ChangedPaths["$JobId|$Side|$RelativePath"] = Get-Date
    $script:PendingChanges[$JobId] = Get-Date
}
function Get-SafeSyncState([string]$JobId) { return [pscustomobject]@{ JobId=$JobId; PendingPaths=@(); Entries=@{}; Exists=$true; LastFullScanUtc=''; LastRunUtc=''; FullScanRequired=$false } }
function Set-SafeSyncStateEntry {
    param([object]$State,[string]$RelativePath,[System.IO.FileInfo]$File,[string]$Status,[string]$ErrorMessage='',[string]$RemoteId='',[string]$RemoteParentId='')
    $State.Entries[$RelativePath.ToLowerInvariant()] = [pscustomobject]@{RelativePath=$RelativePath;Status=$Status;RemoteId=$RemoteId;RemoteParentId=$RemoteParentId}
}
function Save-SafeSyncState([object]$State) { $script:SavedState = $State }

function Write-Fixture([string]$Path,[string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path,$Text)
}

$source = Join-Path $script:TestRoot 'source'
$destination = Join-Path $script:TestRoot 'destination'
[void][System.IO.Directory]::CreateDirectory($source)
[void][System.IO.Directory]::CreateDirectory($destination)
$job = [pscustomobject]@{ Id='trash-browser'; Name='Trash browser test'; Source=$source; Destination=$destination; DestinationType='Local' }
$trashRoot = Join-Path $destination '.safesync-trash'
$firstTrash = Join-Path $trashRoot '20261002-153045123-deleted\folder\a.txt'
$secondTrash = Join-Path $trashRoot '20261001-101112456-replaced-abcdef\b.txt'
Write-Fixture $firstTrash 'restored alpha'
Write-Fixture $secondTrash 'restored bravo'
Write-Fixture (Join-Path $destination 'folder\a.txt') 'current alpha'

try {
    $items = @(Get-SafeSyncTrashItems $job)
    Assert-Test ($items.Count -eq 2) 'The flat trash browser did not list every trashed file.'
    Assert-Test (@($items | Where-Object Name -eq 'a.txt').Count -eq 1 -and @($items | Where-Object Name -eq 'b.txt').Count -eq 1) 'File names were not flattened correctly.'
    $aItem = @($items | Where-Object Name -eq 'a.txt')[0]
    Assert-Test ([string]$aItem.DeletedAtText -eq '2026-10-02 15:30:45') 'The deletion timestamp was not parsed from the trash bundle.'
    Assert-Test ([string]$aItem.OriginalPath -eq (Join-Path $destination 'folder\a.txt')) 'The pre-trash path is incorrect.'

    $result = Restore-SafeSyncTrashItems $job $items
    Assert-Test ($result.Restored -eq 2 -and @($result.Errors).Count -eq 0) 'Multi-file restore did not complete.'
    Assert-Test ([System.IO.File]::ReadAllText((Join-Path $destination 'folder\a.txt')) -eq 'restored alpha') 'The first selected file was not restored.'
    Assert-Test ([System.IO.File]::ReadAllText((Join-Path $destination 'b.txt')) -eq 'restored bravo') 'The second selected file was not restored.'
    Assert-Test (-not (Test-Path -LiteralPath $firstTrash) -and -not (Test-Path -LiteralPath $secondTrash)) 'Restored copies remained in their old trash locations.'
    Assert-Test ($script:ChangedPaths.ContainsKey('trash-browser|D|folder/a.txt') -and $script:ChangedPaths.ContainsKey('trash-browser|D|b.txt')) 'Restored paths were not queued for snapshot reconciliation.'
    Assert-Test ($script:SavedState.Entries['folder/a.txt'].Status -eq 'Conflict' -and @($script:SavedState.PendingPaths).Count -eq 2) 'Restored files were not marked for review in the snapshot.'
    $preserved = @(Get-ChildItem -LiteralPath $trashRoot -File -Recurse -Force | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -eq 'current alpha' })
    Assert-Test ($preserved.Count -eq 1) 'The file replaced during restore was not preserved in SafeSync trash.'

    $olderA = Join-Path $trashRoot '20260930-010203000-deleted\folder\a.txt'
    $newerA = Join-Path $trashRoot '20261001-010203000-deleted\folder\a.txt'
    Write-Fixture $olderA 'older alpha'
    Write-Fixture $newerA 'newer alpha'
    $duplicateItems = @(Get-SafeSyncTrashItems $job | Where-Object RelativePath -eq 'folder/a.txt')
    $duplicateRejected = $false
    try { [void](Restore-SafeSyncTrashItems $job $duplicateItems) } catch { $duplicateRejected = $true }
    Assert-Test $duplicateRejected 'Two versions for the same original path were restored ambiguously.'
}
finally {
    if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "PASS: $script:Passed trash-browser assertions"
