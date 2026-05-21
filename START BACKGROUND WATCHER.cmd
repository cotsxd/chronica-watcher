@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-watcher-hidden.ps1"
echo.
echo Background watcher launch requested. You can close this window.
pause
