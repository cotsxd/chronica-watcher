@echo off
setlocal
cd /d "%~dp0"
echo Chronica Discord Watcher GitHub uploader
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\upload-to-github.ps1"
echo.
pause
