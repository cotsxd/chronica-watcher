$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$lockPath = Join-Path $rootDir "data\watcher.lock"

Write-Output "Chronica Watcher kill switch"
Write-Output "Project folder: $rootDir"

$killed = 0

function Stop-ById {
  param([int]$ProcessId, [string]$Reason)
  if ($ProcessId -le 0) { return }
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $proc) { return }
  try {
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    Write-Output "Stopped process $ProcessId ($($proc.ProcessName)): $Reason"
    $script:killed += 1
  } catch {
    Write-Output "Could not stop process $ProcessId ($($proc.ProcessName)): $($_.Exception.Message)"
  }
}

if (Test-Path $lockPath) {
  try {
    $lock = Get-Content -Raw $lockPath | ConvertFrom-Json
    Stop-ById ([int]$lock.pid) "watcher lock file"
  } catch {
    Write-Output "Could not read watcher lock file: $($_.Exception.Message)"
  }
}

try {
  $escapedRoot = [Regex]::Escape($rootDir)
  $processes = Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
    $_.CommandLine -and
    ($_.CommandLine -match $escapedRoot -or $_.CommandLine -match "chronica_discord_watcher\.py" -or $_.CommandLine -match "chronica_watcher_gui\.ps1")
  }

  foreach ($process in $processes) {
    Stop-ById ([int]$process.ProcessId) "Chronica watcher command line"
  }
} catch {
  Write-Output "Windows would not allow command-line process scanning: $($_.Exception.Message)"
  Write-Output "The lock-file watcher process was still stopped if it was running."
}

if (Test-Path $lockPath) {
  try {
    Remove-Item -LiteralPath $lockPath -Force
    Write-Output "Removed stale watcher lock file."
  } catch {
    Write-Output "Could not remove watcher lock file: $($_.Exception.Message)"
  }
}

Write-Output "Kill switch finished. Processes stopped: $killed"
