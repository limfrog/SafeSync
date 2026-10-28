[CmdletBinding()]
param([string]$PublishPath='', [switch]$RunTests)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$version=[string]([xml](Get-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Raw)).Project.PropertyGroup.Version
if($version -notmatch '^(\d+\.\d+\.\d+)(?:-preview\.(\d+))?$'){throw 'Unsupported installer version format.'}
$assemblyVersion=$Matches[1]+'.0'
$fileVersion=$Matches[1]+'.'+$(if($Matches[2]){$Matches[2]}else{'0'})
if(-not $PublishPath){$PublishPath=Join-Path $root ('artifacts/SafeSync-'+$version+'-Windows-x64')}
$publish=(Resolve-Path -LiteralPath $PublishPath).Path
if(-not $publish.StartsWith((Join-Path $root 'artifacts')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Publish folder must be in windows-v2/artifacts.'}
# Reject stale developer artifacts instead of silently distributing them on a repeated build.
$unexpected=@(Get-ChildItem -LiteralPath $publish -Recurse -File | Where-Object {
    $_.Extension -in @('.pdb','.ps1','.cs','.swift') -or $_.Name -match '^(PREVIEW.+|TEST-RESULTS|MIGRATION|PARITY-AND-PERFORMANCE|RELEASE-VALIDATION|GOOGLE-LIVE-RESULTS|TWOWAY-AND-DROPBOX|DROPBOX-PRODUCTION)\.md$' -or $_.Name -match '^SafeSync\.(Tests|RestartProbe)'
})
if($unexpected.Count){throw 'Developer artifacts are present in the release folder. Use a clean release output directory.'}
$stage=Join-Path $root ('artifacts/packaging-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$common=@('/nologo','/optimize+','/platform:x64','/r:System.IO.Compression.dll','/r:System.IO.Compression.FileSystem.dll')
$core=Join-Path $root 'packaging/NativeSetupCore.cs'
$frontend=Join-Path $root 'packaging/NativeSetup.cs'
if($RunTests){
    $testExe=Join-Path $stage 'NativeSetupTests.exe'
    & $compiler @common /target:exe ("/out:"+$testExe) $core (Join-Path $root 'packaging/NativeSetupTests.cs')
    if($LASTEXITCODE -ne 0){throw 'Installer test compile failed.'}
    & $testExe $stage
    if($LASTEXITCODE -ne 0){throw 'Installer tests failed.'}
}
$assembly=Join-Path $stage 'AssemblyInfo.cs'
# This is generated build metadata, not editable project source.
$assemblyText='[assembly: System.Reflection.AssemblyVersion("'+$assemblyVersion+'")][assembly: System.Reflection.AssemblyFileVersion("'+$fileVersion+'")][assembly: System.Reflection.AssemblyInformationalVersion("'+$version+'")][assembly: System.Reflection.AssemblyCompany("Horizon Entertainment")][assembly: System.Reflection.AssemblyCopyright("SafeSync · Horizon Entertainment")]'
[IO.File]::WriteAllText($assembly,$assemblyText)
$gui=@('/target:winexe','/r:System.Windows.Forms.dll','/r:System.Drawing.dll',('/win32icon:'+(Join-Path (Split-Path $root -Parent) 'outputs/SafeSync/SafeSync.ico')))
& $compiler @common @gui /define:UNINSTALL ("/out:"+(Join-Path $publish 'Uninstall.exe')) $core $frontend $assembly
if($LASTEXITCODE -ne 0){throw 'Uninstaller compile failed.'}
$manifest=Join-Path $stage 'payload.sha256'
$files=@(Get-ChildItem -LiteralPath $publish -Recurse -File | Sort-Object FullName)
$entries=foreach($file in $files){(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetRelativePath($publish,$file.FullName).Replace('\','/')}
[IO.File]::WriteAllLines($manifest,$entries,[Text.UTF8Encoding]::new($false))
$payload=Join-Path $stage 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($publish,$payload,[IO.Compression.CompressionLevel]::Optimal,$false)
$setup=Join-Path $root ('artifacts/SafeSync-Setup-'+$version+'.exe')
& $compiler @common @gui ("/out:"+$setup) ("/resource:"+$payload+',Payload.zip') ("/resource:"+$manifest+',Payload.sha256') $core $frontend $assembly
if($LASTEXITCODE -ne 0){throw 'Setup compile failed.'}
if($RunTests){
    & $testExe /package $stage $payload $manifest
    if($LASTEXITCODE -ne 0){throw 'Isolated full-payload installation failed.'}
    $installed=Join-Path $stage 'installed-package'
    & (Join-Path $PSScriptRoot 'Test-Desktop.ps1') -AppPath (Join-Path $installed 'SafeSync.exe') -Bundled
    & $testExe /remove-test $installed
    if($LASTEXITCODE -ne 0){throw 'Isolated installed-payload removal failed.'}
    $verification=Start-Process -FilePath $setup -ArgumentList '/verify' -WindowStyle Hidden -PassThru
    if(-not $verification.WaitForExit(60000)){ $verification.Kill();throw 'Setup payload verification timed out.' }
    if($verification.ExitCode -ne 0){throw 'Setup embedded payload verification failed.'}
}
Get-FileHash -LiteralPath $setup -Algorithm SHA256
