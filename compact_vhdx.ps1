# =============================================================================
#  Compact WSL ext4.vhdx - reclaim host disk space after deleting files
#  Run in PowerShell as ADMIN
# =============================================================================
#  Why: the VHDX file only grows, never shrinks on its own. After you delete
#  ~30GB of source inside WSL, the file is still 50GB on disk until compacted.
#
#  Steps this script does:
#    1. wsl --shutdown
#    2. locate ext4.vhdx
#    3. diskpart: attach vdisk readonly, compact vdisk, detach
# =============================================================================

$ErrorActionPreference = 'Continue'

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  Compact WSL VHDX" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""

# Admin check
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "ERROR: This must run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell -> Run as administrator" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

# ---------------------------------------------------------------------
# 1. Shutdown WSL
# ---------------------------------------------------------------------
Write-Host "[1] Shutting down WSL..." -ForegroundColor Yellow
wsl --shutdown
Start-Sleep -Seconds 5
Write-Host "  done" -ForegroundColor Green
Write-Host ""

# ---------------------------------------------------------------------
# 2. Locate the VHDX
# ---------------------------------------------------------------------
Write-Host "[2] Locating ext4.vhdx..." -ForegroundColor Yellow

$candidates = @()
foreach ($root in @("E:\WSL2", "F:\WSL2", "D:\WSL2", "$env:LOCALAPPDATA\Packages")) {
    if (Test-Path $root) {
        $candidates += Get-ChildItem -Path $root -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
    }
}

if ($candidates.Count -eq 0) {
    Write-Host "  No ext4.vhdx found." -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

if ($candidates.Count -eq 1) {
    $vhdx = $candidates[0]
    Write-Host ("  Found: {0}" -f $vhdx.FullName)
    Write-Host ("  Size before: {0} GB" -f [math]::Round($vhdx.Length/1GB,2))
} else {
    Write-Host "  Multiple VHDX files found:"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("    [{0}] {1}  ({2} GB)" -f $i, $candidates[$i].FullName, [math]::Round($candidates[$i].Length/1GB,2))
    }
    $sel = Read-Host "  Select number"
    $vhdx = $candidates[[int]$sel]
}
Write-Host ""

$beforeGB = [math]::Round($vhdx.Length/1GB, 2)
$vhdxPath = $vhdx.FullName

# ---------------------------------------------------------------------
# 3. Compact with diskpart
# ---------------------------------------------------------------------
Write-Host "[3] Compacting (this can take several minutes)..." -ForegroundColor Yellow
Write-Host ""

$dpScript = @"
select vdisk file="$vhdxPath"
attach vdisk readonly
compact vdisk
detach vdisk
exit
"@

$tmp = Join-Path $env:TEMP "wsl_compact.txt"
$dpScript | Out-File -FilePath $tmp -Encoding ASCII -Force

$dpOut = & diskpart /s $tmp 2>&1
$dpOut | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Gray }

Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Write-Host ""

# ---------------------------------------------------------------------
# 4. Result
# ---------------------------------------------------------------------
Write-Host "[4] Result" -ForegroundColor Yellow
$after = Get-Item -LiteralPath $vhdxPath -ErrorAction SilentlyContinue
if ($null -ne $after) {
    $afterGB = [math]::Round($after.Length/1GB, 2)
    $saved = [math]::Round($beforeGB - $afterGB, 2)
    Write-Host ("  Before : {0} GB" -f $beforeGB)
    Write-Host ("  After  : {0} GB" -f $afterGB) -ForegroundColor Green
    Write-Host ("  Saved  : {0} GB" -f $saved) -ForegroundColor Green
} else {
    Write-Host "  Could not stat file after compact." -ForegroundColor Red
}
Write-Host ""

Write-Host "[5] Free space now" -ForegroundColor Yellow
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
    Format-Table -AutoSize

Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  Next: start WSL" -ForegroundColor Cyan
Write-Host "    wsl -d Ubuntu" -ForegroundColor White
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to close"
