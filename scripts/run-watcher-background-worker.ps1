$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

$logPath = Join-Path $rootDir "data\chronica-watcher.log"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-WatcherLog {
  param([string]$Message)
  New-Item -ItemType Directory -Force -Path (Join-Path $rootDir "data") | Out-Null
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  [System.IO.File]::AppendAllText($logPath, "[$timestamp] $Message`r`n", $utf8NoBom)
}

function Get-PythonRunner {
  $bundledPython = "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
  if (Test-Path $bundledPython) {
    return @{ File = $bundledPython; Prefix = @() }
  }
  $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($pythonCommand) {
    return @{ File = $pythonCommand.Source; Prefix = @() }
  }
  $pyCommand = Get-Command py.exe -ErrorAction SilentlyContinue
  if ($pyCommand) {
    return @{ File = $pyCommand.Source; Prefix = @("-3") }
  }
  return $null
}

try {
  Write-WatcherLog "Background worker started."
  $runner = Get-PythonRunner
  if (-not $runner) {
    Write-WatcherLog "Python 3 was not found. Install Python 3 and tick 'Add python.exe to PATH'."
    exit 1
  }

  & $runner.File @($runner.Prefix + @(".\app\chronica_discord_watcher.py", "--verbose"))
  $exitCode = $LASTEXITCODE
  Write-WatcherLog "Chronica watcher exited with code $exitCode."
  exit $exitCode
} catch {
  Write-WatcherLog "Background worker crashed: $($_.Exception.Message)"
  exit 1
}
