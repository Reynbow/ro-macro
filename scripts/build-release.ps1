$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$versionPath = Join-Path $root 'VERSION'
if (-not (Test-Path -LiteralPath $versionPath)) {
    throw "VERSION file missing at $versionPath"
}
$ver = (Get-Content -LiteralPath $versionPath -Raw).Trim()
if ($ver -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must be semver x.y.z (no v prefix). Got: $ver"
}

$iconScript = Join-Path $root 'scripts\make-ro-macro-icon.ps1'
if (Test-Path -LiteralPath $iconScript) {
    Write-Host "Generating tray icons (optional)..."
    try {
        & $iconScript
    } catch {
        Write-Warning "Icon script failed (continuing): $($_.Exception.Message)"
    }
}

function Find-Ahk2Exe {
    $paths = @(
        "${env:ProgramFiles}\AutoHotkey\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles}\AutoHotkey\v2.0\Compiler\Ahk2Exe.exe",
        "${env:ProgramFiles}\AutoHotkey\v2\Compiler\Ahk2Exe.exe",
        "${env:LocalAppData}\Programs\AutoHotkey\Compiler\Ahk2Exe.exe",
        "${env:LocalAppData}\Programs\AutoHotkey\v2\Compiler\Ahk2Exe.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command Ahk2Exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Ahk2Exe.exe not found. Install AutoHotkey v2 from https://www.autohotkey.com/"
}

function Find-AhkBaseBin {
    param([string]$compilerDir)
    $parent = Split-Path $compilerDir -Parent
    $names = @(
        (Join-Path $compilerDir 'AutoHotkey64.bin'),
        (Join-Path $compilerDir 'AutoHotkey64.exe'),
        (Join-Path $parent 'AutoHotkey64.bin'),
        (Join-Path $parent 'AutoHotkey64.exe'),
        (Join-Path $parent 'v2.0\AutoHotkey64.exe')
    )
    foreach ($n in $names) {
        if (Test-Path -LiteralPath $n) { return $n }
    }
    $found = Get-ChildItem -Path $parent -Filter 'AutoHotkey64.bin' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    $found2 = Get-ChildItem -Path $parent -Filter 'AutoHotkey64.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found2) { return $found2.FullName }
    throw "Could not find AutoHotkey64.bin or AutoHotkey64.exe near: $compilerDir"
}

$ahk2 = Find-Ahk2Exe
$compilerDir = Split-Path $ahk2 -Parent
$baseBin = Find-AhkBaseBin $compilerDir

$distRoot = Join-Path $root 'dist'
if (-not (Test-Path -LiteralPath $distRoot)) {
    New-Item -ItemType Directory -Path $distRoot | Out-Null
}

$folderName = "RO-Macro-windows-$ver"
$stage = Join-Path $distRoot $folderName
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage | Out-Null

Copy-Item -LiteralPath (Join-Path $root 'Lib') -Destination (Join-Path $stage 'Lib') -Recurse
Copy-Item -LiteralPath $versionPath -Destination (Join-Path $stage 'VERSION')
foreach ($extra in @('README.md', 'LICENSE')) {
    $p = Join-Path $root $extra
    if (Test-Path -LiteralPath $p) {
        Copy-Item -LiteralPath $p -Destination (Join-Path $stage $extra)
    }
}

$assets = Join-Path $root 'assets'
if (Test-Path -LiteralPath $assets) {
    Copy-Item -LiteralPath $assets -Destination (Join-Path $stage 'assets') -Recurse
}

$in = Join-Path $root 'a-ragnarok.ahk'
$out = Join-Path $stage 'RO-Macro.exe'
$icon = Join-Path $assets 'ro-macro-on.ico'

# Do not use /compress here: it requires MPRESS.exe in the Compiler folder (not shipped with AutoHotkey).
$exeArgs = @('/in', $in, '/out', $out, '/bin', $baseBin)
if (Test-Path -LiteralPath $icon) {
    $exeArgs += @('/icon', $icon)
}

Write-Host "Ahk2Exe: $ahk2"
Write-Host "Base:    $baseBin"
Write-Host "Args:    $($exeArgs -join ' ')"

& $ahk2 @exeArgs
$deadline = (Get-Date).AddSeconds(45)
while (-not (Test-Path -LiteralPath $out) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 150
}
if (-not (Test-Path -LiteralPath $out)) {
    throw "Ahk2Exe did not produce: $out (after wait). Exit code: $LASTEXITCODE"
}

$zipPath = Join-Path $distRoot "$folderName.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Compress-Archive -LiteralPath $stage -DestinationPath $zipPath

Write-Host ""
Write-Host "OK: $out"
Write-Host "OK: $zipPath"
