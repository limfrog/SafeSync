$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$framework = Split-Path -Parent $compiler
$references = @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Management.dll') | ForEach-Object { '/reference:' + (Join-Path $framework $_) }
$testExe = Join-Path $PSScriptRoot ('PackageTests-' + [guid]::NewGuid().ToString('N') + '.exe')
$sources = @('InstallerCore.cs','InstallerUI.cs','Launcher.cs','PackageTests.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
& $compiler '/nologo' '/optimize+' '/target:exe' '/platform:anycpu' '/codepage:65001' '/main:PackageTests' ('/out:' + $testExe) $references $sources
if ($LASTEXITCODE -ne 0) { throw 'Packaging test compilation failed.' }
$sandbox = Join-Path (Join-Path $taskRoot 'work') ('package-test-' + [guid]::NewGuid().ToString('N'))
& $testExe $PSScriptRoot $sandbox
if ($LASTEXITCODE -ne 0) { throw 'Packaging tests failed.' }
$verify = Start-Process -FilePath (Join-Path $taskRoot 'outputs\SafeSync-Setup.exe') -ArgumentList '/verify' -PassThru -WindowStyle Hidden
if (-not $verify.WaitForExit(30000)) { $verify.Kill(); throw 'Embedded payload verification timed out.' }
if ($verify.ExitCode -ne 0) { throw 'Embedded setup payload verification failed.' }
[pscustomobject]@{EmbeddedPayload='OK';SetupSHA256=(Get-FileHash -LiteralPath (Join-Path $taskRoot 'outputs\SafeSync-Setup.exe')).Hash}
