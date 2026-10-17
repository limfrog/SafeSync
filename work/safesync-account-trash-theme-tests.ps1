[CmdletBinding()]
param([string]$PreviewDirectory = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:Passed = 0
function Assert-Theme([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }
function Save-ThemePreview($Window,[string]$Name) {
    if ([string]::IsNullOrWhiteSpace($PreviewDirectory)) { return }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($PreviewDirectory))
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($Window.ActualWidth),[int][Math]::Ceiling($Window.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path ([IO.Path]::GetFullPath($PreviewDirectory)) $Name))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
}
$sourcePath = (Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
Assert-Theme ($errors.Count -eq 0) 'Source does not parse.'
foreach ($name in @('Load-Xaml','Get-SafeSyncThemeMode','Get-SafeSyncThemePalette','New-SafeSyncThemeBrush','Get-SafeSyncThemeBrushRole','Set-SafeSyncThemeElementBrush','Apply-SafeSyncThemeToWindow')) {
    $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
    Invoke-Expression $node.Extent.Text
}
foreach ($functionName in @('Show-CloudAccountSettings','Show-SelectedSafeSyncTrashBrowser')) {
    $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $functionName},$true))[0]
    $xaml=@($node.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.TrimStart().StartsWith('<Window')},$true))[0].Value
    foreach ($mode in @('Light','Dark')) {
        $script:Config=[pscustomobject]@{ThemeMode=$mode}
        $window=Load-Xaml $xaml
        try {
            Apply-SafeSyncThemeToWindow $window
            $palette=Get-SafeSyncThemePalette
            $window.WindowStartupLocation='Manual'; $window.Left=-32000; $window.Top=-32000; $window.ShowInTaskbar=$false
            $isCloud=$functionName -eq 'Show-CloudAccountSettings'
            if ($isCloud) {
                $window.FindName('DropboxStatus').Text='연결되지 않음'
                $window.FindName('GoogleStatus').Text='연결됨: sample@example.com'
                $buttons=@('DropboxConnect','DropboxDisconnect','GoogleConnect','GoogleDisconnect','SaveCredentials','CloseButton')
                foreach ($name in @('DropboxKey','GoogleClientId','GoogleSecret')) {
                    $control=$window.FindName($name)
                    Assert-Theme ($control.Background.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Input)) "$mode $name input background is wrong."
                    Assert-Theme ($control.Foreground.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Text)) "$mode $name input text is wrong."
                    Assert-Theme ($control.CaretBrush.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Text)) "$mode $name caret is wrong."
                }
            } else {
                $buttons=@('RefreshButton','SelectAllButton','CloseButton','DeleteButton','RestoreButton')
                $window.FindName('JobText').Text='작업: 테스트 백업 · 백업 위치: D:\Backup'
                $window.FindName('StatusText').Text='파일 1개'
                $window.FindName('TrashGrid').ItemsSource=@([pscustomobject]@{Name='example.txt';DeletedAtText='2026-10-17 16:30:00';OriginalPath='D:\Backup\Documents\example.txt';SizeText='4 KB'})
            }
            $window.Show(); $window.UpdateLayout()
            $window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
            Assert-Theme ($window.Background.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Window)) "$mode window background is wrong."
            foreach ($name in $buttons) {
                $button=$window.FindName($name)
                $button.ApplyTemplate() | Out-Null
                $surface=$button.Template.FindName('ButtonSurface',$button)
                Assert-Theme ($null -ne $surface) "$mode $name uses the native light button template."
                Assert-Theme ($surface.Background.Color -eq $button.Background.Color) "$mode $name template loses its background."
                Assert-Theme ($surface.CornerRadius.TopLeft -eq 6) "$mode $name is not using the rounded button style."
                Assert-Theme ($surface.ActualHeight -ge 30) "$mode $name is clipped."
            }
            if ($isCloud) {
                $scroll=$window.FindName('AccountsScroll')
                Assert-Theme ($scroll.ComputedVerticalScrollBarVisibility -ne 'Visible') "$mode default account window unnecessarily scrolls: extent=$($scroll.ExtentHeight), viewport=$($scroll.ViewportHeight)."
                Assert-Theme ($scroll.ComputedHorizontalScrollBarVisibility -ne 'Visible') "$mode account window scrolls horizontally."
                Save-ThemePreview $window "accounts-$mode.png"
                # Long account names wrap instead of running beyond the window.
                $window.FindName('GoogleStatus').Text='연결됨: long-account-name-for-backup@example.com (개인 백업 계정)'
                $window.Width=700; $window.Height=480; $window.UpdateLayout()
                $root=$window.FindName('CloudAccountsLayout')
                $close=$window.FindName('CloseButton')
                $bottom=$close.TransformToAncestor($root).Transform([Windows.Point]::new(0,$close.ActualHeight)).Y
                Assert-Theme ($bottom -le $root.ActualHeight+1) "$mode small-window footer is clipped."
                Assert-Theme ($scroll.ComputedVerticalScrollBarVisibility -eq 'Visible') "$mode small-window content is inaccessible."
                $scroll.ScrollToBottom(); $window.UpdateLayout()
                Assert-Theme ($scroll.VerticalOffset -gt 0) "$mode small-window scrolling is broken."
            } else {
                Save-ThemePreview $window "trash-$mode.png"
                foreach ($name in @('DeleteButton','RestoreButton')) {
                    $button=$window.FindName($name); $button.IsEnabled=$false; $window.UpdateLayout()
                    $surface=$button.Template.FindName('ButtonSurface',$button)
                    Assert-Theme ($surface.Background.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Subtle)) "$mode disabled $name has a bright system background."
                    $button.IsEnabled=$true; $window.UpdateLayout()
                    Assert-Theme ($surface.Background.Color -eq $button.Background.Color) "$mode $name does not restore its action color."
                }
                Assert-Theme ($window.FindName('RestoreButton').Background.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Accent)) "$mode restore button loses its action color."
                Assert-Theme ($window.FindName('DeleteButton').Background.Color -eq [Windows.Media.ColorConverter]::ConvertFromString($palette.Danger)) "$mode delete button loses its warning color."
            }
        } finally { $window.Close() }
    }
}
"PASS: $script:Passed account/trash theme and layout assertions"
