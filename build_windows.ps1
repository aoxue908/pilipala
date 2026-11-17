# Pilipala Windows Desktop Build Script (PowerShell)
[CmdletBinding()]
param (
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

Write-Host '========================================================' -ForegroundColor Cyan
Write-Host '  Pilipala Windows Desktop Build Tool (VS 2026 Ready)' -ForegroundColor Cyan
Write-Host '========================================================' -ForegroundColor Cyan
Write-Host ''

# 1. Setup Flutter SDK PATH
$env:PATH = 'D:\FlutterSDK\flutter3.19.6\bin;' + $env:PATH

# 2. Locate Visual Studio 2026 using vswhere
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Host '[ERROR] vswhere.exe not found! Visual Studio is required.' -ForegroundColor Red
    exit 1
}

$vsDir = & $vswhere -latest -products * -property installationPath
if (-not $vsDir -or -not (Test-Path $vsDir)) {
    Write-Host '[ERROR] Visual Studio installation directory not found!' -ForegroundColor Red
    exit 1
}

$cmakeExe = Join-Path $vsDir 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
if (-not (Test-Path $cmakeExe)) {
    Write-Host "[ERROR] CMake executable not found at: $cmakeExe" -ForegroundColor Red
    Write-Host 'Please ensure [C++ CMake tools for Windows] is installed in Visual Studio Installer.' -ForegroundColor Yellow
    exit 1
}

Write-Host "[*] Detected Visual Studio: $vsDir" -ForegroundColor Green
Write-Host "[*] CMake Path: $cmakeExe" -ForegroundColor Green
Write-Host ''

# 3. Clean cache if requested
if ($Clean) {
    Write-Host '[*] Cleaning previous build cache...' -ForegroundColor Yellow
    & flutter clean
    if (Test-Path 'build\windows') {
        Remove-Item -Path 'build\windows' -Recurse -Force
    }
    & flutter pub get
}

# 4. Resolve dependencies
Write-Host '[*] Resolving Flutter package dependencies...' -ForegroundColor Cyan
& flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host '[ERROR] flutter pub get failed!' -ForegroundColor Red
    exit 1
}

# 5. Generate CMake build configuration
Write-Host ''
Write-Host '[*] Generating CMake project for Visual Studio 18 2026 (x64)...' -ForegroundColor Cyan
& $cmakeExe -S windows -B build\windows\x64 -G 'Visual Studio 18 2026' -A x64
if ($LASTEXITCODE -ne 0) {
    Write-Host '[ERROR] CMake configuration generation failed!' -ForegroundColor Red
    exit 1
}

# 6. Build Release binary
Write-Host ''
Write-Host '[*] Compiling Release application with MSVC x64...' -ForegroundColor Cyan
& $cmakeExe --build build\windows\x64 --config Release
if ($LASTEXITCODE -ne 0) {
    Write-Host '[ERROR] MSVC build failed!' -ForegroundColor Red
    exit 1
}

# 7. Assemble Complete Portable Bundle (DLLs, Assets, Engine)
Write-Host ''
Write-Host '[*] Assembling portable release bundle...' -ForegroundColor Cyan
$outDir = Join-Path $PSScriptRoot 'build\windows\x64\runner\Release'
$dataDir = Join-Path $outDir 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# Copy app.so
if (Test-Path 'build\windows\app.so') {
    Copy-Item 'build\windows\app.so' -Destination (Join-Path $dataDir 'app.so') -Force
}

# Copy flutter_assets
$targetAssets = Join-Path $dataDir 'flutter_assets'
if (Test-Path 'build\flutter_assets') {
    if (Test-Path $targetAssets) { Remove-Item $targetAssets -Recurse -Force }
    Copy-Item 'build\flutter_assets' -Destination $targetAssets -Recurse -Force
}

# Copy icudtl.dat
if (Test-Path 'windows\flutter\ephemeral\icudtl.dat') {
    Copy-Item 'windows\flutter\ephemeral\icudtl.dat' -Destination (Join-Path $dataDir 'icudtl.dat') -Force
}

# Copy flutter_windows.dll
if (Test-Path 'windows\flutter\ephemeral\flutter_windows.dll') {
    Copy-Item 'windows\flutter\ephemeral\flutter_windows.dll' -Destination (Join-Path $outDir 'flutter_windows.dll') -Force
}

# Copy Plugin DLLs
Get-ChildItem -Path 'build\windows\x64\plugins' -Filter '*.dll' -Recurse | Where-Object { $_.FullName -like '*Release*' } | ForEach-Object {
    Copy-Item $_.FullName -Destination $outDir -Force
}

# Copy mpv & ANGLE DLLs
@('build\windows\x64\libmpv', 'build\windows\x64\ANGLE') | ForEach-Object {
    if (Test-Path $_) {
        Get-ChildItem -Path $_ -Filter '*.dll' | ForEach-Object {
            Copy-Item $_.FullName -Destination $outDir -Force
        }
    }
}

# Copy sherpa_onnx engine DLLs
$sherpaPubDir = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.13.8\windows'
if (Test-Path $sherpaPubDir) {
    Get-ChildItem -Path $sherpaPubDir -Filter '*.dll' | ForEach-Object {
        Copy-Item $_.FullName -Destination $outDir -Force
    }
}

$exePath = Join-Path $outDir 'pilipala.exe'

Write-Host ''
Write-Host '========================================================' -ForegroundColor Green
Write-Host '[BUILD SUCCESS] Windows Desktop Application Exported!' -ForegroundColor Green
Write-Host '========================================================' -ForegroundColor Green
Write-Host "Output Directory: $outDir" -ForegroundColor White
Write-Host "Executable Path:  $exePath" -ForegroundColor White
Write-Host ''
Write-Host 'Distribution note:' -ForegroundColor Gray
Write-Host 'The entire Release directory is a self-contained portable application.' -ForegroundColor Gray
Write-Host 'You can directly zip this folder or package it using Inno Setup.' -ForegroundColor Gray
Write-Host '========================================================' -ForegroundColor Green
