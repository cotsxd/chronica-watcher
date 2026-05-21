$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

$runner = Join-Path $scriptDir "run-with-codex-python.ps1"
if (-not (Test-Path $runner)) {
  throw "Could not find scripts\run-with-codex-python.ps1"
}

& $runner --send-intro
