<#
.SYNOPSIS
  Builds SmartDimmer.exe from src\ and (optionally) the release zip.

.DESCRIPTION
  Requires AutoHotkey v2 (https://www.autohotkey.com) with its compiler (Ahk2Exe). The compiled exe
  embeds src\SmartDimmerUI.html and src\lib\WebView2Loader.dll and extracts them next to itself on
  first start; nothing else is needed at runtime except the Microsoft Edge WebView2 Runtime.

.PARAMETER Zip
  Also produce dist\SmartDimmer-<version>-win64.zip (exe, README, LICENSE, notices).

.EXAMPLE
  .\build.ps1
  .\build.ps1 -Zip
#>
param(
    [switch]$Zip,
    [string]$AhkDir = "C:\Program Files\AutoHotkey"
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$ahk2exe = Join-Path $AhkDir 'Compiler\Ahk2Exe.exe'
$base    = Join-Path $AhkDir 'v2\AutoHotkey64.exe'
foreach ($p in @($ahk2exe, $base)) { if (-not (Test-Path $p)) { throw "Not found: $p  (install AutoHotkey v2 with the compiler, or pass -AhkDir)" } }

$src  = Join-Path $root 'src\SmartDimmer.ahk'
$icon = Join-Path $root 'assets\SmartDimmer.ico'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$exe  = Join-Path $dist 'SmartDimmer.exe'
if (Test-Path $exe) { Remove-Item $exe -Force }

$version = (Select-String -Path $src -Pattern ';@Ahk2Exe-SetVersion\s+([\d.]+)').Matches[0].Groups[1].Value
Write-Host "Compiling Smart Dimmer $version ..."
& $ahk2exe /in $src /out $exe /icon $icon /base $base /silent verbose | Where-Object { $_ -match 'FileInstall|Successfully|rror' } | ForEach-Object { Write-Host "  $_" }
Start-Sleep -Seconds 1
if (-not (Test-Path $exe)) { throw 'Compilation failed' }

# sanity: both embedded files must be present in the binary
$txt = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($exe))
if (-not $txt.Contains('chrome.webview.postMessage')) { throw 'The UI page was not embedded (FileInstall must start its own line)' }
Write-Host ("Built {0} ({1:N0} bytes)" -f $exe, (Get-Item $exe).Length)

if ($Zip) {
    $short = ($version -split '\.')[0..2] -join '.'
    $zipPath = Join-Path $dist "SmartDimmer-v$short-win64.zip"     # (not $zip: that is the switch parameter)
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    $stage = Join-Path $dist 'stage'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item $exe $stage
    Copy-Item (Join-Path $root 'README.md') $stage
    Copy-Item (Join-Path $root 'LICENSE') $stage
    Copy-Item (Join-Path $root 'THIRD_PARTY_NOTICES.md') $stage
    Copy-Item (Join-Path $root 'docs') (Join-Path $stage 'docs') -Recurse
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath
    Remove-Item $stage -Recurse -Force
    Write-Host ("Release archive: {0} ({1:N0} bytes)" -f $zipPath, (Get-Item $zipPath).Length)
}
