$ErrorActionPreference = "Stop"

$taskName = "Chronica Discord Watcher"

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  Write-Host "Removed: $taskName"
} else {
  Write-Host "No scheduled task named '$taskName' was found."
}
