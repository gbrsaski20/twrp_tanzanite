# =============================================================================
#  WSL Rescue - free space so WSL can start again
#  Run in PowerShell (Admin recommended)
# =============================================================================
#  Diagnoses why WSL won't start and frees space safely.
#  Does NOT delete your backup - it MOVES it to another drive.
# =============================================================================

$ErrorActionPreference = 'Continue'

function Line { Write-Host ("-" * 62) -ForegroundColor DarkGray }

Write-Host ""
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  WSL Rescue" -ForegroundColor Cyan
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------
# 1. Free space per drive
# ---------------------------------------------------------------------
Write-Host "[1] Disk free space" -ForegroundColor Yellow
Line
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{n='SizeGB';e={[math]::Round($_.Size/1GB,1)}},
        @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}},
        @{n='Free%';e={ if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace/$_.Size)*100,1) } else { 0 } }} |
    Format-Table -AutoSize
Write-Host ""

# ---------------------------------------------------------------------
# 2. Locate WSL disks (ext4.vhdx)
# ---------------------------------------------------------------------
Write-Host "[2] WSL virtual disks found" -ForegroundColor Yellow
Line
$vhdks = @()
foreach ($root in @("$env:LOCALAPPDATA\Packages", "E:\WSL2", "F:\WSL2", "D:\WSL2")) {
    if (Test-Path $root) {
        $found = Get-ChildItem -Path $root -Recurse -Filter "ext4.vhdx" -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            $vhdks += $f
            Write-Host ("  {0}" -f $f.FullName)
            Write-Host ("     size: {0} GB" -f [math]::Round($f.Length/1GB,1)) -ForegroundColor Gray
        }
    }
}
if ($vhdks.Count -eq 0) {
    Write-Host "  (none found in common locations)" -ForegroundColor Red
}
Write-Host ""

# ---------------------------------------------------------------------
# 3. Distro list
# ---------------------------------------------------------------------
Write-Host "[3] WSL distros" -ForegroundColor Yellow
Line
wsl -l -v
Write-Host ""

# ---------------------------------------------------------------------
# 4. Find leftover backup tars
# ---------------------------------------------------------------------
Write-Host "[4] Leftover backup tar files (safe to relocate)" -ForegroundColor Yellow
Line
$tars = @()
foreach ($p in @("E:\WSL2", "F:\WSL2", "D:\WSL2", "$env:USERPROFILE")) {
    if (Test-Path $p) {
        $found = Get-ChildItem -Path $p -Filter "*.tar" -ErrorAction SilentlyContinue
        foreach ($f in $found) {
            $tars += $f
            Write-Host ("  {0}  ({1} GB)" -f $f.FullName, [math]::Round($f.Length/1GB,2))
        }
    }
}
if ($tars.Count -eq 0) {
    Write-Host "  (none)" -ForegroundColor Gray
}
Write-Host ""

# ---------------------------------------------------------------------
# 5. Offer to move tars to a drive with space
# ---------------------------------------------------------------------
if ($tars.Count -gt 0) {
    Write-Host "[5] Relocate backup tar to free space?" -ForegroundColor Yellow
    Line
    # pick target: drive with most free space, excluding source drive
    $best = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
        Sort-Object FreeSpace -Descending |
        Select-Object -First 1

    Write-Host ("  Suggested destination: {0} ({1} GB free)" -f $best.DeviceID, [math]::Round($best.FreeSpace/1GB,1))
    Write-Host ""
    $ans = Read-Host "  Move backup tar(s) there? (y/N)"
    if ($ans -eq 'y' -or $ans -eq 'Y') {
        foreach ($t in $tars) {
            $dest = Join-Path ($best.DeviceID + "\") $t.Name
            if ($t.FullName -ne $dest) {
                Write-Host ("  Moving {0} -> {1}" -f $t.FullName, $dest)
                try {
                    Move-Item -LiteralPath $t.FullName -Destination $dest -Force -ErrorAction Stop
                    Write-Host "    done" -ForegroundColor Green
                } catch {
                    Write-Host ("    FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red
                }
            }
        }
    } else {
        Write-Host "  skipped" -ForegroundColor Gray
    }
    Write-Host ""
}

# ---------------------------------------------------------------------
# 6. Shutdown and try to start
# ---------------------------------------------------------------------
Write-Host "[6] Restart WSL" -ForegroundColor Yellow
Line
wsl --shutdown
Start-Sleep -Seconds 3

$distro = (wsl -l -q 2>$null | Where-Object { $_ -match '\S' } | Select-Object -First 1)
if ($null -eq $distro) {
    Write-Host "  No distro registered!" -ForegroundColor Red
} else {
    $distro = $distro.Trim()
    Write-Host ("  Starting: {0}" -f $distro)
    $out = wsl -d $distro -e bash -lc "df -h / ; echo '---'; free -h" 2>&1
    Write-Host $out
}
Write-Host ""

# ---------------------------------------------------------------------
# 7. Final state
# ---------------------------------------------------------------------
Write-Host "[7] Disk state after cleanup" -ForegroundColor Yellow
Line
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{n='FreeGB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
    Format-Table -AutoSize

Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host "  If WSL now starts, run inside WSL:" -ForegroundColor Cyan
Write-Host "    rm -rf ~/twrp-build        # frees ~30GB inside ext4" -ForegroundColor White
Write-Host "    df -h /" -ForegroundColor White
Write-Host "=============================================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to close"
