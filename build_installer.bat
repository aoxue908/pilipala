@echo off
chcp 65001 >nul
title Lynxi Windows Installer Builder
cd /d "%~dp0"

echo ========================================================
echo   Lynxi Windows Setup Installer Build Tool
echo ========================================================
echo.

set "ISCC="
if exist "C:\Program Files\Inno Setup 7\ISCC.exe" (
    set "ISCC=C:\Program Files\Inno Setup 7\ISCC.exe"
) else if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
    set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
) else if exist "C:\Program Files\Inno Setup 6\ISCC.exe" (
    set "ISCC=C:\Program Files\Inno Setup 6\ISCC.exe"
)

if "%ISCC%"=="" (
    echo [ERROR] Inno Setup compiler (ISCC.exe) not found!
    echo Please install Inno Setup 6 or 7.
    pause
    exit /b 1
)

if not exist "%~dp0build\windows\x64\runner\Release\lynxi.exe" (
    echo [ERROR] Release folder not found!
    echo Expected: %~dp0build\windows\x64\runner\Release\lynxi.exe
    echo Please run build_windows.bat first.
    pause
    exit /b 1
)

echo [*] Compiling Inno Setup Script...
"%ISCC%" "%~dp0windows\installer.iss"

if errorlevel 1 (
    echo.
    echo ========================================================
    echo [BUILD FAILED] Inno Setup compilation failed!
    echo ========================================================
) else (
    echo.
    echo ========================================================
    echo [BUILD SUCCESS] Installer EXE created successfully!
    echo Installer Output: %~dp0Lynxi-Setup-1.0.25-x64.exe
    echo ========================================================
)

echo.
if not defined NO_PAUSE pause