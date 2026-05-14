$ErrorActionPreference = 'Stop'
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeUser32 {
  [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
  public static extern bool DestroyIcon(IntPtr hIcon);
}
"@
$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root 'assets'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Add-Type -AssemblyName System.Drawing

# Transparent background + simple filled circle with black outline.
function Draw-SimpleDotIcon([System.Drawing.Graphics]$g, [bool]$macrosOn, [float]$w, [float]$h) {
  $cx = $w * 0.5
  $cy = $h * 0.5
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  $rDot = [Math]::Min($w, $h) * 0.34
  $rect = [System.Drawing.RectangleF]::new($cx - $rDot, $cy - $rDot, 2.0 * $rDot, 2.0 * $rDot)

  $fillCol = if ($macrosOn) {
    [System.Drawing.Color]::FromArgb(255, 34, 197, 94)  # green
  } else {
    [System.Drawing.Color]::FromArgb(255, 239, 68, 68)  # red
  }

  $brush = New-Object System.Drawing.SolidBrush $fillCol
  $g.FillEllipse($brush, $rect)
  $brush.Dispose()

  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 0, 0, 0), [single]2.0)
  $g.DrawEllipse($pen, $rect.X, $rect.Y, $rect.Width, $rect.Height)
  $pen.Dispose()
}

function Save-EmblemIcon([string]$path, [bool]$macrosOn) {
  $size = 64
  $bmp = New-Object System.Drawing.Bitmap ($size), ($size)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    Draw-SimpleDotIcon $g $macrosOn ([float]$size) ([float]$size)
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    try {
      $fs = [System.IO.File]::Create($path)
      try {
        $icon.Save($fs)
      }
      finally {
        $fs.Close()
      }
    }
    finally {
      $icon.Dispose()
      [void][NativeUser32]::DestroyIcon($hIcon)
    }
  }
  finally {
    $g.Dispose()
    $bmp.Dispose()
  }
}

$onPath = Join-Path $dir 'ro-macro-on.ico'
$offPath = Join-Path $dir 'ro-macro-off.ico'
Save-EmblemIcon $onPath $true
Save-EmblemIcon $offPath $false
Write-Host "Wrote $onPath"
Write-Host "Wrote $offPath"
