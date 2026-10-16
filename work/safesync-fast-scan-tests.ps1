$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$script:Passed=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++}

. '.\outputs\SafeSync\SafeSync.Integrity.ps1'
Assert-Test ($null -ne ('SafeSyncFastScanner' -as [type])) 'The compiled scan engine was not loaded.'

$root=Join-Path (Resolve-Path '.\work').Path ('fast-scan-test-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try{
    for($d=0;$d -lt 40;$d++){
        $folder=Join-Path $root ('folder-{0:D3}' -f $d);[void][IO.Directory]::CreateDirectory($folder)
        for($f=0;$f -lt 25;$f++){[IO.File]::WriteAllText((Join-Path $folder ('file-{0:D3}.txt' -f $f)),'x')}
    }
    $internal=Join-Path $root '.safesync-trash\old';[void][IO.Directory]::CreateDirectory($internal);[IO.File]::WriteAllText((Join-Path $internal 'hidden.txt'),'hidden')
    [IO.File]::WriteAllText((Join-Path $root 'orphan.safesync-part-123'),'partial')
    $folders=New-Object System.Collections.Generic.List[string]
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $items=[SafeSyncFastScanner]::EnumerateFiles($root,[Action[string]]{param($path)$folders.Add($path)})
    $watch.Stop()
    Assert-Test ($items.Count -eq 1000) 'The scan engine returned an incorrect file count.'
    Assert-Test (@($items|Where-Object{$_.FullName -match '\.safesync-'}).Count -eq 0) 'The scan engine included SafeSync internal files.'
    Assert-Test ($folders.Count -eq 41) 'The scan engine did not report every normal folder.'
    Assert-Test (@($items|Where-Object{$_.Name -eq 'file-000.txt'}).Count -eq 40) 'The scan engine lost files with duplicate names in different folders.'
    Assert-Test ($watch.ElapsedMilliseconds -lt 10000) 'The compiled scan engine took unexpectedly long on a small local tree.'
    Write-Host "PASS: $script:Passed fast-scan assertions in $($watch.ElapsedMilliseconds) ms"
}
finally{if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
