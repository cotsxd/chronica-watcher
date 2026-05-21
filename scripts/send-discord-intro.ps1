$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$envPath = Join-Path $rootDir "config\.env"
$logPath = Join-Path $rootDir "data\chronica-watcher.log"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-WatcherLog {
  param([string]$Message)
  New-Item -ItemType Directory -Force -Path (Join-Path $rootDir "data") | Out-Null
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  [System.IO.File]::AppendAllText($logPath, "[$timestamp] $Message`r`n", $utf8NoBom)
}

$webhook = $null
Get-Content $envPath | ForEach-Object {
  if ($_ -match '^DISCORD_WEBHOOK_URL=(.+)$') {
    $webhook = $matches[1].Trim()
  }
}

if (-not $webhook) {
  Write-WatcherLog "Discord intro message failed: webhook missing."
  exit 1
}

$message = @'
Ahoy, crew! I am the Chronica Updates bot.

I keep an eye on our Chronica campaign pages and post here when something changes, so you do not have to keep checking the site manually.

I will announce things like:
- new characters, places, kinships, and developments
- updates to existing Chronica pages
- a direct link to the page that changed

I only post the update notice and the link, so you can jump into Chronica when you want the full details. If something looks off, blame my tiny clockwork brain and let Phil know.
'@

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $body = @{ content = $message; username = "Chronica Updates" } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri $webhook -Method Post -ContentType "application/json" -Body $body | Out-Null
  Write-WatcherLog "Discord intro message sent."
  exit 0
} catch {
  Write-WatcherLog "Discord intro message failed: $($_.Exception.Message)"
  exit 1
}
