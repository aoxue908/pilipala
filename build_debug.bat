@echo off
chcp 65001 >nul
title Pilipala Fast Debug APK Build Tool
cd /d "%~dp0"

echo ========================================================
echo   Pilipala Fast Debug APK Build Tool [极速调试导出]
echo ========================================================
echo.

set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
set "PATH=%JAVA_HOME%\bin;D:\FlutterSDK\flutter3.19.6\bin;%PATH%"

set "CLEAN_BUILD=0"
set "TARGET_PLATFORM=android-arm64"

rem 解析参数: 支持 clean 或 all [全架构]
if /i "%1"=="clean" set "CLEAN_BUILD=1"
if /i "%2"=="clean" set "CLEAN_BUILD=1"
if /i "%1"=="all" set "TARGET_PLATFORM="
if /i "%2"=="all" set "TARGET_PLATFORM="

if "%CLEAN_BUILD%"=="1" (
    echo [*] 检测到 clean 参数，正在清理旧缓存...
    call flutter clean
    call flutter pub get
) else (
    echo [*] 增量编译模式 [极速构建，保留 Gradle 守护进程与本地编译缓存]
    echo     如需全新全量编译，请运行: build_debug.bat clean
)

echo.
if defined TARGET_PLATFORM (
    echo [*] 正在为主流手机架构 [arm64-v8a] 快速构建 Debug APK...
    echo     如需全架构包，请运行: build_debug.bat all
    call flutter build apk --debug --target-platform %TARGET_PLATFORM%
) else (
    echo [*] 正在构建全架构 Debug APK [universal]...
    call flutter build apk --debug
)

if errorlevel 1 (
    echo.
    echo ========================================================
    echo [BUILD FAILED] 编译失败，请检查上方日志。
    echo ========================================================
) else (
    echo.
    echo ========================================================
    echo [BUILD SUCCESS] 调试包导出成功！
    copy /y "build\app\outputs\flutter-apk\app-debug.apk" "app-debug.apk" >nul 2>nul
    echo 输出路径 1: %CD%\app-debug.apk [项目根目录]
    echo 输出路径 2: %CD%\build\app\outputs\flutter-apk\app-debug.apk
    echo ========================================================
)

echo.
if not defined NO_PAUSE pause