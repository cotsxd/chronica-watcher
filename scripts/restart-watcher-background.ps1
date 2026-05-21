$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

& (Join-Path $scriptDir "stop-watcher-background.ps1")
Start-Sleep -Seconds 1
& (Join-Path $scriptDir "run-watcher-hidden.ps1")
