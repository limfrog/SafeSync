[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path (Split-Path $root -Parent) 'outputs/SafeSync/SafeSync-icon.png'
$target=Join-Path $root 'artifacts/branding'
[void][IO.Directory]::CreateDirectory($target)
Add-Type -AssemblyName System.Drawing
$original=[Drawing.Image]::FromFile($source)
try {
    foreach($size in @(64,256)){
        $bitmap=[Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $canvas=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $canvas.Clear([Drawing.Color]::Transparent)
            $canvas.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $canvas.DrawImage($original,[Drawing.Rectangle]::new(0,0,$size,$size))
            $bitmap.Save((Join-Path $target ('SafeSync-'+$size+'.png')),[Drawing.Imaging.ImageFormat]::Png)
        } finally {$canvas.Dispose();$bitmap.Dispose()}
    }
} finally {$original.Dispose()}
Get-ChildItem -LiteralPath $target -Filter '*.png' | Select-Object FullName,Length
