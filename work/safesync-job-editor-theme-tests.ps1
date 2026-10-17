[CmdletBinding()]
param([string]$PreviewPath = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$path = (Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors.Message -join '; ') }
foreach ($name in @('Load-Xaml','Get-SafeSyncThemeMode','Get-SafeSyncThemePalette','New-SafeSyncThemeBrush','Get-SafeSyncThemeBrushRole','Set-SafeSyncThemeElementBrush','Apply-SafeSyncThemeToWindow')) {
    $node = @($ast.FindAll({param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name}, $true))[0]
    if ($null -eq $node) { throw "Missing function: $name" }
    Invoke-Expression $node.Extent.Text
}
$editor = @($ast.FindAll({param($item) $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Show-JobEditor'}, $true))[0]
$editorXaml = @($editor.FindAll({param($item) $item -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $item.Value.TrimStart().StartsWith('<Window')}, $true))[0].Value
if ([string]::IsNullOrWhiteSpace($editorXaml)) { throw 'Job editor XAML is missing.' }

foreach ($mode in @('Light','Dark')) {
    $script:Config = [pscustomobject]@{ ThemeMode=$mode }
    $window = Load-Xaml $editorXaml
    try {
        Apply-SafeSyncThemeToWindow $window
        $palette = Get-SafeSyncThemePalette
        $expectedText = [System.Windows.Media.ColorConverter]::ConvertFromString($palette.Text)
        $expectedWindow = [System.Windows.Media.ColorConverter]::ConvertFromString($palette.Window)
        $expectedInput = [System.Windows.Media.ColorConverter]::ConvertFromString($palette.Input)
        $combo = $window.FindName('DestinationTypeBox')
        $combo.SelectedIndex = 0
        $label = $window.FindName('RealtimeRadio')
        $check = $window.FindName('MirrorCheck')
        $box = $window.FindName('NameBox')
        $browse = $window.FindName('SourceBrowse')
        if ($window.Background.Color -ne $expectedWindow) { throw "$mode window background is wrong." }
        if ($box.Background.Color -ne $expectedInput -or $box.Foreground.Color -ne $expectedText) { throw "$mode text box colors are wrong." }
        if ($browse.Foreground.Color -ne $expectedText -or $label.Foreground.Color -ne $expectedText -or $check.Foreground.Color -ne $expectedText) { throw "$mode control text colors are wrong." }
        if ($combo.Background.Color -ne $expectedInput -or $combo.Foreground.Color -ne $expectedText) { throw "$mode combo box colors are wrong." }
        $combo.ApplyTemplate() | Out-Null
        $popup = $combo.Template.FindName('PART_Popup',$combo)
        if ($null -eq $popup -or $popup.Child.Background.Color -ne ([System.Windows.Media.ColorConverter]::ConvertFromString($palette.Surface))) { throw "$mode dropdown popup background is wrong." }
        foreach ($item in @($combo.Items)) {
            $itemText = if ($item.IsSelected) { [System.Windows.Media.Colors]::White } else { $expectedText }
            if ($item.Background.Color -ne ([System.Windows.Media.ColorConverter]::ConvertFromString($palette.Surface)) -or $item.Foreground.Color -ne $itemText) { throw "$mode dropdown item colors are wrong." }
        }
        if ($window.FindName('SaveButton').Background.Color -ne ([System.Windows.Media.ColorConverter]::ConvertFromString($palette.Accent))) { throw "$mode save button accent is wrong." }
        if ($mode -eq 'Dark' -and -not [string]::IsNullOrWhiteSpace($PreviewPath)) {
            $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
            $window.Left = -32000; $window.Top = -32000; $window.ShowInTaskbar = $false
            $window.Show()
            $combo.IsDropDownOpen = $true
            $window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
            if (-not $popup.IsOpen) { throw 'The dark dropdown did not open.' }
            if ($popup.Child.ActualWidth -lt ($combo.ActualWidth - 2)) { throw 'The dark dropdown popup is narrower than the selection box.' }
            $combo.SelectedIndex = 1
            if ([string]$combo.SelectedItem.Tag -ne 'Dropbox') { throw 'The dark dropdown did not change selection.' }
            $combo.IsDropDownOpen = $false
            $combo.SelectedIndex = 0
            $window.Measure([System.Windows.Size]::new(680,545))
            $window.Arrange([System.Windows.Rect]::new(0,0,680,545))
            $window.UpdateLayout()
            $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(680,545,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($window)
            $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream = [System.IO.File]::Create([System.IO.Path]::GetFullPath($PreviewPath))
            try { $encoder.Save($stream) } finally { $stream.Dispose() }
        }
    }
    finally { $window.Close() }
}
'SafeSync job editor theme tests OK'
