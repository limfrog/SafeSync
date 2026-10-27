[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'native-vss/VssMain.cpp'
$output=Join-Path $root 'native-vss/bin'
[void][IO.Directory]::CreateDirectory($output)
$locator=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if(-not (Test-Path -LiteralPath $locator)){throw 'VSS helper build requires Visual Studio C++ build tools.'}
$studio=(& $locator -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if(-not $studio){throw 'MSVC x64 C++ compiler is missing.'}
$environment=Join-Path $studio 'VC/Auxiliary/Build/vcvars64.bat'
$batch=Join-Path $output 'compile.cmd'
$commands=@('@echo off',('call "'+$environment+'" >nul'),'if errorlevel 1 exit /b %errorlevel%',('cl.exe /nologo /O2 /MT /EHsc /std:c++17 /W3 /D_WIN32_WINNT=0x0A00 "'+$source+'" /Fo"'+(Join-Path $output 'VssMain.obj')+'" /Fe"'+(Join-Path $output 'SafeSync.Vss.exe')+'" /link vssapi.lib ole32.lib oleaut32.lib advapi32.lib /DEPENDENTLOADFLAG:0x800 /MANIFESTUAC:NO'),'exit /b %errorlevel%')
[IO.File]::WriteAllLines($batch,$commands,[Text.Encoding]::ASCII)
& $env:ComSpec /d /c $batch
if($LASTEXITCODE -ne 0){throw 'Native VSS helper compilation failed.'}
Get-FileHash -LiteralPath (Join-Path $output 'SafeSync.Vss.exe') -Algorithm SHA256
