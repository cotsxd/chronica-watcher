$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$packageName = "Chronica-Discord-Watcher-Shareable-$stamp"
$distDir = Join-Path $rootDir "dist"
$packageDir = Join-Path $distDir $packageName
$zipPath = Join-Path $distDir "$packageName.zip"

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageDir "app") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageDir "scripts") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $packageDir "config") | Out-Null

Copy-Item -LiteralPath @(
  "START HERE.cmd",
  "START BACKGROUND WATCHER.cmd",
  "STOP BACKGROUND WATCHER.cmd",
  "KILL FROZEN WATCHER.cmd",
  "UPLOAD TO GITHUB.cmd",
  ".gitignore",
  "README.md",
  "SIMPLE-README.md"
) -Destination $packageDir

Copy-Item -LiteralPath @(
  "app\chronica_discord_watcher.py",
  "app\chronica_watcher_gui.ps1"
) -Destination (Join-Path $packageDir "app")

Copy-Item -LiteralPath @(
  "scripts\install-windows-startup-shortcut.ps1",
  "scripts\install-windows-startup-task.ps1",
  "scripts\kill-frozen-watcher.ps1",
  "scripts\restart-watcher-background.ps1",
  "scripts\run-gui.ps1",
  "scripts\run-watcher-background-worker.ps1",
  "scripts\run-watcher-hidden.ps1",
  "scripts\run-with-codex-python.ps1",
  "scripts\send-discord-intro.ps1",
  "scripts\stop-watcher-background.ps1",
  "scripts\uninstall-windows-startup-shortcut.ps1",
  "scripts\uninstall-windows-startup-task.ps1",
  "scripts\upload-to-github.ps1"
) -Destination (Join-Path $packageDir "scripts")

Copy-Item -LiteralPath @(
  "config\.env.example",
  "config\config.example.json"
) -Destination (Join-Path $packageDir "config")

Compress-Archive -LiteralPath $packageDir -DestinationPath $zipPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
  $blocked = $archive.Entries | Where-Object {
    $_.FullName -match "(^|/)(data|archive)(/|$)|config/config\.json|config/\.env$|__pycache__|\.pyc$"
  }
  if ($blocked) {
    throw "Package contains private/generated files: $($blocked.FullName -join ', ')"
  }
} finally {
  $archive.Dispose()
}

Write-Output "Created shareable package:"
Write-Output $zipPath
