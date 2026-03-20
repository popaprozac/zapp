# Zapp Bootstrap Script (Windows)
# Syncs native framework code to CLI and rebuilds CLI for current platform
# Usage: .\bootstrap.ps1 [-Clean]

param(
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$CliDir = Join-Path $ScriptDir "packages\cli"
$ViteDir = Join-Path $ScriptDir "packages\vite"
$NativeDir = Join-Path $CliDir "native"
$SrcDir = Join-Path $ScriptDir "src"
$VendorDir = Join-Path $ScriptDir "vendor"

Write-Host "[zapp] bootstrapping for Windows..."

# Clean if requested
if ($Clean) {
    Write-Host "[zapp] cleaning build artifacts..."
    $exampleZapp = Join-Path $ScriptDir "example\.zapp"
    $exampleBin = Join-Path $ScriptDir "example\bin"
    if (Test-Path $exampleZapp) { Remove-Item -Recurse -Force $exampleZapp }
    if (Test-Path $exampleBin) { Remove-Item -Recurse -Force $exampleBin }
    Write-Host "[zapp] cleaned"
}

# Sync src/ directory
Write-Host "[zapp] syncing native\src\..."
if (Test-Path "$NativeDir\src") { Remove-Item -Recurse -Force "$NativeDir\src" }
New-Item -ItemType Directory -Force -Path "$NativeDir\src" | Out-Null
Copy-Item -Path "$SrcDir\*" -Destination "$NativeDir\src\" -Recurse -Force

# Clean unwanted directories
$cleanupPaths = @(
    "$NativeDir\src\cli\node_modules",
    "$NativeDir\src\cli\dist",
    "$NativeDir\src\cli\bun.lock",
    "$NativeDir\src\cli\package.json",
    "$NativeDir\src\tools",
    "$NativeDir\src\generated"
)
foreach ($path in $cleanupPaths) {
    if (Test-Path $path) { Remove-Item -Recurse -Force $path }
}

# Run Bun install on packages
Write-Host "[zapp] running Bun install on packages..."
Set-Location $CliDir
bun install
Set-Location $ViteDir
bun install

# Sync vendor/ directory
Write-Host "[zapp] syncing native\vendor\..."
if (Test-Path "$NativeDir\vendor") { Remove-Item -Recurse -Force "$NativeDir\vendor" }
New-Item -ItemType Directory -Force -Path "$NativeDir\vendor" | Out-Null

# Sync quickjs-ng (minimal)
Write-Host "  syncing quickjs-ng..."
$qjsSrc = Join-Path $VendorDir "quickjs-ng"
$qjsDst = Join-Path $NativeDir "vendor\quickjs-ng"
if (Test-Path $qjsSrc) {
    New-Item -ItemType Directory -Force -Path $qjsDst | Out-Null
    $excludeDirs = @(".git", "build", "docs", "test262*")
    $includeExtensions = @("*.c", "*.h", "*.js", "*.txt", "Makefile", "CMakeLists.txt", "*.conf")
    
    Get-ChildItem -Path $qjsSrc -Recurse -File | Where-Object {
        $relPath = $_.FullName.Substring($qjsSrc.Length)
        -not ($excludeDirs | Where-Object { $relPath -like "*\$_*" -or $relPath -like "*/*/\$_/*" })
    } | ForEach-Object {
        $destPath = Join-Path $qjsDst $_.FullName.Substring($qjsSrc.Length + 1)
        $destFolder = Split-Path $destPath -Parent
        if (-not (Test-Path $destFolder)) { New-Item -ItemType Directory -Force -Path $destFolder | Out-Null }
        Copy-Item -Path $_.FullName -Destination $destPath -Force
    }
}

# Sync webview2 (just headers)
Write-Host "  syncing webview2..."
$wvSrc = Join-Path $VendorDir "webview2"
$wvDst = Join-Path $NativeDir "vendor\webview2"
if (Test-Path $wvSrc) {
    New-Item -ItemType Directory -Force -Path $wvDst | Out-Null
    Copy-Item -Path "$wvSrc\*" -Destination $wvDst -Recurse -Force -Exclude ".git"
}

# Ensure git submodules are updated
Write-Host "[zapp] updating git submodules..."
Set-Location $ScriptDir
git submodule update --init --recursive

# Rebuild CLI
Write-Host "[zapp] rebuilding CLI..."
Set-Location $CliDir
bun run build

Write-Host "[zapp] bootstrap complete!"
