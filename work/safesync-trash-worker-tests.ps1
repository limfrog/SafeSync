$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }

$root = Join-Path (Resolve-Path '.\work').Path ('trash-worker-test-' + [guid]::NewGuid().ToString('N'))
$data = Join-Path $root 'data'
$destination = Join-Path $root 'destination'
$trashRoot = Join-Path $destination '.safesync-trash'
$first = Join-Path $trashRoot '20261003-010203000-deleted\folder\first.txt'
$second = Join-Path $trashRoot '20261002-010203000-deleted\second.txt'
$outside = Join-Path $root 'must-not-delete.txt'
$worker = (Resolve-Path '.\outputs\SafeSync\SafeSync.TrashWorker.ps1').Path

function Write-Fixture([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Text)
}

function Invoke-Worker([string]$Mode, [string]$Result, [string]$Progress, [string]$Request = '') {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$worker,'-Mode',$Mode,'-JobId','trash-worker','-DataRoot',$data,'-ResultPath',$Result,'-ProgressPath',$Progress)
    if (-not [string]::IsNullOrWhiteSpace($Request)) { $arguments += @('-RequestPath',$Request) }
    & powershell.exe @arguments
    return $LASTEXITCODE
}

try {
    Write-Fixture $first 'first'
    Write-Fixture $second 'second'
    Write-Fixture $outside 'keep'
    [void][System.IO.Directory]::CreateDirectory($data)
    [pscustomobject]@{
        Jobs=@([pscustomobject]@{Id='trash-worker';Name='Trash worker';Source=(Join-Path $root 'source');Destination=$destination;DestinationType='Local'})
        CloudAccounts=[pscustomobject]@{Dropbox=[pscustomobject]@{};GoogleDrive=[pscustomobject]@{}}
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $data 'config.json') -Encoding UTF8

    $resultPath = Join-Path $data 'list-result.json'
    $progressPath = Join-Path $data 'list-progress.json'
    Assert-Test ((Invoke-Worker 'List' $resultPath $progressPath) -eq 0) 'The list worker failed.'
    $list = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test ([string]$list.Status -eq 'Completed' -and @($list.Items).Count -eq 2) 'The background list did not return every local trash item.'
    Assert-Test (Test-Path -LiteralPath $progressPath -PathType Leaf) 'The worker did not publish responsive progress.'

    $requestPath = Join-Path $data 'delete-request.json'
    [pscustomobject]@{Items=@(@($list.Items | Where-Object Name -eq 'first.txt')[0])} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $deleteResultPath = Join-Path $data 'delete-result.json'
    Assert-Test ((Invoke-Worker 'Delete' $deleteResultPath (Join-Path $data 'delete-progress.json') $requestPath) -eq 0) 'The delete worker failed.'
    $deleted = Get-Content -LiteralPath $deleteResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test ([int]$deleted.Deleted -eq 1 -and @($deleted.Errors).Count -eq 0) 'The selected file was not permanently deleted.'
    Assert-Test (-not (Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath $second)) 'Permanent deletion affected the wrong trash file.'

    $unsafeRequest = Join-Path $data 'unsafe-request.json'
    [pscustomobject]@{Items=@([pscustomobject]@{Name='must-not-delete.txt';TrashPath=$outside;TrashRoot=$trashRoot;RelativePath='must-not-delete.txt'})} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $unsafeRequest -Encoding UTF8
    $unsafeResult = Join-Path $data 'unsafe-result.json'
    Assert-Test ((Invoke-Worker 'Delete' $unsafeResult (Join-Path $data 'unsafe-progress.json') $unsafeRequest) -eq 0) 'A rejected item should not crash the delete worker.'
    $unsafe = Get-Content -LiteralPath $unsafeResult -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Test ([int]$unsafe.Deleted -eq 0 -and @($unsafe.Errors).Count -eq 1 -and (Test-Path -LiteralPath $outside)) 'Path validation allowed deletion outside SafeSync trash.'

    $mainSource = Get-Content -LiteralPath '.\outputs\SafeSync\SafeSync.ps1' -Raw -Encoding UTF8
    Assert-Test ($mainSource.Contains('x:Name="DeleteButton" Content="선택 파일 완전 삭제"')) 'The permanent-delete button is missing.'
    Assert-Test ($mainSource.Contains("Start-Process -FilePath `$powershellPath") -and $mainSource.Contains('IsIndeterminate="True"')) 'Trash loading is not visibly asynchronous.'
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "PASS: $script:Passed trash-worker assertions"
