@echo off
REM ===========================================================================
REM pull_pstore.bat - ambil log boot gagal (pstore) dari recovery, versi cmd.exe
REM
REM Pakai:  tools\pull_pstore.bat
REM
REM Alur: flash kernel uji -> coba boot recovery (gagal) -> matikan paksa ->
REM       fastboot flash boot boot_halcyon_A17_stok.img ->
REM       fastboot reboot recovery -> jalankan file ini.
REM ===========================================================================
setlocal enabledelayedexpansion

set "ADB=adb"
where adb >nul 2>&1
if errorlevel 1 (
    if exist "F:\Tool RedmiNote14\platform-tools\adb.exe" (
        set "ADB=F:\Tool RedmiNote14\platform-tools\adb.exe"
    ) else (
        echo ERROR: adb tidak ditemukan. Edit ADB= di file ini.
        exit /b 1
    )
)

"%ADB%" devices | findstr /r /c:"device$" >nul
if errorlevel 1 (
    echo Tidak ada perangkat di adb.
    echo.
    echo Kalau masih di fastboot, flash dulu:
    echo   fastboot flash boot boot_halcyon_A17_stok.img
    echo   fastboot reboot recovery
    exit /b 1
)

set "OUT=pstore-%DATE:/=-%-%RANDOM%.log"

echo == perangkat ==
"%ADB%" shell "uname -r"

echo.
echo == salin pstore ke /tmp ==
"%ADB%" shell "if [ -f /system/bin/pstore-dump.sh ]; then sh /system/bin/pstore-dump.sh; fi"
"%ADB%" shell "mount | grep -q ' /sys/fs/pstore ' || mount -t pstore pstore /sys/fs/pstore 2>/dev/null; cat /sys/fs/pstore/console-ramoops-0 > /tmp/pc.log 2>/dev/null; cat /sys/fs/pstore/pmsg-ramoops-0 > /tmp/pm.log 2>/dev/null; ls -l /tmp/pc.log 2>/dev/null"

echo.
echo == tarik ==
"%ADB%" pull /tmp/pc.log "%OUT%" >nul 2>&1
if exist "%OUT%" (
    for %%F in ("%OUT%") do echo   tersimpan: %%~nxF  %%~zF byte
) else (
    echo   /tmp/pc.log tidak ada - coba /tmp/pstore.log
    "%ADB%" pull /tmp/pstore.log "%OUT%" >nul 2>&1
    if exist "%OUT%" (echo   tersimpan: %OUT%) else (echo   pstore KOSONG / sudah dibaca)
)

if exist "%OUT%" (
    echo.
    echo == ringkasan ==
    findstr /i /c:"disagrees about version" /c:"Unknown symbol" /c:"Kernel panic" /c:"Call trace" /c:"Failed to insmod" "%OUT%" | more +0
)

echo.
echo selesai.
endlocal
