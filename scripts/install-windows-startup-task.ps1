$ErrorActionPreference = "Stop"

$taskName = "Chronica Discord Watcher"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$runner = Join-Path $scriptDir "run-watcher-hidden.ps1"

if (-not (Test-Path $runner)) {
  throw "Could not find $runner"
}

$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`"" `
  -WorkingDirectory $rootDir

$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 5)

Register-ScheduledTask `
  -TaskName $taskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Description "Checks Chronica campaign pages and posts updates to Discord." `
  -Force | Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host "Installed and started: $taskName"
Write-Host "Logs will appear in: $(Join-Path $rootDir "data\chronica-watcher.log")"
