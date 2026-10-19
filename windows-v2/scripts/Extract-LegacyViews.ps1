[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$legacy=Join-Path (Split-Path $root -Parent) 'outputs/SafeSync/SafeSync.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($legacy,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join '; ')}
$windows=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.TrimStart().StartsWith('<Window')},$true))
$mapping=@{Main='x:Name="JobsGrid"';Progress='x:Name="ProgressItems"';Settings='x:Name="RetentionBox"';JobEditor='x:Name="DestinationTypeBox"';Trash='x:Name="TrashGrid"'}
$destination=Join-Path $root 'src/SafeSync.App/Views'
[void][IO.Directory]::CreateDirectory($destination)
foreach($key in $mapping.Keys){
    $matches=@($windows | Where-Object {$_.Value.Contains($mapping[$key])})
    if($matches.Count -ne 1){throw "Expected exactly one $key view."}
    [IO.File]::WriteAllText((Join-Path $destination ($key+'.xaml')),$matches[0].Value,[Text.UTF8Encoding]::new($false))
}
'Extracted five WPF views. No PowerShell runtime code is included.'
