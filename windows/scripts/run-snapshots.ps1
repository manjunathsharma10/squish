# Drives a Debug build of Squish through a pass (see DebugSnapshot.cs), then
# prints its log. Used by CI.
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string[]]$Files,
    [string]$Settings = "",
    [string]$Preset = "",
    [string]$Exe = "Squish/bin/Debug/net10.0-windows10.0.19041.0/Squish.exe",
    [string]$Results = "results"
)
$ErrorActionPreference = "Stop"
$snap = Join-Path $Results $Name
$out = Join-Path $snap "output"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$env:SQUISH_SNAPSHOT = (Resolve-Path $snap).Path
$env:SQUISH_OUT = (Resolve-Path $out).Path
$env:SQUISH_FILES = ($Files | ForEach-Object { (Resolve-Path $_).Path }) -join ";"
$env:SQUISH_SETTINGS = $Settings
$env:SQUISH_PRESET = $Preset

$process = Start-Process -FilePath $Exe -PassThru
if (-not $process.WaitForExit(900000)) { $process.Kill(); throw "$Name timed out" }

Write-Host "==== $Name ===="
Get-Content (Join-Path $snap "log.txt")
Get-ChildItem -Recurse $out | Format-Table FullName, Length -AutoSize | Out-String -Width 300 | Write-Host
