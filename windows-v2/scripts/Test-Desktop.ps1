[CmdletBinding()]
param([string]$AppPath='', [switch]$Bundled)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if([string]::IsNullOrWhiteSpace($AppPath)){$AppPath=Join-Path $root 'src/SafeSync.App/bin/Release/net10.0-windows/SafeSync.exe'}
$executable=(Resolve-Path -LiteralPath $AppPath).Path
if(-not $executable.StartsWith([IO.Path]::GetFullPath($root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Test executable must be inside windows-v2.'}
$fixture=Join-Path $root ('artifacts/ui-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$arguments=@('--smoke-test','--data-root',('"'+$fixture+'"'),'--preview-dir',('"'+(Join-Path $fixture 'previews')+'"'))
$process=Start-Process -FilePath $executable -ArgumentList $arguments -PassThru -WindowStyle Hidden
if(-not $process.WaitForExit(60000)){$process.Kill();throw 'Native UI smoke test timed out.'}
$process.Refresh()
$result=Get-Content -LiteralPath (Join-Path $fixture 'smoke-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($process.ExitCode -ne 0 -or $result.Status -ne 'OK' -or $result.PowerShellLoaded -or $result.Assertions -lt 312){$result | ConvertTo-Json -Depth 5;throw 'Native UI smoke test failed.'}
if($Bundled){
    $runtime=Join-Path (Split-Path $executable -Parent) 'runtime'
    foreach($location in @($result.RuntimeLocation,$result.DesktopRuntimeLocation)){
        if(-not $location.StartsWith($runtime+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'The app did not use its bundled runtime.'}
    }
}
[pscustomobject]@{Status='OK';Assertions=$result.Assertions;PowerShellLoaded=$result.PowerShellLoaded;BundledRuntime=[bool]$Bundled;ProcessExited=$process.HasExited;ResultFolder=$fixture} | ConvertTo-Json
