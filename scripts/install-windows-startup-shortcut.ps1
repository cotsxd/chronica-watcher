$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$runner = Join-Path $scriptDir "run-watcher-hidden.ps1"
$startupFolder = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupFolder "Chronica Discord Watcher.lnk"

if (-not (Test-Path $runner)) {
  throw "Could not find $runner"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`""
$shortcut.WorkingDirectory = $rootDir
$shortcut.Description = "Checks Chronica campaign pages and posts updates to Discord."
$shortcut.Save()

Start-Process `
  -FilePath "powershell.exe" `
  -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`"" `
  -WorkingDirectory $rootDir `
  -WindowStyle Hidden

Write-Host "Installed startup shortcut: $shortcutPath"
Write-Host "Started the watcher now."
Write-Host "Logs will appear in: $(Join-Path $rootDir "data\chronica-watcher.log")"
