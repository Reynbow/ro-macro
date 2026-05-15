# Generates assets/ro-macro-on.ico (green) and ro-macro-off.ico (red): circle + dark outline.
# Run: powershell -ExecutionPolicy Bypass -File tools\gen-ro-icons.ps1 (from ragnarok-spam folder)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$assets = Join-Path $root "assets"
New-Item -ItemType Directory -Force -Path $assets | Out-Null
Add-Type -AssemblyName System.Drawing

function Get-PngBytes([int]$dim, [System.Drawing.Color]$fill, [System.Drawing.Color]$stroke) {
    $bmp = New-Object System.Drawing.Bitmap $dim, $dim, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $sw = [Math]::Max(1, [int]($dim / 14))
    $pad = [Math]::Max($sw + 1, [int]($dim * 0.08))
    $r = $dim - 2 * $pad
    $rect = New-Object System.Drawing.Rectangle $pad, $pad, $r, $r
    $br = New-Object System.Drawing.SolidBrush $fill
    $g.FillEllipse($br, $rect)
    $pen = New-Object System.Drawing.Pen $stroke, ([single]$sw)
    $g.DrawEllipse($pen, $rect)
    $g.Dispose()
    $br.Dispose()
    $pen.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bytes = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()
    return , $bytes
}

function Write-MultiPngIco([string]$path, [object[]]$layers) {
    $count = $layers.Count
    $headerSize = 6 + 16 * $count
    [uint32]$offset = [uint32]$headerSize
    $dirMs = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($dirMs)
    $w.Write([uint16]0)
    $w.Write([uint16]1)
    $w.Write([uint16]$count)
    foreach ($layer in $layers) {
        $dim = [int]$layer.Dim
        $png = [byte[]]$layer.Bytes
        if ($dim -ge 256) {
            $bw = [byte]0
            $bh = [byte]0
        }
        else {
            $bw = [byte]$dim
            $bh = [byte]$dim
        }
        $w.Write($bw)
        $w.Write($bh)
        $w.Write([byte]0)
        $w.Write([byte]0)
        $w.Write([uint16]1)
        $w.Write([uint16]32)
        $w.Write([uint32]$png.Length)
        $w.Write([uint32]$offset)
        $offset += [uint32]$png.Length
    }
    $payloadMs = New-Object System.IO.MemoryStream
    foreach ($layer in $layers) {
        $payloadMs.Write($layer.Bytes, 0, $layer.Bytes.Length)
    }
    $w.Flush()
    $out = New-Object byte[] ($dirMs.Length + $payloadMs.Length)
    [Array]::Copy($dirMs.ToArray(), 0, $out, 0, $dirMs.Length)
    [Array]::Copy($payloadMs.ToArray(), 0, $out, $dirMs.Length, $payloadMs.Length)
    $w.Dispose()
    $dirMs.Dispose()
    $payloadMs.Dispose()
    [IO.File]::WriteAllBytes($path, $out)
}

$green = [System.Drawing.Color]::FromArgb(255, 34, 197, 94)
$red = [System.Drawing.Color]::FromArgb(255, 239, 68, 68)
$strokeC = [System.Drawing.Color]::FromArgb(255, 24, 32, 28)
$dims = @(16, 24, 32, 48, 64, 256)
$onLayers = foreach ($d in $dims) {
    [pscustomobject]@{ Dim = $d; Bytes = (Get-PngBytes $d $green $strokeC) }
}
$offLayers = foreach ($d in $dims) {
    [pscustomobject]@{ Dim = $d; Bytes = (Get-PngBytes $d $red $strokeC) }
}
Write-MultiPngIco (Join-Path $assets "ro-macro-on.ico") $onLayers
Write-MultiPngIco (Join-Path $assets "ro-macro-off.ico") $offLayers
Write-Host "Wrote:" (Join-Path $assets "ro-macro-on.ico") (Join-Path $assets "ro-macro-off.ico")
