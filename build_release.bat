@echo off
chcp 65001 >nul
title Pilipala Release APK Build Tool
cd /d "%~dp0"

echo ========================================================
echo   Pilipala Release APK One-Click Build Tool
echo ========================================================
echo.

set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
set "PATH=%JAVA_HOME%\bin;D:\FlutterSDK\flutter3.19.6\bin;%PATH%"

set "CLEAN_BUILD=0"
if /i "%1"=="clean" set "CLEAN_BUILD=1"

if "%CLEAN_BUILD%"=="1" (
    echo [1/3] Stopping background Java and Gradle processes for clean build...
    taskkill /F /IM java.exe >nul 2>nul
    taskkill /F /IM gradle.exe >nul 2>nul
    echo [2/3] Cleaning cache and resolving dependencies...
    call flutter clean
    call flutter pub get
) else (
    echo [1/2] 增量 Release 编译模式 [保留缓存，极速构建]
    echo       若需要全新全量打包，请运行: build_release.bat clean
)

echo [*] Building Release APK...
call flutter build apk --release

if errorlevel 1 (
    echo.
    echo ========================================================
    echo [BUILD FAILED] Please check the error logs above.
    echo ========================================================
) else (
    echo.
    echo ========================================================
    echo [BUILD SUCCESS]
    copy /y "build\app\outputs\flutter-apk\app-release.apk" "app-release.apk" >nul 2>nul
    echo APK [项目根目录]: %CD%\app-release.apk
    echo APK [构建目录]:   %CD%\build\app\outputs\flutter-apk\app-release.apk
    echo ========================================================
)

echo.
if not defined NO_PAUSE pause