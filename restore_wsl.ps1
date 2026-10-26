# =============================================================================
#  Restore WSL from backup tar -> import to F: (59GB free)
#  Run in PowerShell
# =============================================================================
#  Situation this fixes:
#    - WSL registry has ZERO registered distros
#    - E:\WSL2\Ubuntu\ext4.vhdx is an orphan (50.6GB, not registered)
#    - F:\ubuntu-backup.tar is a CLEAN backup (6.3GB)
#
#  What this does:
#    1. wsl --shutdown
#    2. wsl --import Ubuntu  F:\WSL2\Ubuntu  F:\ubuntu-backup.tar
#    3. verify registration
#    4. report space
#  It does NOT delete the orphaned E: vhdx - that is a separate opt-in step.
# =============================================================================

$ErrorActionPreference = 'Continue'

$TarPath    = "F:\ubuntu-backup.tar"
$ImportDir  = "F:\WSL2\Ubuntu"
$DistroName = "Ubuntu"
$OrphanVhdx = "E:\WSL2\Ubuntu\ext4.vhdx"

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  Restore WSL -> F: drive" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------
Write-Host "[1] Pre-flight checks" -ForegroundColor Yellow
Write-Host ("-" * 62) -ForegroundColor DarkGray

if (-not (Test-Path $TarPath)) {
    Write-Host ("  ERROR: backup tar not found: {0}" -f $TarPath) -ForegroundColor Red
    Write-Host "  Cannot continue." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}
$tarGB = [math]::Round((Get-Item $TarPath).Length / 1GB, 2)
Write-Host ("  tar found: {0}  ({1} GB)" -f $TarPath, $tarGB) -ForegroundColor Green

$fFree = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='F:'").FreeSpace / 1GB, 1)
Write-Host ("  F: free space: {0} GB" -f $fFree)
if ($fFree -lt 40) {
    Write-Host "  WARNING: F: has less than 40GB free. Import may fail." -ForegroundColor Yellow
}

# existing distros
Write-Host ""
Write-Host "  Currently registered distros:"
$list = wsl -l -q 2>$null
if ($null -eq $list -or ($list -join "").Trim() -eq "") {
    Write-Host "    (none)" -ForegroundColor Gray
} else {
    $list | ForEach-Object { if ($_ -match '\S') { Write-Host ("    " + $_.Trim()) } }
}
Write-Host ""

# ---------------------------------------------------------------------
# Shutdown + import
# ---------------------------------------------------------------------
Write-Host "[2] Shutting down WSL..." -ForegroundColor Yellow
wsl --shutdown
Start-Sleep -Seconds 5
Write-Host "  done" -ForegroundColor Green
Write-Host ""

Write-Host "[3] Importing (this takes a few minutes)..." -ForegroundColor Yellow
Write-Host ("  wsl --import {0} {1} {2}" -f $DistroName, $ImportDir, $TarPath) -ForegroundColor Gray
Write-Host ""

if (-not (Test-Path $ImportDir)) {
    New-Item -ItemType Directory -Path $ImportDir -Force | Out-Null
}

$out = wsl --import $DistroName $ImportDir $TarPath 2>&1
$out | ForEach-Object { Write-Host ("  " + $_) }

# import prints nothing on success
Write-Host ""

# ---------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------
Write-Host "[4] Verify registration" -ForegroundColor Yellow
Write-Host ("-" * 62) -ForegroundColor DarkGray
wsl -l -v
Write-Host ""

$check = wsl -d $DistroName -e bash -lc "echo IMPORT_OK; id; df -h / | tail -1; free -h | grep -i swap" 2>&1
if ($check -match "IMPORT_OK") {
    Write-Host "  WSL IS WORKING" -ForegroundColor Green
    $check | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Gray }
} else {
    Write-Host "  Import verification FAILED" -ForegroundColor Red
    $check | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Red }
}
Write-Host ""

# ---------------------------------------------------------------------
# Optional: delete orphaned VHDX on E:
# ---------------------------------------------------------------------
Write-Host "[5] Orphaned VHDX on E:" -ForegroundColor Yellow
Write-Host ("-" * 62) -ForegroundColor DarkGray

if (Test-Path $OrphanVhdx) {
    $orphGB = [math]::Round((Get-Item $OrphanVhdx).Length / 1GB, 2)
    Write-Host ("  Found: {0}" -f $OrphanVhdx)
    Write-Host ("  Size : {0} GB  (NOT registered - pure waste)" -f $orphGB) -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  WARNING: deleting this frees ${orphGB}GB but is irreversible." -ForegroundColor Yellow
    Write-Host "  It is safe ONLY because F:\ubuntu-backup.tar holds the same data." -ForegroundColor Yellow
    Write-Host ""
    $ans = Read-Host "  Delete orphaned E: vhdx now? (type DELETE to confirm)"
    if ($ans -eq 'DELETE') {
        try {
            Remove-Item -LiteralPath $OrphanVhdx -Force -ErrorAction Stop
            Write-Host ("  Deleted. Freed {0} GB on E:" -f $orphGB) -ForegroundColor Green
            # remove empty dirs
            Remove-Item "E:\WSL2\Ubuntu" -Force -Recurse -ErrorAction SilentlyContinue
        } catch {
            Write-Host ("  FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    } else {
        Write-Host "  skipped - E: stays full" -ForegroundColor Gray
    }
} else {
    Write-Host "  (already gone)" -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------
# Final state
# ---------------------------------------------------------------------
Write-Host "[6] Disk state" -ForegroundColor Yellow
Write-Host ("-" * 62) -ForegroundColor DarkGray
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
        @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
    Format-Table -AutoSize

Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  NEXT: set up the build environment inside WSL" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Enter WSL:        wsl -d Ubuntu" -ForegroundColor White
Write-Host "  2. Run setup:        bash /mnt/e/workbuddyainew/2026-10-26-15-33-38/twrp_tanzanite/post_import_setup.sh" -ForegroundColor White
Write-Host ""
Read-Host "Press Enter to close"
