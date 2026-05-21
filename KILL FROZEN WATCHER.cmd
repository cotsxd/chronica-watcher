@echo off
setlocal
cd /d "%~dp0"
echo Stopping any Chronica Watcher windows and background processes...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\kill-frozen-watcher.ps1"
echo.
echo Kill switch finished. You can close this window.
pause
