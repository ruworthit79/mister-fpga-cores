<#
  install-quartus17.ps1  (v2)
  ----------------------------------------------------------------------------
  Installs Intel/Altera Quartus Prime LITE 17.0 + Cyclone V device support -
  the exact toolchain the Quadra 950 MiSTer core is built with (matches the
  MiSTer sys/ framework; no project migration, no IP upgrade).

  v2 changes:
    * FINDS an already-downloaded installer anywhere under C:\Users (handles the
      case where an elevated run downloaded into the Administrator profile).
    * Correct unattended flags (no --accept_eula; 17.0 auto-accepts in
      unattended mode). Shows a progress bar (--unattendedmodeui minimal).
    * Ensures the Cyclone V .qdz sits next to the installer so it's included.
    * Verifies quartus_sh.exe afterwards and sets QUARTUS_ROOTDIR + PATH.

  Run in an ADMINISTRATOR PowerShell:
    powershell -ExecutionPolicy Bypass -File .\install-quartus17.ps1

  Options:
    -InstallDir     C:\intelFPGA_lite\17.0     (where Quartus goes)
    -DownloadDir    <profile>\Downloads\quartus17  (where to download if needed)
    -GUI            run the installer wizard instead of silent (you click through)
    -ForceDownload  ignore any existing installer and download fresh
  ----------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
  [string]$InstallDir  = "C:\intelFPGA_lite\17.0",
  [string]$DownloadDir = "$env:USERPROFILE\Downloads\quartus17",
  [switch]$GUI,
  [switch]$ForceDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$SetupName = "QuartusLiteSetup-17.0.0.595-windows.exe"
$DevName   = "cyclonev-17.0.0.595.qdz"
$Bases = @(
  "https://downloads.intel.com/akdlm/software/acdsinst/17.0std/595/ib_installers",
  "https://downloads.intel.com/akdlm/software/acdsinst/17.0/595/ib_installers",
  "https://download.altera.com/akdlm/software/acdsinst/17.0std/595/ib_installers"
)
$ManualPage = "https://www.intel.com/content/www/us/en/software-kit/669513/intel-quartus-prime-lite-edition-design-software-version-17-0-for-windows.html"

function Find-Big([string]$pattern, [int]$minMB) {
  $roots = @($DownloadDir, "C:\Users") | Where-Object { Test-Path $_ }
  foreach ($r in $roots) {
    $hit = Get-ChildItem $r -Recurse -Filter $pattern -File -EA SilentlyContinue |
           Where-Object { $_.Length -gt ($minMB * 1MB) } |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($hit) { return $hit }
  }
  return $null
}

function Download-To([string]$name, [string]$dir) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $dest = Join-Path $dir $name
  foreach ($b in $Bases) {
    try {
      Write-Host "  trying $b/$name"
      Invoke-WebRequest -Uri "$b/$name" -OutFile $dest -UseBasicParsing -TimeoutSec 60
      if ((Get-Item $dest).Length -gt 50MB) { return Get-Item $dest }
      Remove-Item $dest -EA SilentlyContinue
    } catch { Write-Host "  (failed: $($_.Exception.Message))" }
  }
  return $null
}

Write-Host "=== Quartus Prime Lite 17.0 + Cyclone V installer (v2) ===" -ForegroundColor Cyan

# --- 1. locate or fetch the setup .exe (~1.6 GB) ---
$exe = $null
if (-not $ForceDownload) { $exe = Find-Big $SetupName 1000 }
if ($exe) { Write-Host ("[1/4] Found installer: {0} ({1} MB)" -f $exe.FullName,[int]($exe.Length/1MB)) }
else {
  Write-Host "[1/4] Downloading installer (~1.6 GB)..."
  $exe = Download-To $SetupName $DownloadDir
  if (-not $exe) {
    Write-Warning "Could not download automatically (Intel/Altera moved the links)."
    Write-Host   "Download '$SetupName' + '$DevName' manually, put BOTH in $DownloadDir, then re-run." -ForegroundColor Yellow
    try { Start-Process $ManualPage } catch {}
    exit 1
  }
}
$work = $exe.DirectoryName

# --- 2. make sure the Cyclone V .qdz is next to the .exe ---
$qdzHere = Join-Path $work $DevName
if (-not (Test-Path $qdzHere)) {
  $qdz = Find-Big $DevName 100
  if ($qdz) { Write-Host "[2/4] Copying Cyclone V device file next to installer"; Copy-Item $qdz.FullName $qdzHere -Force }
  else {
    Write-Host "[2/4] Cyclone V .qdz not found; fetching..."
    $qdz = Download-To $DevName $work
    if (-not $qdz) { Write-Warning "Cyclone V device file missing - the wizard may not offer Cyclone V. Get '$DevName' into $work and re-run." }
  }
} else { Write-Host "[2/4] Cyclone V device file present next to installer." }

# --- 3. install ---
if ($GUI) {
  Write-Host "[3/4] Launching the installer WIZARD - click through it."
  Write-Host "      Set dir to $InstallDir and CHECK 'Cyclone V' on the devices page."
  Start-Process -FilePath $exe.FullName -WorkingDirectory $work -Wait
} else {
  Write-Host "[3/4] Installing unattended into $InstallDir (progress bar appears; be patient)..."
  $p = Start-Process -FilePath $exe.FullName -WorkingDirectory $work `
        -ArgumentList "--mode unattended --unattendedmodeui minimal --installdir `"$InstallDir`"" -Wait -PassThru
  Write-Host "      installer exit code: $($p.ExitCode)"
}

# --- 4. verify + set environment ---
$qroot = Join-Path $InstallDir "quartus"
$bin   = Join-Path $qroot "bin64"
$sh    = Join-Path $bin "quartus_sh.exe"
if (Test-Path $sh) {
  [Environment]::SetEnvironmentVariable("QUARTUS_ROOTDIR", $qroot, "User")
  $up = [Environment]::GetEnvironmentVariable("Path","User")
  if ($up -notlike "*$bin*") { [Environment]::SetEnvironmentVariable("Path", "$up;$bin", "User") }
  Write-Host "`n[4/4] SUCCESS - Quartus at $qroot" -ForegroundColor Green
  Write-Host "      QUARTUS_ROOTDIR + PATH set (user scope)."
  Write-Host "`nNext: open a NEW terminal, cd to your mister-fpga-cores clone, run:  build.bat" -ForegroundColor Cyan
} else {
  Write-Warning "`n[4/4] quartus_sh not found at $sh - the install did not complete."
  Write-Host   "Try the wizard so you can watch it and confirm Cyclone V is checked:" -ForegroundColor Yellow
  Write-Host   "  powershell -ExecutionPolicy Bypass -File .\install-quartus17.ps1 -GUI"
  exit 1
}
