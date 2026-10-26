@echo off
REM ============================================================
REM  Move WSL2 Ubuntu to E: drive (free up C: space)
REM  Run this in PowerShell as Admin
REM ============================================================
REM
REM  This script:
REM  1. Exports current WSL2 Ubuntu to E:\WSL2\ubuntu-backup.tar
REM  2. Unregisters the old instance (removes from C:)
REM  3. Imports it to E:\WSL2\Ubuntu-22.04
REM
REM  After this, WSL2 will run from E: drive instead of C:
REM  All your files inside WSL2 will be preserved.
REM ============================================================

echo ============================================================
echo   Move WSL2 Ubuntu from C: to E: drive
echo ============================================================
echo.

REM Step 1: Create destination directory
echo [1/4] Creating E:\WSL2 directory...
mkdir E:\WSL2 2>nul
if not exist E:\WSL2 (
    echo ERROR: Could not create E:\WSL2
    echo Make sure E: drive is accessible.
    pause
    exit /b 1
)

REM Step 2: Shutdown WSL
echo [2/4] Shutting down WSL...
wsl --shutdown
timeout /t 5 /nobreak >nul

REM Step 3: Check what distros exist
echo [3/4] Current WSL distros:
wsl -l -v
echo.

REM Step 4: Export current Ubuntu
echo [4/4] Exporting Ubuntu to E:\WSL2\ubuntu-backup.tar...
echo This will take a few minutes depending on size...
echo.

REM Try common distro names
set DISTRO_NAME=
for /f "tokens=1" %%i in ('wsl -l -q ^| findstr /i "Ubuntu"') do (
    if not defined DISTRO_NAME set DISTRO_NAME=%%i
)

if "%DISTRO_NAME%"=="" (
    echo ERROR: No Ubuntu distro found in WSL.
    echo Please check: wsl -l -v
    pause
    exit /b 1
)

echo Found distro: %DISTRO_NAME%
echo Exporting...
wsl --export %DISTRO_NAME% E:\WSL2\ubuntu-backup.tar

if errorlevel 1 (
    echo ERROR: Export failed!
    pause
    exit /b 1
)

echo Export complete!
echo File size:
dir E:\WSL2\ubuntu-backup.tar | findstr "ubuntu-backup"

echo.
echo Unregistering old instance from C:...
wsl --unregister %DISTRO_NAME%

if errorlevel 1 (
    echo ERROR: Unregister failed!
    echo You can manually import the backup later.
    pause
    exit /b 1
)

echo.
echo Importing to E:\WSL2\Ubuntu-22.04...
wsl --import Ubuntu-22.04 E:\WSL2\Ubuntu-22.04 E:\WSL2\ubuntu-backup.tar

if errorlevel 1 (
    echo ERROR: Import failed!
    echo Backup file is at: E:\WSL2\ubuntu-backup.tar
    echo Try manual import:
    echo   wsl --import Ubuntu-22.04 E:\WSL2\Ubuntu-22.04 E:\WSL2\ubuntu-backup.tar
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   SUCCESS! WSL2 moved to E: drive
echo ============================================================
echo.
echo New location: E:\WSL2\Ubuntu-22.04\
echo.
echo Verify:
wsl -l -v
echo.
echo You can now start WSL with: wsl -d Ubuntu-22.04
echo.
echo The backup tar file is at: E:\WSL2\ubuntu-backup.tar
echo You can delete it once you confirm everything works:
echo   del E:\WSL2\ubuntu-backup.tar
echo.
pause
