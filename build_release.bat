@echo off
chcp 65001 >nul
title Lynxi Release APK Build Tool
cd /d "%~dp0"

echo ========================================================
echo   Lynxi Release APK One-Click Build Tool
echo ========================================================
echo.

if exist "D:\app\talktime\.tools\jdk-17.0.17+10\bin\java.exe" (
    set "JAVA_HOME=D:\app\talktime\.tools\jdk-17.0.17+10"
) else if exist "D:\app\talktime\.tools\zulu17.70.113-ca-jdk17.0.21.0.3-win_x64\bin\java.exe" (
    set "JAVA_HOME=D:\app\talktime\.tools\zulu17.70.113-ca-jdk17.0.21.0.3-win_x64"
) else (
    set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
)
set "PATH=%JAVA_HOME%\bin;D:\FlutterSDK\flutter3.19.6\bin;%PATH%"

set "CLEAN_BUILD=0"
if /i "%1"=="clean" set "CLEAN_BUILD=1"

if "%CLEAN_BUILD%"=="1" (
    echo [1/3] 正在终止后台 Java 与 Gradle 进程...
    taskkill /F /IM java.exe >nul 2>nul
    taskkill /F /IM gradle.exe >nul 2>nul
    echo [2/3] 正在执行 flutter clean 并重新解析依赖...
    call flutter clean
    call flutter pub get
) else (
    echo [1/2] 增量 Release 编译模式 [保留缓存，极速构建]
    echo       若需要全新全量打包，请运行: build_release.bat clean
)

echo [*] 正在构建 Release APK...
call flutter build apk --release

if errorlevel 1 (
    echo.
    echo [*] 增量构建异常，正在自动清理残留资源缓存并重新构建...
    taskkill /F /IM java.exe >nul 2>nul
    taskkill /F /IM gradle.exe >nul 2>nul
    if exist "build\app\intermediates" (
        rmdir /s /q "build\app\intermediates" >nul 2>nul
    )
    echo [*] 正在重试构建 Release APK...
    call flutter build apk --release
)

if errorlevel 1 (
    echo.
    echo ========================================================
    echo [BUILD FAILED] 编译失败，请检查上方日志。
    echo ========================================================
) else (
    echo.
    echo ========================================================
    echo [BUILD SUCCESS] 打包完成！
    copy /y "build\app\outputs\flutter-apk\app-release.apk" "app-release.apk" >nul 2>nul
    echo APK [根目录镜像]: %CD%\app-release.apk
    echo APK [构建目录]:   %CD%\build\app\outputs\flutter-apk\app-release.apk
    echo ========================================================
)

echo.
if not defined NO_PAUSE pause