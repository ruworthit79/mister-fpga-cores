@echo off
REM ---------------------------------------------------------------------------
REM  install-quartus17.bat - launcher for install-quartus17.ps1
REM  Installs Quartus Prime Lite 17.0 + Cyclone V (the Quadra 950 toolchain).
REM  Double-click this, or run from a Command Prompt. It relaunches itself
REM  elevated (Run as Administrator) and then runs the PowerShell installer.
REM
REM  Pass -SkipDownload if you already downloaded the two installer files:
REM     install-quartus17.bat -SkipDownload
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

REM --- relaunch elevated if not already admin ---
net session >nul 2>&1
if %errorlevel% neq 0 (
	echo Requesting administrator privileges...
	powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
	exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-quartus17.ps1" %*

echo.
echo Done. Open a NEW terminal, cd to your mister-fpga-cores clone, and run build.bat
pause
endlocal
