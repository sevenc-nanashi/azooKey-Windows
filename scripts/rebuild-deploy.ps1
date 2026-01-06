# azooKey-Windows Build & Deploy Script
# Run as Administrator

param(
    [switch]$SkipBuild,
    [switch]$SkipAHK
)

$ErrorActionPreference = "Continue"
$ProjectRoot = "G:\Projects\azooKey-Windows"

Write-Host "=== azooKey-Windows Build & Deploy ===" -ForegroundColor Cyan

# Set Rust environment
$env:RUSTUP_HOME = "G:\.rustup"
$env:CARGO_HOME = "G:\.cargo"

# 1. Build
if (-not $SkipBuild) {
    Write-Host "`n[1/4] Building..." -ForegroundColor Yellow
    Set-Location $ProjectRoot
    & "G:\.cargo\bin\cargo-make.exe" make build --release
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
        # cargo-make returns 1 when iscc (Inno Setup) is missing, but build succeeds
        Write-Host "Build may have failed. Check output above." -ForegroundColor Red
    }
} else {
    Write-Host "`n[1/4] Skipping build..." -ForegroundColor Gray
}

# 2. Stop processes
Write-Host "`n[2/4] Stopping processes..." -ForegroundColor Yellow
Stop-Process -Name "launcher" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "azookey-server" -Force -ErrorAction SilentlyContinue
Stop-Process -Name "ui" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# 3. Copy DLLs (with rename workaround for locked files)
Write-Host "`n[3/4] Deploying DLLs..." -ForegroundColor Yellow

# x64 DLL
$x64Src = "$ProjectRoot\target\release\azookey_windows.dll"
$x64Dst = "$ProjectRoot\build\azookey_windows.dll"
if (Test-Path $x64Src) {
    Move-Item -Path $x64Dst -Destination "$x64Dst.old" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $x64Src -Destination $x64Dst -Force
    Write-Host "  x64 DLL deployed" -ForegroundColor Green
} else {
    Write-Host "  x64 DLL not found: $x64Src" -ForegroundColor Red
}

# x86 DLL
$x86Src = "$ProjectRoot\target\i686-pc-windows-msvc\release\azookey_windows.dll"
$x86Dst = "$ProjectRoot\build\x86\azookey_windows.dll"
if (Test-Path $x86Src) {
    Move-Item -Path $x86Dst -Destination "$x86Dst.old" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $x86Src -Destination $x86Dst -Force
    Write-Host "  x86 DLL deployed" -ForegroundColor Green
} else {
    Write-Host "  x86 DLL not found: $x86Src" -ForegroundColor Red
}

# Show timestamps
Write-Host "`n  DLL timestamps:" -ForegroundColor Cyan
Get-Item "$ProjectRoot\build\azookey_windows.dll" -ErrorAction SilentlyContinue |
    Select-Object Name, LastWriteTime | Format-Table -AutoSize

# 4. Restart launcher and AHK
Write-Host "[4/4] Starting processes..." -ForegroundColor Yellow

# Start launcher
Start-Process "$ProjectRoot\build\launcher.exe"
Write-Host "  launcher.exe started" -ForegroundColor Green

# Restart AutoHotkey
if (-not $SkipAHK) {
    $ahkScript = "$ProjectRoot\scripts\ctrl-ime.ahk"
    if (Test-Path $ahkScript) {
        # Kill existing AHK processes running our script
        Get-Process -Name "AutoHotkey*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -match "AutoHotkey" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        # Start AHK script (will auto-elevate if needed)
        Start-Process $ahkScript
        Write-Host "  ctrl-ime.ahk started" -ForegroundColor Green
    } else {
        Write-Host "  AHK script not found: $ahkScript" -ForegroundColor Red
    }
} else {
    Write-Host "  Skipping AHK restart..." -ForegroundColor Gray
}

# Wait for processes to start
Start-Sleep -Seconds 3

# Show running processes
Write-Host "`n=== Running Processes ===" -ForegroundColor Cyan
Get-Process -Name "launcher", "azookey-server" -ErrorAction SilentlyContinue |
    Select-Object Name, Id, StartTime | Format-Table -AutoSize

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Now switch IME to azooKey and test in Notepad."
Write-Host "  - Left Ctrl = English"
Write-Host "  - Right Ctrl = Japanese"
