$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$gui = Join-Path $rootDir "app\chronica_watcher_gui.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gui
