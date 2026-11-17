@echo off
setlocal
cd /d "%~dp0"
title Pilipala Windows Build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
pause
