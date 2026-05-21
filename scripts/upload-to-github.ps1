$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
Set-Location $rootDir

Write-Output "Chronica Discord Watcher GitHub uploader"
Write-Output "Project folder: $rootDir"
Write-Output ""

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) {
  throw "Git for Windows is not installed. Install it from https://git-scm.com/download/win, then run this again."
}

& git config --global --add safe.directory $rootDir

if (-not (Test-Path ".git")) {
  Write-Output "Initializing Git repository..."
  & git init
}

$blockedPaths = @(
  "config\.env",
  "config\config.json",
  "data\chronica-watcher.log",
  "data\known-pages.json",
  "data\.chronica-watch-state.json",
  "data\sent-messages.json",
  "dist",
  "archive"
)

Write-Output "Checking private/generated files are ignored..."
foreach ($path in $blockedPaths) {
  if (Test-Path $path) {
    & git check-ignore -q -- $path
    if ($LASTEXITCODE -ne 0) {
      throw "$path is not ignored by Git. Stopping so private files are not uploaded."
    }
  }
}

$secretPatterns = @(
  ("discord.com/api/webhooks/" + "150"),
  ("dylanjack" + "coates"),
  ("N7" + "Uqu"),
  "https://discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_-]{40,}",
  "CHRONICA_PASSWORD=.+",
  "CHRONICA_EMAIL=.+"
)

$allowedSecretExampleText = @(
  'CHRONICA_PASSWORD=...',
  'CHRONICA_PASSWORD=your-bot-account-password',
  'CHRONICA_PASSWORD=$Password',
  'CHRONICA_EMAIL=...',
  'CHRONICA_EMAIL=bot-account@example.com',
  'CHRONICA_EMAIL=$Email',
  'DISCORD_WEBHOOK_URL=...',
  'DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/your-webhook-id/your-webhook-token',
  'DISCORD_WEBHOOK_URL=$WebhookUrl'
)

Write-Output "Scanning shareable source files for obvious secrets..."
$scanTargets = @(
  "README.md",
  "SIMPLE-README.md",
  ".gitignore",
  "app",
  "scripts",
  "config\.env.example",
  "config\config.example.json",
  "START HERE.cmd",
  "START BACKGROUND WATCHER.cmd",
  "STOP BACKGROUND WATCHER.cmd",
  "KILL FROZEN WATCHER.cmd",
  "UPLOAD TO GITHUB.cmd"
)

$scanFiles = @()
foreach ($target in $scanTargets) {
  if (-not (Test-Path $target)) { continue }
  $item = Get-Item $target
  if ($item.PSIsContainer) {
    $scanFiles += Get-ChildItem -Path $item.FullName -Recurse -File | Select-Object -ExpandProperty FullName
  } else {
    $scanFiles += $item.FullName
  }
}

foreach ($pattern in $secretPatterns) {
  $matches = Select-String -Path $scanFiles -Pattern $pattern -ErrorAction SilentlyContinue
  $realMatches = @()
  foreach ($match in $matches) {
    $allowed = $false
    foreach ($allowedText in $allowedSecretExampleText) {
      if ($match.Line.Trim() -eq $allowedText -or $match.Line.Contains($allowedText)) {
        $allowed = $true
        break
      }
    }
    if (-not $allowed -and $match.Path -notlike "*upload-to-github.ps1") {
      $realMatches += $match
    }
  }
  if ($realMatches) {
    $realMatches | ForEach-Object { Write-Output "$($_.Path):$($_.LineNumber): $($_.Line)" }
    throw "Possible secret found in shareable source files. Fix it before uploading."
  }
}

& git branch -M main

Write-Output "Adding safe project files..."
& git add .

$staged = & git diff --cached --name-only
if (-not $staged) {
  Write-Output "No new changes to commit."
} else {
  Write-Output "Files staged for GitHub:"
  $staged | ForEach-Object { Write-Output "  $_" }
  Write-Output ""
  & git commit -m "Initial Chronica Discord Watcher release"
}

$remoteUrl = Read-Host "Paste the GitHub repository URL, for example https://github.com/your-name/chronica-discord-watcher"
$remoteUrl = $remoteUrl.Trim()
if (-not $remoteUrl -or $remoteUrl -notmatch "^https://github\.com/[^/]+/[^/\s]+/?$|^https://github\.com/[^/]+/[^/\s]+\.git$|^git@github\.com:[^/]+/[^/\s]+\.git$") {
  throw "That does not look like a GitHub repository URL."
}
if ($remoteUrl -match "^https://github\.com/.+/$") {
  $remoteUrl = $remoteUrl.TrimEnd("/")
}
if ($remoteUrl -match "^https://github\.com/.+" -and $remoteUrl -notmatch "\.git$") {
  $remoteUrl = "$remoteUrl.git"
}

$existingRemote = (& git remote 2>$null) -contains "origin"
if ($existingRemote) {
  & git remote set-url origin $remoteUrl
} else {
  & git remote add origin $remoteUrl
}

Write-Output "Pushing to GitHub..."
& git push -u origin main

Write-Output ""
Write-Output "Upload complete."
