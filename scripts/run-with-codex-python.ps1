$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

$bundledPython = "$env:USERPROFILE\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
if (Test-Path $bundledPython) {
  & $bundledPython .\app\chronica_discord_watcher.py @args
  exit $LASTEXITCODE
}

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($pythonCommand) {
  & $pythonCommand.Source .\app\chronica_discord_watcher.py @args
  exit $LASTEXITCODE
}

$pyCommand = Get-Command py.exe -ErrorAction SilentlyContinue
if ($pyCommand) {
  & $pyCommand.Source -3 .\app\chronica_discord_watcher.py @args
  exit $LASTEXITCODE
}

throw "Could not find Python. Install Python 3 from https://www.python.org/downloads/windows/ and tick 'Add python.exe to PATH'."
