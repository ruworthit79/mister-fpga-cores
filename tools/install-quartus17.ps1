<#
  install-quartus17.ps1
  ----------------------------------------------------------------------------
  Installs Intel/Altera Quartus Prime LITE 17.0 + Cyclone V device support -
  the exact toolchain the Quadra 950 MiSTer core is built with (matches the
  MiSTer sys/ framework; no project migration, no IP upgrade).

  What it does:
    1. Downloads the Quartus Lite 17.0 Windows installer + the Cyclone V
       device file (.qdz) into a folder (tries known URLs; falls back to
       manual download if they have moved).
    2. Runs the installer UNATTENDED, installing Quartus + Cyclone V only.
    3. Sets QUARTUS_ROOTDIR and adds quartus\bin64 to your PATH (user scope).

  Usage (from an elevated "Windows PowerShell" - Run as Administrator):
    powershell -ExecutionPolicy Bypass -File .\install-quartus17.ps1

  Options:
    -InstallDir  C:\intelFPGA_lite\17.0      (where Quartus goes)
    -DownloadDir $HOME\Downloads\quartus17   (where installer files go)
    -SkipDownload                            (use files already in DownloadDir)

  NOTE: this is ~5-7 GB of download and needs ~12+ GB free disk. It does NOT
  require an Intel account for the direct-CDN links, but those links can change;
  if a download fails the script tells you exactly what to grab and where to put
  it, then re-run with -SkipDownload.
  ----------------------------------------------------------------------------
#>
[CmdletBinding()]
param(
  [string]$InstallDir  = "C:\intelFPGA_lite\17.0",
  [string]$DownloadDir = "$env:USERPROFILE\Downloads\quartus17",
  [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # faster Invoke-WebRequest

# --- files we need (17.0.0 build 595 = the classic Lite 17.0 release) ---
$Setup = "QuartusLiteSetup-17.0.0.595-windows.exe"
$Dev   = "cyclonev-17.0.0.595.qdz"

# candidate CDN URL bases (tried in order; first that serves a large binary wins)
$Bases = @(
  "https://downloads.intel.com/akdlm/software/acdsinst/17.0std/595/ib_installers",
  "https://downloads.intel.com/akdlm/software/acdsinst/17.0/595/ib_installers",
  "https://download.altera.com/akdlm/software/acdsinst/17.0std/595/ib_installers"
)
$ManualPage = "https://www.intel.com/content/www/us/en/software-kit/669513/intel-quartus-prime-lite-edition-design-software-version-17-0-for-windows.html"

function Get-File($name) {
  $dest = Join-Path $DownloadDir $name
  if ((Test-Path $dest -PathType Leaf) -and ((Get-Item $dest).Length -gt 50MB)) {
    Write-Host "  already have $name ($([math]::Round((Get-Item $dest).Length/1MB)) MB) - skipping"
    return $true
  }
  foreach ($b in $Bases) {
    $url = "$b/$name"
    try {
      Write-Host "  trying $url"
      Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 60
      if ((Get-Item $dest).Length -gt 50MB) { Write-Host "  OK -> $dest"; return $true }
      Remove-Item $dest -ErrorAction SilentlyContinue   # was an error page
    } catch { Write-Host "  (failed: $($_.Exception.Message))" }
  }
  return $false
}

Write-Host "=== Quartus Prime Lite 17.0 + Cyclone V installer helper ===" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

if (-not $SkipDownload) {
  Write-Host "`n[1/3] Downloading (this is several GB)..."
  $okSetup = Get-File $Setup
  $okDev   = Get-File $Dev
  if (-not ($okSetup -and $okDev)) {
    Write-Warning "`nAutomatic download failed (the CDN links have likely moved)."
    Write-Host    "Do this instead, then re-run with -SkipDownload:" -ForegroundColor Yellow
    Write-Host    "  1. Open: $ManualPage"
    Write-Host    "  2. Download the Windows installer '$Setup'"
    Write-Host    "     and the Cyclone V device file '$Dev'."
    Write-Host    "  3. Put BOTH files in: $DownloadDir"
    Write-Host    "  4. Re-run:  powershell -ExecutionPolicy Bypass -File .\install-quartus17.ps1 -SkipDownload"
    try { Start-Process $ManualPage } catch {}
    exit 1
  }
} else {
  Write-Host "`n[1/3] -SkipDownload set; using files in $DownloadDir"
}

$setupPath = Join-Path $DownloadDir $Setup
$devPath   = Join-Path $DownloadDir $Dev
foreach ($f in @($setupPath, $devPath)) {
  if (-not (Test-Path $f)) { Write-Error "Missing $f - download it (see above) and re-run with -SkipDownload"; exit 1 }
}
# The unattended installer picks up device .qdz files that sit next to setup.exe,
# so both being in $DownloadDir is what we want.

Write-Host "`n[2/3] Installing Quartus Lite 17.0 + Cyclone V (unattended)..."
Write-Host "      target: $InstallDir  (this takes a while; no window will pop up)"
$args = "--mode unattended --installdir `"$InstallDir`" --accept_eula 1"
$p = Start-Process -FilePath $setupPath -ArgumentList $args -Wait -PassThru
if ($p.ExitCode -ne 0) { Write-Error "Installer exited with code $($p.ExitCode)."; exit 1 }

Write-Host "`n[3/3] Setting environment (QUARTUS_ROOTDIR + PATH, user scope)..."
$qroot = Join-Path $InstallDir "quartus"
$bin   = Join-Path $qroot "bin64"
[Environment]::SetEnvironmentVariable("QUARTUS_ROOTDIR", $qroot, "User")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$bin*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$bin", "User")
}

$sh = Join-Path $bin "quartus_sh.exe"
Write-Host ""
if (Test-Path $sh) {
  Write-Host "SUCCESS: Quartus is at $qroot" -ForegroundColor Green
  Write-Host "         quartus_sh: $sh"
  Write-Host ""
  Write-Host "Next (open a NEW terminal so PATH refreshes):" -ForegroundColor Cyan
  Write-Host "  cd <your clone of mister-fpga-cores>"
  Write-Host "  build.bat            # -> output_files\Quadra950.rbf"
} else {
  Write-Warning "Install finished but quartus_sh not found at $sh."
  Write-Warning "Check the install log / that Cyclone V was included, or open the GUI once."
}
