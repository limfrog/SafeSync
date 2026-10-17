$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Drawing
$script:Passed=0
function Assert-Test([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Passed++}

$path=(Resolve-Path '.\outputs\SafeSync\SafeSync.ps1').Path
$source=[System.IO.File]::ReadAllText($path,[System.Text.Encoding]::UTF8)
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-Test ($errors.Count -eq 0) 'Main script does not parse.'
$syncNode=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Sync-ProgressWindowPlacement'},$true))[0]
Invoke-Expression $syncNode.Extent.Text
$trayLocationNode=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-SafeSyncTrayMenuLocation'},$true))[0]
Invoke-Expression $trayLocationNode.Extent.Text
$watcherStartNode=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-Watchers'},$true))[0]

Assert-Test ($source.Contains('x:Name="SettingsButton"')) 'The main window has no settings button.'
Assert-Test (-not $source.Contains('$script:Window.Add_LocationChanged({ Sync-ProgressWindowPlacement })')) 'Moving the main window still forces the progress window to dock.'
Assert-Test ($source.Contains('limfrog75@gmail.com')) 'Author email is missing from settings.'
$author=([string][char]0xC784)+([string][char]0xD638)
Assert-Test ($source.Contains($author)) 'Author name is missing from settings.'
Assert-Test ($source.Contains("`$script:AppVersion = '1.9.12'")) 'Displayed application version is incorrect.'
Assert-Test ($source.Contains('x:Name="PauseButton"')) 'The main window has no per-job pause button.'
Assert-Test ($source.Contains('x:Name="TrashButton"')) 'The main window has no SafeSync trash button.'
$runClick=[regex]::Match($source,'\$script:RunButton\.Add_Click\(\{[^\r\n]+\}\)').Value
Assert-Test ($source.Contains('x:Name="FullScanButton"') -and $source.Contains('$script:FullScanButton.Add_Click') -and $source.Contains('-ForceFull)')) 'Fast backup and full verification are not separate actions.'
Assert-Test (-not [string]::IsNullOrWhiteSpace($runClick) -and -not $runClick.Contains('-ForceFull')) 'The normal manual backup still forces a full scan.'
Assert-Test ($source.Contains('x:Name="TrashGrid"') -and $source.Contains('SelectionMode="Extended"')) 'The trash browser does not support multi-selection.'
Assert-Test ($source.Contains('x:Name="RestoreButton"') -and $source.Contains('Restore-SafeSyncTrashItems')) 'The trash browser has no restore action.'
Assert-Test ($source.Contains('Get-SafeSyncDropboxTrashItems') -and $source.Contains('Get-SafeSyncGoogleTrashItems')) 'The trash browser does not support both cloud API providers.'
Assert-Test ($source.Contains('DropboxCursor') -and $source.Contains('GoogleChangeToken')) 'Cloud change-feed cursors are not persisted.'
Assert-Test ($source.Contains('Set-SafeSyncJobPaused $job $true') -and $source.Contains('$pauseFailures = @(')) 'Trash restore does not remain paused for safe review.'
Assert-Test ($source.Contains('Binding="{Binding DeletedAtText}"') -and $source.Contains('Binding="{Binding OriginalPath}"')) 'The trash browser is missing deletion time or original path.'
Assert-Test ($watcherStartNode.Extent.Text.Contains('Invoke-SafeSyncOfflineChangeDetection')) 'Startup change detection does not use the persisted offline journal.'
Assert-Test ($watcherStartNode.Extent.Text.Contains('Queue-SafeSyncSnapshotRetries')) 'Saved failed files are not queued without a source-wide startup comparison.'
Assert-Test ($source.Contains("`$snapshotDetail = if (`$destinationType -eq 'GoogleDrive')")) 'Startup metadata comparison is not clearly identified as separate from a Google Drive scan.'
Assert-Test (-not $watcherStartNode.Extent.Text.Contains('Queue-SafeSyncStartupReconciliation')) 'Startup reconciliation still blocks the UI thread.'
Assert-Test ($source.Contains('Text="{Binding FolderText}"')) 'Detailed progress does not show the folder being inspected.'
Assert-Test ($source.Contains("'Connecting to Dropbox'") -and $source.Contains("'Connecting to Google Drive'")) 'Cloud connection stages are not translated for the progress UI.'
Assert-Test ($source.Contains('$script:ReconciliationJobs.Keys')) 'Startup comparison is not included in the progress window.'
Assert-Test ($source.Contains('x:Name="ConflictGrid"')) 'The per-file conflict resolution window is missing.'
Assert-Test ($source.Contains("Action='Ignore'") -and $source.Contains("Value='Backup'")) 'Conflict resolution choices or their safe default are missing.'
Assert-Test ($source.Contains('-ConflictBackupPaths $backupPaths')) 'Selected conflict files are not routed to the resolution worker.'
Assert-Test ($source.Contains('x:Name="ProgressConflictGrid"') -and $source.Contains('x:Name="SourceSummaryPath"') -and $source.Contains('x:Name="DestinationSummaryPath"')) 'The progress window does not contain the integrated two-sided comparison UI.'
Assert-Test ($source.Contains('Tag="Overwrite"') -and $source.Contains('Tag="RenameThenCopy"') -and $source.Contains('Tag="Ignore"')) 'The integrated conflict grid does not offer all three requested actions as per-file buttons.'
Assert-Test ($source.Contains('-ConflictRenamePaths $rename')) 'Rename-and-copy conflict choices are not routed to the worker.'
Assert-Test ($source.Contains('elseif (-not [string]::IsNullOrWhiteSpace([string]$Job.Destination))') -and $source.Contains('human-readable label')) 'The progress route still displays a cloud folder ID instead of its saved label.'
Assert-Test ($source.Contains('function Open-SafeSyncJobFolder') -and $source.Contains('Get-SafeSyncVisualAncestor')) 'Folder double-click navigation is missing.'
Assert-Test (-not $source.Contains("(Find-Control 'CloudAccountsButton').Add_Click")) 'The cloud account button is still wired as a main-window action.'
Assert-Test ($source.Contains("`$dialog.FindName('CloudAccountsButton').Add_Click({ Show-CloudAccountSettings })")) 'The cloud account button is not wired inside settings.'
Assert-Test ($source.Contains('x:Name="NotificationsButton"')) 'The main window has no pending-message button.'
Assert-Test ($source.Contains('x:Name="ProgressButton"') -and $source.Contains('Toggle-SafeSyncProgressWindow')) 'The synchronization status window has no open/close control.'
Assert-Test ($source.Contains('$script:ProgressWindowUserHidden') -and $source.Contains('Hide-SafeSyncProgressWindow')) 'Closing the status window does not persist the user hide choice.'
Assert-Test ($source.Contains('function Set-SafeSyncProgressWindowVisibility') -and $source.Contains('$script:ProgressWindowTransitioning')) 'Progress-window Show/Hide calls are not serialized against WPF re-entry.'
Assert-Test ($source.Contains('function Show-SafeSyncMainWindow') -and $source.Contains('$script:MainWindowTransitioning')) 'Main-window tray Show calls are not serialized against WPF re-entry.'
Assert-Test ($source.Contains('[SafeSyncDpi]::Enable()') -and $source.Contains('$trayMenu.add_Opened')) 'Tray menu DPI setup or final-position correction is missing.'
Assert-Test ($source.Contains('$script:NotifyIcon.add_MouseDoubleClick') -and -not $source.Contains('$script:NotifyIcon.add_DoubleClick')) 'Right double-click can still be mistaken for an open-window action.'
$bottomTrayLocation=Get-SafeSyncTrayMenuLocation ([System.Drawing.Point]::new(1900,1070)) ([System.Drawing.Rectangle]::new(0,0,1920,1040)) ([System.Drawing.Size]::new(150,90))
Assert-Test ($bottomTrayLocation.X -eq 1750 -and $bottomTrayLocation.Y -eq 950) 'A bottom-right tray menu is not anchored beside the notification icon.'
$leftTrayLocation=Get-SafeSyncTrayMenuLocation ([System.Drawing.Point]::new(-10,400)) ([System.Drawing.Rectangle]::new(40,0,1880,1040)) ([System.Drawing.Size]::new(150,90))
Assert-Test ($leftTrayLocation.X -eq 40 -and $leftTrayLocation.Y -eq 310) 'A left-side taskbar menu is not clamped to its monitor.'
Assert-Test ($source.Contains('add_DispatcherUnhandledException') -and $source.Contains('$eventArgs.Handled = $true')) 'Unhandled WPF UI exceptions can still display the raw .NET dialog.'
Assert-Test ($source.Contains('function Request-SafeSyncProgressRefresh') -and $source.Contains('[System.Windows.Threading.DispatcherPriority]::Background')) 'Progress refresh work is not coalesced below user input priority.'
Assert-Test ($source.Contains('$script:ProgressTimer.Interval = [TimeSpan]::FromMilliseconds(750)')) 'The progress window still rebuilds too frequently for responsive input.'
Assert-Test ($source.Contains('$script:Window.Add_Activated') -and -not $source.Contains('$script:ProgressWindow.Owner = $script:Window')) 'The status window cannot move behind the main window when the main window is clicked.'
Assert-Test ($source.Contains('[System.Drawing.SystemIcons]::Warning')) 'Pending messages do not change the tray icon.'
Assert-Test ($source.Contains('function Initialize-SafeSyncTrayAnimation') -and $source.Contains('SafeSync-Progress-$step.ico') -and $source.Contains('Initialize-SafeSyncTrayAnimation') -and $source.Contains('TrayAnimationTimer')) 'The tray icon has no packaged progress animation.'
Assert-Test (-not $source.Contains('ShowBalloonTip') -and $source.Contains('MessageBoxImage]::None')) 'Tray notifications can still trigger a Windows system sound.'
Assert-Test ($source.Contains('SoundOnMinimizeCheck') -and $source.Contains('SoundOnBackupCompleteCheck') -and $source.Contains('SoundOnBackupErrorCheck')) 'Notification sound settings are missing from the configuration window.'
Assert-Test (-not $source.Contains('ShowBalloonTip') -and $source.Contains("Play-SafeSyncNotificationSound 'Minimize'") -and $source.Contains("Play-SafeSyncNotificationSound 'BackupComplete'") -and $source.Contains("Play-SafeSyncNotificationSound 'BackupError'")) 'Notification sound settings are not connected to every notification type.'
Assert-Test ($source.Contains('x:Name="ThemeLightRadio"') -and $source.Contains('x:Name="ThemeDarkRadio"') -and $source.Contains('ThemeMode') -and $source.Contains('Apply-SafeSyncTheme')) 'Light/dark mode is missing from the settings window.'
Assert-Test ($source.Contains('SafeSyncHeadingBrush') -and $source.Contains('PART_LeftHeaderGripper') -and $source.Contains('PART_RightHeaderGripper') -and $source.Contains('VerticalGridLinesBrush')) 'Theme-aware data-grid headers and resize separators are missing.'
Assert-Test ($source.Contains('x:Name="CheckMark"') -and $source.Contains('TargetType="{x:Type ScrollBar}"') -and $source.Contains('TargetType="{x:Type Button}"')) 'Dark-mode checkbox, scrollbar, or button templates are missing.'
Assert-Test ($source.Contains('Style x:Key="MenuHeaderItem"') -and $source.Contains('Property="MinWidth" Value="124"') -and -not $source.Contains('Property="Width" Value="152"')) 'The compact desktop menu style is missing.'
Assert-Test ($source.Contains('SafeSyncMenuBorderBrush') -and $source.Contains('MenuBorder =')) 'The menu popup border is not theme-aware.'
$viewMenuIndex=$source.IndexOf('x:Name="MenuProgressItem"')
$trashMenuIndex=$source.IndexOf('x:Name="TrashButton"')
$toolsMenuIndex=$source.IndexOf('x:Name="SettingsButton"')
Assert-Test ($viewMenuIndex -ge 0 -and $trashMenuIndex -gt $viewMenuIndex -and $toolsMenuIndex -gt $trashMenuIndex) 'The trash browser is not grouped under the View menu.'
Assert-Test (-not $source.Contains('x:Name="VersionText"')) 'Program information is still duplicated in settings.'
Assert-Test ($source.Contains('ResizeMode="CanResize"') -and $source.Contains('x:Name="MainLayoutSplitter"') -and $source.Contains('x:Name="ProgressLayoutSplitter"')) 'The settings layout or resizable pane splitters are missing.'
Assert-Test ($source.Contains('MinWidth="800"') -and $source.Contains('MainActivityRow" Height="155" MinHeight="56"') -and $source.Contains('<RowDefinition Height="26"/>')) 'The main-window minimum width, activity pane, or footer reservation is incorrect.'
Assert-Test ($source.Contains('WindowLayout') -and $source.Contains('Save-SafeSyncWindowLayout') -and $source.Contains('MainActivityHeight') -and $source.Contains('ProgressLockedHeight')) 'Window sizes and pane heights are not persisted.'
Assert-Test ($source.Contains("WindowState -ne [System.Windows.WindowState]::Minimized")) 'Minimized-window popup suppression is missing.'
Assert-Test ($source.Contains("notification-state.json")) 'Issue deduplication is not persisted across restarts.'
Assert-Test (-not $source.Contains("BalloonTipTitle='SafeSync 확인 필요'")) 'A minimized error still creates a popup balloon instead of only changing the icon.'
Assert-Test ($source.Contains('x:Name="ProgressLockedGrid"') -and $source.Contains('x:Name="RetryLockedButton"')) 'The app has no in-use file list or retry control.'
Assert-Test ($source.Contains('function Invoke-SafeSyncLockedRetries') -and $source.Contains('function Start-SafeSyncLockedRetry') -and $source.Contains('Start-BackupProcess $Job')) 'In-use files are not retried automatically.'
Assert-Test ($source.Contains('$lockedResultCount -eq 0') -and -not $source.Contains('LockedFiles=[string[]]$newErrors')) 'An in-use file can still create a tray balloon or ordinary error notice.'
Assert-Test ($source.Contains('function Remove-SafeSyncLockedFileErrors') -and $source.Contains('Test-SafeSyncFileInUseError $message') -and $source.Contains("'CompletedWithLockedFiles'")) 'Locked-file errors are not removed before ordinary notifications.'

$script:Window=New-Object Windows.Window
$script:Window.Width=400;$script:Window.Height=300;$script:Window.Left=-9000;$script:Window.Top=-9000;$script:Window.ShowActivated=$false
$script:ProgressWindow=New-Object Windows.Window
$script:ProgressWindow.Width=430;$script:ProgressWindow.Height=280;$script:ProgressWindow.MinHeight=210;$script:ProgressWindow.ShowActivated=$false
$script:PositioningProgressWindow=$false
$script:ProgressWindowPlaced=$false
$script:Window.Show();$script:Window.UpdateLayout()
try{
    Sync-ProgressWindowPlacement
    Assert-Test $script:ProgressWindowPlaced 'Initial progress window placement was not recorded.'
    $script:ProgressWindow.Left=-7000;$script:ProgressWindow.Top=-6000
    Sync-ProgressWindowPlacement
    Assert-Test ($script:ProgressWindow.Left -eq -7000 -and $script:ProgressWindow.Top -eq -6000) 'Progress window was forced back after a user move.'
}finally{$script:ProgressWindow.Close();$script:Window.Close()}

# Reproduce the WPF re-entry that previously raised "VisualTarget root Visual
# cannot have a parent": IsVisibleChanged calls the visibility helper again
# while the first Show() is still pumping messages.
$transitionNode=@($ast.FindAll({param($node)$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-SafeSyncProgressWindowVisibility'},$true))[0]
Invoke-Expression $transitionNode.Extent.Text
function Update-SafeSyncProgressButton {}
$script:ProgressWindow=New-Object Windows.Window
$script:ProgressWindow.ShowActivated=$false
$script:ProgressWindowTransitioning=$false
$script:ProgressWindowPlaced=$true
$script:ProgressWindow.Add_IsVisibleChanged({if($script:ProgressWindow.IsVisible){Set-SafeSyncProgressWindowVisibility $true}})
try{
    Set-SafeSyncProgressWindowVisibility $true
    Assert-Test ($script:ProgressWindow.IsVisible -and -not $script:ProgressWindowTransitioning) 'A re-entrant progress-window Show was not serialized.'
    Set-SafeSyncProgressWindowVisibility $false
    Assert-Test (-not $script:ProgressWindow.IsVisible) 'The serialized progress window did not hide.'
}finally{$script:ProgressWindow.Close()}

Write-Host "PASS: $script:Passed UI behavior assertions"
