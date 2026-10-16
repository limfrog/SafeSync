[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceImage,
    [Parameter(Mandatory=$true)][string]$Destination
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
if (-not (Test-Path -LiteralPath $SourceImage -PathType Leaf)) { throw "Tray icon source is missing: $SourceImage" }
[void](New-Item -ItemType Directory -Path $Destination -Force)

function Write-PngIco {
    param([System.Drawing.Bitmap]$Bitmap, [string]$Path)
    $stream = $null
    $writer = $null
    $pngStream = $null
    try {
        $pngStream = [System.IO.MemoryStream]::new()
        $Bitmap.Save($pngStream, [System.Drawing.Imaging.ImageFormat]::Png)
        $png = $pngStream.ToArray()
        $stream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($stream)
        $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]1)
        $writer.Write([byte]32); $writer.Write([byte]32); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([UInt16]1); $writer.Write([UInt16]32); $writer.Write([UInt32]$png.Length); $writer.Write([UInt32]22)
        $writer.Write($png); $writer.Flush()
        [System.IO.File]::WriteAllBytes($Path, $stream.ToArray())
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $pngStream) { $pngStream.Dispose() }
    }
}

$source = [System.Drawing.Bitmap]::new([string](Resolve-Path -LiteralPath $SourceImage))
try {
    for ($index = 0; $index -lt 4; $index++) {
        $frame = [System.Drawing.Bitmap]::new(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($frame)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, 32, 32))
            switch ($index) {
                1 { $frame.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                2 { $frame.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                3 { $frame.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
            }
            Write-PngIco -Bitmap $frame -Path (Join-Path $Destination ("SafeSync-Progress-$index.ico"))
        }
        finally { $graphics.Dispose(); $frame.Dispose() }
    }
}
finally { $source.Dispose() }
