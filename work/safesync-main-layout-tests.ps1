[CmdletBinding()]
param([string]$PreviewDirectory = '',[string]$SourcePath = '.\outputs\SafeSync\SafeSync.ps1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$script:Passed = 0
function Assert-Layout([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:Passed++ }
function Save-LayoutPreview([System.Windows.FrameworkElement]$Element,[string]$Name) {
    if([string]::IsNullOrWhiteSpace($PreviewDirectory)){return}
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($PreviewDirectory))
    $bitmap=[System.Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($Element.ActualWidth),[int][Math]::Ceiling($Element.ActualHeight),96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Element)
    $encoder=[System.Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[System.IO.File]::Create((Join-Path ([System.IO.Path]::GetFullPath($PreviewDirectory)) $Name))
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
$path = (Resolve-Path $SourcePath).Path
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Layout ($errors.Count -eq 0) 'Application source does not parse.'
$names=@('Load-Xaml','Get-SafeSyncThemeMode','Get-SafeSyncThemePalette','New-SafeSyncThemeBrush','Get-SafeSyncThemeBrushRole','Set-SafeSyncThemeElementBrush','Apply-SafeSyncThemeToWindow','Find-Control','Refresh-JobsGrid','Get-TriggerText','Test-SafeSyncJobPaused','Get-SelectedJob','Update-JobActionButtons','Update-SafeSyncMainPaneLimit','Initialize-SafeSyncMainShortcuts')
foreach($node in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)) { if($names -contains $node.Name) { Invoke-Expression $node.Extent.Text } }
$xaml=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.TrimStart().StartsWith('<Window') -and $n.Value.Contains('x:Name="JobsGrid"')},$true))[0].Value
$script:AppVersion='1.9.15'
$script:RunningJobs=@{}; $script:LastStatus=@{}
$script:SettingsOpened=0
function Show-ApplicationSettings { $script:SettingsOpened++ }
foreach($mode in @('Light','Dark')) {
    $script:Config=[pscustomobject]@{ThemeMode=$mode;TrashRetentionDays=100;Jobs=@()}
    $script:Window=Load-Xaml $xaml
    foreach($name in @('JobsGrid','ActivityBox','FooterText','NotificationsButton','EditButton','DeleteButton','PauseButton','RunButton','FullScanButton','ProgressButton','TrashButton','MainJobsRow','MainActivityRow')) { Set-Variable -Scope Script -Name $name -Value (Find-Control $name) }
    $window=$script:Window
    (Find-Control 'MainLayoutRoot').Add_LayoutUpdated({ Update-SafeSyncMainPaneLimit })
    try {
        Apply-SafeSyncThemeToWindow $window
        Initialize-SafeSyncMainShortcuts
        Refresh-JobsGrid
        Assert-Layout (-not (Find-Control 'JobActionsButton').IsEnabled) "$mode empty list still enables task management."
        Assert-Layout (-not (Find-Control 'TrashShortcutButton').IsEnabled) "$mode empty list still enables the trash shortcut."
        Assert-Layout ((Find-Control 'EmptyJobsHint').Visibility -eq 'Visible') "$mode empty-state guidance is missing."
        $script:Config.Jobs=@(
            [pscustomobject]@{Id='job-a';Name='Studio projects';Source='J:\Work\Projects';Destination='Google Drive / Backup / Studio';TriggerType='Realtime';ScheduleTime='23:00';Paused=$false},
            [pscustomobject]@{Id='job-b';Name='Daily archive';Source='D:\Documents';Destination='\\NAS\Backup\Documents';TriggerType='Scheduled';ScheduleTime='23:00';Paused=$true}
        )
        Refresh-JobsGrid
        Assert-Layout ((Find-Control 'EmptyJobsHint').Visibility -eq 'Collapsed') "$mode empty-state guidance covers the task list."
        $script:JobsGrid.SelectedIndex=0
        Update-JobActionButtons
        Assert-Layout ((Find-Control 'JobActionsButton').IsEnabled -and $script:RunButton.IsEnabled) "$mode selected job does not enable actions."
        Assert-Layout (@((Find-Control 'JobActionsButton').ContextMenu.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] -and $_.Tag -eq 'TrashButton' }).Count -eq 0) "$mode task-management menu still duplicates the trash shortcut."
        $script:Forwarded=0
        $script:EditButton.Add_Click({$script:Forwarded++})
        $edit=@((Find-Control 'JobActionsButton').ContextMenu.Items | Where-Object { $_ -is [System.Windows.Controls.MenuItem] -and $_.Tag -eq 'EditButton' })[0]
        $edit.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
        Assert-Layout ($script:Forwarded -eq 1) "$mode task-management edit does not reach the existing editor action."
        $script:TrashOpened=0
        $script:TrashButton.Add_Click({$script:TrashOpened++})
        (Find-Control 'TrashShortcutButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-Layout ($script:TrashOpened -eq 1) "$mode trash shortcut does not reach the existing trash browser action."
        $script:JobsGrid.SelectedIndex=1; Update-JobActionButtons
        Assert-Layout (-not $script:RunButton.IsEnabled -and -not $script:FullScanButton.IsEnabled) "$mode paused job allows a backup action."
        $script:JobsGrid.SelectedIndex=0; Update-JobActionButtons
        (Find-Control 'SettingsShortcutButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-Layout ($script:SettingsOpened -gt 0) "$mode settings shortcut did not open settings."
        $window.WindowStartupLocation='Manual'; $window.Left=-32000; $window.Top=-32000; $window.ShowInTaskbar=$false
        $decoder=[System.Windows.Media.Imaging.BitmapDecoder]::Create([uri](Join-Path (Split-Path $path -Parent) 'SafeSync.ico'),[System.Windows.Media.Imaging.BitmapCreateOptions]::None,[System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        (Find-Control 'BrandImage').Source=@($decoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1)[0]
        $script:ActivityBox.Text="17:42:15  Backup completed: Studio projects`r`n17:42:11  Comparing changed Google Drive files`r`n17:40:03  Automatic backup engine started"
        $window.Show(); $window.UpdateLayout()
        $window.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        (Find-Control 'JobActionsButton').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $window.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $menu=(Find-Control 'JobActionsButton').ContextMenu
        Assert-Layout $menu.IsOpen "$mode task-management menu does not open."
        Assert-Layout ($edit.ActualHeight -ge 20) "$mode task-management menu items are not visible."
        $palette=Get-SafeSyncThemePalette
        Assert-Layout ($menu.Background.Color -eq ([System.Windows.Media.ColorConverter]::ConvertFromString($palette.Surface))) "$mode task-management popup has the wrong background."
        $menuSurface=$menu.Template.FindName('MenuPopupSurface',$menu)
        Assert-Layout ($menuSurface.BorderBrush.Color -eq ([System.Windows.Media.ColorConverter]::ConvertFromString($palette.MenuBorder))) "$mode task-management popup has a default system border."
        $edit.Focus() | Out-Null
        $window.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        Save-LayoutPreview $menu "menu-$mode-task.png"
        $menu.IsOpen=$false
        $window.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        foreach($width in @(1180,800)) {
            $window.Width=$width; $window.Height=if($width -eq 800){540}else{720}
            $window.UpdateLayout(); Update-SafeSyncMainPaneLimit; $window.UpdateLayout()
            $window.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
            $columnWidth=0.0;foreach($column in $script:JobsGrid.Columns){$columnWidth+=$column.ActualWidth}
            Assert-Layout ($columnWidth -ge $script:JobsGrid.ActualWidth-40) "$mode table columns do not fill the available width."
            $root=Find-Control 'MainLayoutRoot'; $footer=Find-Control 'FooterText'
            $bottom=$footer.TransformToAncestor($root).Transform([System.Windows.Point]::new(0,$footer.ActualHeight)).Y
            $viewport=[System.Windows.Media.VisualTreeHelper]::GetParent($root)
            Assert-Layout ($root.ActualHeight+$root.Margin.Top+$root.Margin.Bottom -le $viewport.ActualHeight+1) "$mode content overflows the client area at width $width."
            Assert-Layout ($bottom -le $root.ActualHeight+1) "$mode footer is clipped at width $width."
            foreach($buttonName in @('AddButton','RunButton','PauseButton','RunAllButton','ProgressButton','TrashShortcutButton','JobActionsButton','SettingsShortcutButton')) {
                $button=Find-Control $buttonName
                $right=$button.TransformToAncestor($root).Transform([System.Windows.Point]::new($button.ActualWidth,0)).X
                Assert-Layout ($right -le $root.ActualWidth+1) "$mode $buttonName is clipped at width $width."
            }
            Save-LayoutPreview $window "main-$mode-$width.png"
        }
    } finally { $window.Close() }
}
"PASS: $script:Passed main layout and shortcut assertions"
