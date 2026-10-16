$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
$script:Passed = 0
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }

$script:TestRoot = Join-Path (Resolve-Path '.\work').Path ('trash-window-test-' + [guid]::NewGuid().ToString('N'))
$script:DataRoot = Join-Path $script:TestRoot 'data'
$script:ResultRoot = Join-Path $script:DataRoot 'results'
$destination = Join-Path $script:TestRoot 'destination'
$trashFile = Join-Path $destination '.safesync-trash\20261003-010203000-deleted\folder\example.txt'
[void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $trashFile))
[void][System.IO.Directory]::CreateDirectory($script:ResultRoot)
[System.IO.File]::WriteAllText($trashFile, 'example')
$script:Job = [pscustomobject]@{ Id='trash-window'; Name='Trash window'; Source=(Join-Path $script:TestRoot 'source'); Destination=$destination; DestinationType='Local' }
[pscustomobject]@{ Jobs=@($script:Job); CloudAccounts=[pscustomobject]@{Dropbox=[pscustomobject]@{};GoogleDrive=[pscustomobject]@{}} } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:DataRoot 'config.json') -Encoding UTF8
$script:ScriptPath = (Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$script:Window = New-Object System.Windows.Window
$script:Window.Width = 300
$script:Window.Height = 200
$script:TrashBrowserContext = $null
function Get-SelectedJob { return $script:Job }
function Load-Xaml([string]$Xaml) { return [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$Xaml))) }
function Add-Activity([string]$Message) {}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
Assert-Test ($errors.Count -eq 0) 'Main script does not parse.'
$needed = @('Get-SafeSyncTrashCachePath','Initialize-SafeSyncTrashBrowser','Show-SelectedSafeSyncTrashBrowser')
foreach ($node in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true)) {
    if ($node.Name -in $needed) { Invoke-Expression $node.Extent.Text }
}

$script:Failure = ''
$script:Stage = 0
$script:Started = [datetime]::UtcNow
$application = New-Object System.Windows.Application
$application.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    try {
        if ($script:Stage -eq 0) {
            $script:Window.Show()
            Show-SelectedSafeSyncTrashBrowser
            Assert-Test ($null -ne $script:TrashBrowserContext -and $script:TrashBrowserContext.Dialog.IsVisible) 'Trash window did not open modelessly.'
            Assert-Test ($script:Window.IsEnabled -and $null -eq $script:TrashBrowserContext.Dialog.Owner) 'The main window is blocked by the trash browser.'
            $firstWindow = $script:TrashBrowserContext.Dialog
            Show-SelectedSafeSyncTrashBrowser
            Assert-Test ([object]::ReferenceEquals($firstWindow, $script:TrashBrowserContext.Dialog)) 'Opening trash again created a second conflicting window.'
            $script:Stage = 1
        }
        elseif ($script:Stage -eq 1 -and $null -ne $script:TrashBrowserContext -and -not $script:TrashBrowserContext.State.Busy -and
                $null -ne $script:TrashBrowserContext.Grid.ItemsSource -and @($script:TrashBrowserContext.Grid.ItemsSource).Count -eq 1) {
            Assert-Test ([string]@($script:TrashBrowserContext.Grid.ItemsSource)[0].Name -eq 'example.txt') 'Background listing did not populate the modeless window.'
            $cachePath = Get-SafeSyncTrashCachePath $script:Job
            Assert-Test (Test-Path -LiteralPath $cachePath -PathType Leaf) 'The first listing did not create its reusable cache.'
            $script:TrashBrowserContext.Dialog.Close()
            Assert-Test ($null -eq $script:TrashBrowserContext) 'Closing the window did not clear its event state.'
            Show-SelectedSafeSyncTrashBrowser
            $script:Stage = 2
        }
        elseif ($script:Stage -eq 2 -and $null -ne $script:TrashBrowserContext -and
                $null -ne $script:TrashBrowserContext.Grid.ItemsSource -and @($script:TrashBrowserContext.Grid.ItemsSource).Count -eq 1) {
            Assert-Test (-not $script:TrashBrowserContext.State.Busy) 'A recent cached listing needlessly restarted a full scan.'
            Assert-Test ($script:Window.IsEnabled) 'The main window became disabled after reopening trash.'
            $script:TrashBrowserContext.Dialog.Close()
            $script:Window.Close()
            $timer.Stop()
            $application.Shutdown()
        }
        if (([datetime]::UtcNow - $script:Started).TotalSeconds -gt 20) { throw 'Timed out waiting for the trash browser.' }
    }
    catch {
        $script:Failure = $_.Exception.Message
        $timer.Stop()
        if ($null -ne $script:TrashBrowserContext) { try { $script:TrashBrowserContext.Dialog.Close() } catch {} }
        try { $script:Window.Close() } catch {}
        $application.Shutdown()
    }
})
try {
    $timer.Start()
    [void]$application.Run()
    if (-not [string]::IsNullOrWhiteSpace($script:Failure)) { throw $script:Failure }
}
finally {
    if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "PASS: $script:Passed trash-window assertions"
