@echo off
REM ---------------------------------------------------------------------------
REM  build.bat - compile the Quadra 950 MiSTer core with Intel Quartus on Windows.
REM
REM  Produces a MiSTer-loadable bitstream at output_files\Quadra950.rbf
REM  (GENERATE_RBF_FILE is ON in Quadra950.qsf).
REM
REM  Target board: Superstation One (MiSTer / DE10-Nano compatible,
REM  Cyclone V 5CSEBA6U23I7 - set in sys\sys.tcl).
REM
REM  Requires: Quartus Prime 17.0.x (Standard or Lite). Run this from a normal
REM  Command Prompt; if quartus_sh is not on PATH, either open the "Quartus Prime
REM  <ver> Command Prompt" shortcut (which sets it up) or set QUARTUS_ROOTDIR, e.g.
REM     set QUARTUS_ROOTDIR=C:\intelFPGA\17.0\quartus
REM
REM  Usage:
REM     build.bat            full compile
REM     build.bat clean      remove build artifacts
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"

set PROJECT=Quadra950

if /I "%~1"=="clean" (
	echo Cleaning build artifacts...
	if exist output_files rmdir /s /q output_files
	if exist db rmdir /s /q db
	if exist incremental_db rmdir /s /q incremental_db
	if exist qdb rmdir /s /q qdb
	if exist "%PROJECT%.qws" del /q "%PROJECT%.qws"
	if exist build_id.v del /q build_id.v
	if exist c5_pin_model_dump.txt del /q c5_pin_model_dump.txt
	echo Clean.
	exit /b 0
)

REM Locate quartus_sh: PATH first, then %QUARTUS_ROOTDIR%\bin, then bin64.
set QSH=
where quartus_sh >nul 2>nul && set QSH=quartus_sh
if "%QSH%"=="" if defined QUARTUS_ROOTDIR if exist "%QUARTUS_ROOTDIR%\bin64\quartus_sh.exe" set QSH="%QUARTUS_ROOTDIR%\bin64\quartus_sh.exe"
if "%QSH%"=="" if defined QUARTUS_ROOTDIR if exist "%QUARTUS_ROOTDIR%\bin\quartus_sh.exe"   set QSH="%QUARTUS_ROOTDIR%\bin\quartus_sh.exe"
if "%QSH%"=="" (
	echo ERROR: quartus_sh not found. Install Quartus Prime 17.0.x and either run
	echo        this from the "Quartus Prime Command Prompt" or set QUARTUS_ROOTDIR
	echo        e.g.  set QUARTUS_ROOTDIR=C:\intelFPGA\17.0\quartus
	exit /b 1
)

echo Compiling %PROJECT% (this takes ~15-40 min depending on the machine)...
%QSH% --flow compile %PROJECT%
if errorlevel 1 (
	echo Build failed - check output_files\*.rpt
	exit /b 1
)

if exist "output_files\%PROJECT%.rbf" (
	echo.
	echo SUCCESS: output_files\%PROJECT%.rbf
	echo Deploy: copy it to \media\fat\_Computer\ on the MiSTer SD card.
) else (
	echo Build finished but output_files\%PROJECT%.rbf was not produced.
	echo Check output_files\*.rpt
	exit /b 1
)

endlocal
