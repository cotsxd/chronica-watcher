$ErrorActionPreference = "Stop"

$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupFolder "Chronica Discord Watcher.lnk"

if (Test-Path $shortcutPath) {
  Remove-Item -LiteralPath $shortcutPath -Force
  Write-Host "Removed startup shortcut: $shortcutPath"
} else {
  Write-Host "No Chronica startup shortcut was found."
}
