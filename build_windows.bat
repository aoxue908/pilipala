@echo off
setlocal
cd /d "%~dp0"
title Lynxi Windows Build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
if not defined NO_PAUSE pause