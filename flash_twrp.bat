@echo off
REM ============================================================
REM  Flash TWRP vendor_boot for Xiaomi Redmi Note 14 4G (tanzanite)
REM  Usage: flash_twrp.bat [path\to\vendor_boot.img]
REM ============================================================

setlocal enabledelayedexpansion

set "FASTBOOT=F:\Tool RedmiNote14\platform-tools\fastboot.exe"
set "ADB=F:\Tool RedmiNote14\platform-tools\adb.exe"

REM Image path from argument or default
if "%~1"=="" (
    REM Search common locations
    set "IMG="
    if exist "vendor_boot_twrp_tanzanite.img" set "IMG=vendor_boot_twrp_tanzanite.img"
    if not defined IMG if exist "F:\Tool RedmiNote14\vendor_boot_twrp_tanzanite.img" set "IMG=F:\Tool RedmiNote14\vendor_boot_twrp_tanzanite.img"
    if not defined IMG if exist "F:\Tool RedmiNote14\Rom + recovery\vendor_boot_twrp_tanzanite.img" set "IMG=F:\Tool RedmiNote14\Rom + recovery\vendor_boot_twrp_tanzanite.img"
    if not defined IMG (
        echo ERROR: vendor_boot image not found!
        echo.
        echo Usage: %0 ^<path\to\vendor_boot.img^>
        echo.
        echo Download the image from your GitHub Actions run artifacts,
        echo then pass the path to this script.
        exit /b 1
    )
) else (
    set "IMG=%~1"
)

if not exist "%IMG%" (
    echo ERROR: File not found: %IMG%
    exit /b 1
)

echo ============================================================
echo   Flash TWRP vendor_boot for tanzanite
echo   Image: %IMG%
echo ============================================================
echo.

REM Check if device is in fastboot
echo Checking for fastboot device...
"%FASTBOOT%" devices | findstr "fastboot" >nul
if errorlevel 1 (
    echo Device not in fastboot mode.
    echo.
    echo Trying adb reboot bootloader...
    "%ADB%" devices | findstr "device recovery" >nul
    if errorlevel 1 (
        echo ERROR: Device not connected via ADB or Fastboot.
        echo.
        echo Manual steps:
        echo   1. Power off phone
        echo   2. Hold Volume Down + Power together
        echo   3. Release when you see the fastboot logo
        echo   4. Run this script again
        exit /b 1
    )
    "%ADB%" reboot bootloader
    echo Waiting for fastboot mode...
    timeout /t 10 /nobreak >nul
)

echo.
echo Fastboot devices:
"%FASTBOOT%" devices

echo.
echo Flashing vendor_boot...
"%FASTBOOT%" flash vendor_boot "%IMG%"
if errorlevel 1 (
    echo.
    echo ERROR: Flash failed!
    pause
    exit /b 1
)

echo.
echo ============================================================
echo   FLASH SUCCESSFUL!
echo ============================================================
echo.
echo Booting to recovery...
"%FASTBOOT%" reboot recovery 2>nul
if errorlevel 1 (
    echo Could not auto-reboot. Manual:
    echo   Hold Volume Up + Power to boot to TWRP
)

echo.
echo If TWRP doesn't boot or has bugs, report back with:
echo   adb shell dmesg ^> dmesg.log
echo   adb shell logcat ^> logcat.log
echo We'll fix bugs together.
pause
