[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$appRoot = Join-Path $taskRoot 'outputs\SafeSync'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is required.' }
$framework = Split-Path -Parent $compiler
$references = @('System.dll','System.Core.dll','System.Drawing.dll','System.Windows.Forms.dll','System.IO.Compression.dll','System.IO.Compression.FileSystem.dll','System.Management.dll') | ForEach-Object { '/reference:' + (Join-Path $framework $_) }
$common = @('/nologo','/optimize+','/target:winexe','/platform:anycpu','/utf8output','/codepage:65001',('/win32manifest:' + (Join-Path $PSScriptRoot 'app.manifest')))
$iconSource = Join-Path $appRoot 'SafeSync.ico'
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) { throw 'SafeSync.ico is required for the application icon.' }
& (Join-Path $PSScriptRoot 'New-TrayIcons.ps1') -SourceImage (Join-Path $appRoot 'SafeSync-icon.png') -Destination $appRoot
$common += '/win32icon:' + $iconSource
$common += $references
& $compiler $common ('/out:' + (Join-Path $appRoot 'SafeSync.exe')) (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'runtime.config') -Destination (Join-Path $appRoot 'SafeSync.exe.config') -Force
$installerSources = @((Join-Path $PSScriptRoot 'InstallerCore.cs'), (Join-Path $PSScriptRoot 'InstallerUI.cs'))
& $compiler $common ('/out:' + (Join-Path $appRoot 'Uninstall.exe')) $installerSources (Join-Path $PSScriptRoot 'Uninstall.cs')
if ($LASTEXITCODE -ne 0) { throw 'Uninstaller compilation failed.' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$names = @('SafeSync.exe','SafeSync.exe.config','SafeSync.ps1','SafeSync.Cloud.ps1','SafeSync.Integrity.ps1','SafeSync.TrashWorker.ps1','SafeSync.ico','SafeSync-Progress-0.ico','SafeSync-Progress-1.ico','SafeSync-Progress-2.ico','SafeSync-Progress-3.ico','Start SafeSync.cmd','README-ko.md','Uninstall.exe')
$payload = Join-Path $PSScriptRoot 'payload.zip'
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Force }
$archive = [System.IO.Compression.ZipFile]::Open($payload, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $names) { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $appRoot $name), $name, [System.IO.Compression.CompressionLevel]::Optimal) }
} finally { $archive.Dispose() }
$manifest = ($names | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $appRoot $_) -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_ }) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'payload.sha256'), $manifest, [System.Text.UTF8Encoding]::new($false))
$setupPath = Join-Path $taskRoot 'outputs\SafeSync-Setup.exe'
$resources = @(('/resource:' + $payload + ',SafeSync.Payload.zip'), ('/resource:' + (Join-Path $PSScriptRoot 'payload.sha256') + ',SafeSync.Payload.sha256'))
& $compiler $common ('/out:' + $setupPath) $resources $installerSources (Join-Path $PSScriptRoot 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Setup compilation failed.' }
Compress-Archive -Path (Join-Path $appRoot '*') -DestinationPath (Join-Path $taskRoot 'outputs\SafeSync-Windows.zip') -CompressionLevel Optimal -Force
Get-Item -LiteralPath $setupPath | Select-Object Name,Length,LastWriteTime
