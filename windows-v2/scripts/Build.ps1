[CmdletBinding()]
param([string]$DotnetPath='dotnet',[switch]$RunTests,[switch]$BundleRuntime,[string]$DropboxAppKey='')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$workspace=Split-Path $root -Parent
$version=[string]([xml](Get-Content -LiteralPath (Join-Path $root 'Directory.Build.props') -Raw)).Project.PropertyGroup.Version
$cache=Join-Path $workspace 'work/native-v2-build-cache'
$saved=@{}
if($DropboxAppKey -and $DropboxAppKey -notmatch '^[a-zA-Z0-9]{5,128}$'){throw 'DropboxAppKey must be a public Dropbox app key, not a secret or token.'}
$appKeyArg=@();if($DropboxAppKey){$appKeyArg=@('-p:SafeSyncDropboxAppKey='+$DropboxAppKey)}
foreach($name in @('APPDATA','DOTNET_CLI_HOME','DOTNET_CLI_TELEMETRY_OPTOUT','DOTNET_GENERATE_ASPNET_CERTIFICATE','DOTNET_ADD_GLOBAL_TOOLS_TO_PATH','NUGET_PACKAGES')){$saved[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try {
    # Isolate SDK/NuGet state. These process-only overrides are restored below;
    # no user-wide environment, tool registration or package config is changed.
    [void][IO.Directory]::CreateDirectory((Join-Path $cache 'roaming'))
    $env:APPDATA=Join-Path $cache 'roaming'
    $env:DOTNET_CLI_HOME=$cache
    $env:DOTNET_CLI_TELEMETRY_OPTOUT='1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false'
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false'
    $env:NUGET_PACKAGES=Join-Path $cache 'packages'
    $app=Join-Path $root 'src/SafeSync.App/SafeSync.App.csproj'
    $tests=Join-Path $root 'tests/SafeSync.Tests/SafeSync.Tests.csproj'
    foreach($project in @($app,$tests)){
        & $DotnetPath restore $project --configfile (Join-Path $root 'NuGet.Config') --nologo
        if($LASTEXITCODE -ne 0){throw 'Restore failed.'}
    }
    & $DotnetPath build $app -c Release --no-restore --nologo $appKeyArg
    if($LASTEXITCODE -ne 0){throw 'Native app build failed.'}
    if($RunTests){
        & $DotnetPath run --project $tests -c Release --no-restore $appKeyArg -- (Join-Path $root 'artifacts/tests')
        if($LASTEXITCODE -ne 0){throw 'Native core tests failed.'}
    }
    if($BundleRuntime){
        $publish=Join-Path $root ('artifacts/SafeSync-'+$version+'-Windows-x64')
        & $DotnetPath publish $app -c Release --no-restore --no-self-contained -p:AppHostRelativeDotNet=runtime -p:AppHostDotNetSearch=AppRelative -o $publish --nologo $appKeyArg
        if($LASTEXITCODE -ne 0){throw 'Native preview publish failed.'}
        # Use the official, checksum-verified SDK's redistributable runtimes.
        $dotnetRoot=Split-Path (Get-Command $DotnetPath).Source -Parent
        $runtimeRoot=Join-Path $publish 'runtime'
        foreach($component in @('host/fxr','shared/Microsoft.NETCore.App','shared/Microsoft.WindowsDesktop.App')){
            $available=Join-Path $dotnetRoot $component
            $version=@(Get-ChildItem -LiteralPath $available -Directory | Where-Object {$_.Name -match '^10\.0\.\d+$'} | Sort-Object {[version]$_.Name} -Descending)[0]
            if($null -eq $version){throw "Missing bundled runtime: $component"}
            $target=Join-Path $runtimeRoot $component
            [void][IO.Directory]::CreateDirectory($target)
            Copy-Item -LiteralPath $version.FullName -Destination $target -Recurse -Force
        }
        foreach($notice in @('LICENSE.txt','ThirdPartyNotices.txt')){Copy-Item -LiteralPath (Join-Path $dotnetRoot $notice) -Destination $runtimeRoot -Force}
        foreach($document in @('README-ko.md','MIGRATION.md','TEST-RESULTS.md','PARITY-AND-PERFORMANCE.md','RELEASE-VALIDATION.md','GOOGLE-LIVE-RESULTS.md','TWOWAY-AND-DROPBOX.md','DROPBOX-PRODUCTION.md','PREVIEW11-VALIDATION.md','PREVIEW12-VALIDATION.md','PREVIEW13-VALIDATION.md','PREVIEW14-VALIDATION.md','PREVIEW15-VALIDATION.md','PREVIEW16-VALIDATION.md','UPDATES.md')){Copy-Item -LiteralPath (Join-Path $root $document) -Destination (Join-Path $publish $document) -Force}
        Copy-Item -LiteralPath (Join-Path $root 'PREVIEW17-VALIDATION.md') -Destination (Join-Path $publish 'PREVIEW17-VALIDATION.md') -Force
        Copy-Item -LiteralPath (Join-Path $root 'PREVIEW18-VALIDATION.md') -Destination (Join-Path $publish 'PREVIEW18-VALIDATION.md') -Force
        Copy-Item -LiteralPath (Join-Path $root 'PREVIEW19-VALIDATION.md') -Destination (Join-Path $publish 'PREVIEW19-VALIDATION.md') -Force
        Copy-Item -LiteralPath (Join-Path $root 'PREVIEW20-VALIDATION.md') -Destination (Join-Path $publish 'PREVIEW20-VALIDATION.md') -Force
        if($RunTests){& (Join-Path $PSScriptRoot 'Test-Desktop.ps1') -AppPath (Join-Path $publish 'SafeSync.exe') -Bundled}
        & (Join-Path $PSScriptRoot 'Build-Installer.ps1') -PublishPath $publish -RunTests:$RunTests
        $zip=$publish+'.zip'
        Compress-Archive -LiteralPath $publish -DestinationPath $zip -CompressionLevel Optimal -Force
        Get-FileHash -LiteralPath $zip -Algorithm SHA256 | Select-Object Path,Hash
    }
}
finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name],'Process')}}
