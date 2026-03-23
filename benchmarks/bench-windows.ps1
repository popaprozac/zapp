param(
    [int]$Runs = 10
)

$ErrorActionPreference = "Continue"
$BenchDir = $PSScriptRoot

function Measure-App {
    param(
        [string]$Name,
        [string]$Binary,
        [string]$ProcessName,
        [int]$Runs = 10,
        [int]$SleepMs = 500
    )

    if (-not (Test-Path $Binary)) {
        Write-Host "  ${Name}: binary not found (${Binary})" -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host "--- $Name ---" -ForegroundColor Cyan

    # Binary size
    $size = (Get-Item $Binary).Length
    if ($size -ge 1MB) {
        $sizeFmt = "{0:N1} MB" -f ($size / 1MB)
    } else {
        $sizeFmt = "{0:N0} KB" -f ($size / 1KB)
    }
    Write-Host "  Binary: ${sizeFmt} (${size} bytes)"

    # Startup time
    $times = @()
    for ($i = 1; $i -le $Runs; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $Binary -PassThru -WindowStyle Normal
        Start-Sleep -Milliseconds $SleepMs
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds

        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Get-Process | Where-Object { $_.ProcessName -eq $ProcessName } | Stop-Process -Force -ErrorAction SilentlyContinue
        } catch {}
        Start-Sleep -Milliseconds 300
    }

    $sorted = $times | Sort-Object
    $median = $sorted[[math]::Floor($Runs / 2)]
    Write-Host "  Startup: ${median} ms (median of ${Runs})"

    # Memory
    $proc = Start-Process -FilePath $Binary -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 2
    try {
        $proc.Refresh()
        $ws = [math]::Round($proc.WorkingSet64 / 1MB, 1)
        $pm = [math]::Round($proc.PrivateMemorySize64 / 1MB, 1)
        Write-Host "  Working Set: ${ws} MB | Private: ${pm} MB"
    } catch {
        Write-Host "  Memory - could not measure"
    }
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Get-Process | Where-Object { $_.ProcessName -eq $ProcessName } | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}
    Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "=== Windows Benchmark Suite ===" -ForegroundColor Cyan
Write-Host "Runs: ${Runs} | Sleep: 500ms"
Write-Host ""

# --- Zapp ---
Measure-App -Name "Zapp (no workers)" `
    -Binary (Join-Path $BenchDir "hello-world\bin\hello-world.exe") `
    -ProcessName "hello-world" `
    -Runs $Runs

# --- Tauri ---
Measure-App -Name "Tauri v2" `
    -Binary (Join-Path $BenchDir "competitors\tauri\hello-world\src-tauri\target\release\hello-world.exe") `
    -ProcessName "hello-world" `
    -Runs $Runs

# --- Wails ---
Measure-App -Name "Wails v3" `
    -Binary (Join-Path $BenchDir "competitors\wails\hello-world\bin\hello-world.exe") `
    -ProcessName "hello-world" `
    -Runs $Runs

# --- Electron ---
$electronBin = Join-Path $BenchDir "competitors\electron\hello-world\dist\win-unpacked\hello-world.exe"
if (Test-Path $electronBin) {
    $electronDir = Split-Path $electronBin -Parent
    $totalSize = (Get-ChildItem -Path $electronDir -Recurse | Measure-Object -Property Length -Sum).Sum
    $totalMB = [math]::Round($totalSize / 1MB, 1)
    Write-Host ""
    Write-Host "--- Electron ---" -ForegroundColor Cyan
    Write-Host "  App dir: ${totalMB} MB (unpacked)"
}
Measure-App -Name "Electron" `
    -Binary $electronBin `
    -ProcessName "hello-world" `
    -Runs $Runs `
    -SleepMs 1000

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
