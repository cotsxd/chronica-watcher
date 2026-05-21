$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

$python = "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if (-not (Test-Path $python)) {
  throw "Could not find bundled Python at $python"
}
$worker = Join-Path $scriptDir "run-watcher-background-worker.ps1"
if (-not (Test-Path $worker)) {
  throw "Could not find background worker at $worker"
}

New-Item -ItemType Directory -Force -Path .\data | Out-Null
$logPath = Join-Path $rootDir "data\chronica-watcher.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::AppendAllText($logPath, "[$timestamp] Starting Chronica watcher background process.`r`n", $utf8NoBom)

Start-Process powershell.exe -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $worker
) -WorkingDirectory $rootDir -WindowStyle Hidden

[System.IO.File]::AppendAllText($logPath, "[$timestamp] Background watcher launched. You can close this GUI now.`r`n", $utf8NoBom)
Write-Output "Background watcher launched. Check Live Log for activity."
exit 0
