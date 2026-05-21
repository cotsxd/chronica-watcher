$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$lockPath = Join-Path $rootDir "data\watcher.lock"
$logPath = Join-Path $rootDir "data\chronica-watcher.log"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-WatcherLog {
  param([string]$Message)
  New-Item -ItemType Directory -Force -Path (Join-Path $rootDir "data") | Out-Null
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  [System.IO.File]::AppendAllText($logPath, "[$timestamp] $Message`r`n", $utf8NoBom)
}

if (-not (Test-Path $lockPath)) {
  Write-Host "No background watcher lock was found. It does not look like the watcher is running."
  Write-WatcherLog "Stop requested, but no watcher lock was found."
  exit 0
}

try {
  $lock = Get-Content -Raw $lockPath | ConvertFrom-Json
  $watcherPid = [int]$lock.pid
  $proc = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
  if ($proc) {
    Stop-Process -Id $watcherPid -Force
    Write-Host "Stopped background watcher process $watcherPid."
    Write-WatcherLog "Stopped background watcher process $watcherPid."
  } else {
    Write-Host "The saved watcher process was not running. Removing stale lock."
    Write-WatcherLog "Removed stale watcher lock for missing process $watcherPid."
  }
  Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
} catch {
  Write-Host "Could not stop background watcher: $($_.Exception.Message)"
  Write-WatcherLog "Could not stop background watcher: $($_.Exception.Message)"
  exit 1
}
