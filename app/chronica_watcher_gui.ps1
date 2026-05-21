Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $appDir
$scriptDir = Join-Path $rootDir "scripts"
$watcher = Join-Path $appDir "chronica_discord_watcher.py"
$configPath = Join-Path $rootDir "config\config.json"
$envPath = Join-Path $rootDir "config\.env"
$statePath = Join-Path $rootDir "data\.chronica-watch-state.json"
$knownPagesPath = Join-Path $rootDir "data\known-pages.json"
$logPath = Join-Path $rootDir "data\chronica-watcher.log"
$lockPath = Join-Path $rootDir "data\watcher.lock"
$cacheDir = Join-Path $rootDir "data\chronica-page-cache-fresh"
$pauseFile = Join-Path $rootDir "data\notifications-paused.flag"
$sentMessagesPath = Join-Path $rootDir "data\sent-messages.json"
if (Test-Path $configPath) {
  try {
    $configJson = Get-Content -Raw $configPath -Encoding UTF8 | ConvertFrom-Json
    $configuredCacheDir = $configJson.cache_dir
    if ($configuredCacheDir) {
      $cacheDir = Join-Path $rootDir $configuredCacheDir
    }
    if ($configJson.notification_pause_file) {
      $pauseFile = Join-Path $rootDir $configJson.notification_pause_file
    }
    if ($configJson.sent_messages_file) {
      $sentMessagesPath = Join-Path $rootDir $configJson.sent_messages_file
    }
  } catch {}
}
$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Chronica Discord Watcher.lnk"
$python = $null
$pythonPrefix = @()
$script:process = $null
$script:helperProcess = $null
$script:logPosition = 0

$colorBg = [System.Drawing.Color]::FromArgb(245, 247, 250)
$colorPanel = [System.Drawing.Color]::FromArgb(255, 255, 255)
$colorInk = [System.Drawing.Color]::FromArgb(30, 41, 59)
$colorMuted = [System.Drawing.Color]::FromArgb(100, 116, 139)
$colorPrimary = [System.Drawing.Color]::FromArgb(37, 99, 235)
$colorSuccess = [System.Drawing.Color]::FromArgb(22, 163, 74)
$colorWarning = [System.Drawing.Color]::FromArgb(217, 119, 6)
$colorDanger = [System.Drawing.Color]::FromArgb(220, 38, 38)
$colorSoft = [System.Drawing.Color]::FromArgb(226, 232, 240)
$fontUi = New-Object System.Drawing.Font("Segoe UI", 9)
$fontUiBold = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$fontTitle = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
$fontSubtitle = New-Object System.Drawing.Font("Segoe UI", 9)
$fontMono = New-Object System.Drawing.Font("Consolas", 10)

function Ensure-DataFolders {
  New-Item -ItemType Directory -Force -Path (Join-Path $rootDir "data") | Out-Null
  New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
}

function Resolve-PythonRunner {
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

function Append-Output {
  param([string]$Text)
  if ($output.InvokeRequired) {
    $output.BeginInvoke([Action[string]]{ param($value) Append-Output $value }, $Text) | Out-Null
    return
  }
  $output.AppendText($Text)
  $output.SelectionStart = $output.TextLength
  $output.ScrollToCaret()
}

function Set-AppStatus {
  param([string]$Text)
  if ($statusLabel.InvokeRequired) {
    $statusLabel.BeginInvoke([Action[string]]{ param($value) Set-AppStatus $value }, $Text) | Out-Null
    return
  }
  $statusLabel.Text = $Text
  if ($Text -match "Running") {
    $statusLabel.BackColor = $colorPrimary
  } elseif ($Text -match "Missing|failed|error") {
    $statusLabel.BackColor = $colorDanger
  } elseif ($Text -match "Nothing") {
    $statusLabel.BackColor = $colorWarning
  } else {
    $statusLabel.BackColor = $colorSuccess
  }
}

function Get-ConfigText {
  if (Test-Path $configPath) { return Get-Content -Raw $configPath }
  return ""
}

function Save-ConfigText {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($configPath, $configBox.Text, $utf8NoBom)
  Append-Output "Saved config/config.json`r`n"
  Refresh-Dashboard
}

function Get-SecretStatus {
  $result = [ordered]@{
    CHRONICA_EMAIL = "missing"
    CHRONICA_PASSWORD = "missing"
    DISCORD_WEBHOOK_URL = "missing"
  }
  if (-not (Test-Path $envPath)) { return $result }
  Get-Content $envPath | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
      $key = $matches[1].Trim()
      $value = $matches[2].Trim()
      if ($result.Contains($key)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
          $result[$key] = "missing"
        } elseif ($value -match 'your-|bot-account@example.com') {
          $result[$key] = "placeholder?"
        } else {
          $result[$key] = "set"
        }
      }
    }
  }
  return $result
}

function Get-ExistingEnvValue {
  param([string]$Key)
  if (-not (Test-Path $envPath)) { return "" }
  foreach ($line in Get-Content $envPath) {
    if ($line -match "^\s*$([Regex]::Escape($Key))=(.*)$") {
      return $matches[1].Trim().Trim('"').Trim("'")
    }
  }
  return ""
}

function Get-ExistingCampaignId {
  if (-not (Test-Path $configPath)) { return "" }
  try {
    $config = Get-Content -Raw $configPath -Encoding UTF8 | ConvertFrom-Json
    $allText = (($config.watched_urls + $config.allowed_url_patterns) -join "`n")
    if ($allText -match "/campaigns/(\d+)/") {
      return $matches[1]
    }
  } catch {}
  return ""
}

function Test-SetupNeeded {
  if (-not (Test-Path $envPath) -or -not (Test-Path $configPath)) { return $true }
  $secrets = Get-SecretStatus
  if ($secrets.CHRONICA_EMAIL -ne "set" -or $secrets.CHRONICA_PASSWORD -ne "set" -or $secrets.DISCORD_WEBHOOK_URL -ne "set") {
    return $true
  }
  try {
    $configText = Get-Content -Raw $configPath -Encoding UTF8
    if ($configText -match "YOUR_CAMPAIGN_ID") { return $true }
    $config = $configText | ConvertFrom-Json
    if (-not $config.watched_urls -or $config.watched_urls.Count -eq 0) { return $true }
  } catch {
    return $true
  }
  return $false
}

function Normalize-CampaignId {
  param([string]$InputText)
  $value = $InputText.Trim()
  if ($value -match "chronica\.ventures/campaigns/(\d+)") {
    return $matches[1]
  }
  if ($value -match "^\d+$") {
    return $value
  }
  return ""
}

function Write-SetupFiles {
  param(
    [string]$CampaignId,
    [string]$Email,
    [string]$Password,
    [string]$WebhookUrl
  )

  New-Item -ItemType Directory -Force -Path (Join-Path $rootDir "config") | Out-Null
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  $envText = @"
CHRONICA_EMAIL=$Email
CHRONICA_PASSWORD=$Password
DISCORD_WEBHOOK_URL=$WebhookUrl
"@
  [System.IO.File]::WriteAllText($envPath, $envText.TrimEnd() + "`r`n", $utf8NoBom)

  $examplePath = Join-Path $rootDir "config\config.example.json"
  if (Test-Path $examplePath) {
    $configText = Get-Content -Raw $examplePath -Encoding UTF8
  } else {
    $configText = @"
{
  "site_base_url": "https://chronica.ventures",
  "login_url": "https://chronica.ventures/login",
  "sitemap_url": "https://chronica.ventures/sitemap.xml",
  "requires_login": true,
  "watched_urls": [
    "https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/characters",
    "https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/kinships",
    "https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/places",
    "https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/developments"
  ],
  "fallback_urls": [],
  "discover_links_from_watched_pages": true,
  "link_discovery_max_depth": 2,
  "link_discovery_max_pages": 1000,
  "allowed_url_patterns": [
    "/campaigns/YOUR_CAMPAIGN_ID/characters",
    "/campaigns/YOUR_CAMPAIGN_ID/kinships",
    "/campaigns/YOUR_CAMPAIGN_ID/places",
    "/campaigns/YOUR_CAMPAIGN_ID/developments"
  ],
  "check_interval_seconds": 60,
  "state_file": "data/.chronica-watch-state.json",
  "known_pages_file": "data/known-pages.json",
  "lock_file": "data/watcher.lock",
  "cache_dir": "data/chronica-page-cache-fresh",
  "notification_pause_file": "data/notifications-paused.flag",
  "sent_messages_file": "data/sent-messages.json",
  "notify_on_first_seen": false,
  "discord_delay_seconds": 1,
  "discovery_interval_seconds": 300,
  "max_concurrent_checks": 12,
  "ignore_url_patterns": ["/login", "/new($|[/?#])", "/edit($|[/?#])", "/guide($|[/?#])", "/admin", "/settings", "\\?page=", "\\?.*(characterfilter|placefilter|questfilter|tagfilter|folder_id)=", "/update_view_settings"],
  "log_file": "data/chronica-watcher.log",
  "skip_hidden_or_secret_pages": true,
  "ignore_urls": []
}
"@
  }
  $configText = $configText.Replace("YOUR_CAMPAIGN_ID", $CampaignId)
  [System.IO.File]::WriteAllText($configPath, $configText, $utf8NoBom)
}

function Show-SetupWizard {
  param([switch]$FirstRun)

  $wizard = New-Object System.Windows.Forms.Form
  $wizard.Text = "Chronica Watcher Setup"
  $wizard.Size = New-Object System.Drawing.Size(620, 560)
  $wizard.MinimumSize = New-Object System.Drawing.Size(620, 560)
  $wizard.StartPosition = "CenterScreen"
  $wizard.BackColor = $colorBg
  $wizard.Font = $fontUi
  $wizard.FormBorderStyle = "FixedDialog"
  $wizard.MaximizeBox = $false
  $wizard.MinimizeBox = $false

  $title = New-Object System.Windows.Forms.Label
  $title.Text = "Set up Chronica Discord Watcher"
  $title.Location = New-Object System.Drawing.Point(24, 22)
  $title.Size = New-Object System.Drawing.Size(560, 34)
  $title.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 18)
  $title.ForeColor = $colorInk
  $wizard.Controls.Add($title)

  $intro = New-Object System.Windows.Forms.Label
  $intro.Text = "This wizard creates config/.env and config/config.json. Your password and webhook stay on this computer."
  $intro.Location = New-Object System.Drawing.Point(26, 64)
  $intro.Size = New-Object System.Drawing.Size(550, 44)
  $intro.ForeColor = $colorMuted
  $wizard.Controls.Add($intro)

  function Add-WizardLabel {
    param([string]$Text, [int]$Top)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point(30, $Top)
    $label.Size = New-Object System.Drawing.Size(540, 22)
    $label.Font = $fontUiBold
    $label.ForeColor = $colorInk
    $wizard.Controls.Add($label)
  }

  function Add-WizardBox {
    param([int]$Top, [string]$Text = "", [switch]$Password)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(32, $Top)
    $box.Size = New-Object System.Drawing.Size(540, 28)
    $box.Text = $Text
    if ($Password) { $box.UseSystemPasswordChar = $true }
    $wizard.Controls.Add($box)
    return $box
  }

  Add-WizardLabel "Chronica campaign ID or campaign URL" 120
  $campaignBox = Add-WizardBox 146 (Get-ExistingCampaignId)

  Add-WizardLabel "Chronica bot account email" 184
  $emailBox = Add-WizardBox 210 (Get-ExistingEnvValue "CHRONICA_EMAIL")

  Add-WizardLabel "Chronica bot account password" 248
  $passwordBox = Add-WizardBox 274 (Get-ExistingEnvValue "CHRONICA_PASSWORD") -Password

  Add-WizardLabel "Discord webhook URL" 312
  $webhookBox = Add-WizardBox 338 (Get-ExistingEnvValue "DISCORD_WEBHOOK_URL")

  $status = New-Object System.Windows.Forms.Label
  $status.Location = New-Object System.Drawing.Point(32, 380)
  $status.Size = New-Object System.Drawing.Size(540, 48)
  $status.ForeColor = $colorDanger
  $wizard.Controls.Add($status)

  $saveButton = New-Object System.Windows.Forms.Button
  $saveButton.Text = "Save Setup"
  $saveButton.Location = New-Object System.Drawing.Point(324, 448)
  $saveButton.Size = New-Object System.Drawing.Size(120, 38)
  $saveButton.BackColor = $colorSuccess
  $saveButton.ForeColor = [System.Drawing.Color]::White
  $saveButton.FlatStyle = "Flat"
  $saveButton.FlatAppearance.BorderSize = 0
  $saveButton.Font = $fontUiBold
  $wizard.Controls.Add($saveButton)

  $cancelButton = New-Object System.Windows.Forms.Button
  $cancelButton.Text = if ($FirstRun) { "Skip For Now" } else { "Cancel" }
  $cancelButton.Location = New-Object System.Drawing.Point(452, 448)
  $cancelButton.Size = New-Object System.Drawing.Size(120, 38)
  $cancelButton.BackColor = $colorSoft
  $cancelButton.ForeColor = $colorInk
  $cancelButton.FlatStyle = "Flat"
  $cancelButton.FlatAppearance.BorderSize = 0
  $wizard.Controls.Add($cancelButton)

  $script:setupSaved = $false
  $saveButton.Add_Click({
    $campaignId = Normalize-CampaignId $campaignBox.Text
    $email = $emailBox.Text.Trim()
    $password = $passwordBox.Text
    $webhook = $webhookBox.Text.Trim()

    if (-not $campaignId) {
      $status.Text = "Enter the campaign number, or paste a Chronica campaign URL like https://chronica.ventures/campaigns/12345."
      return
    }
    if (-not $email -or $email -notmatch "@") {
      $status.Text = "Enter the Chronica bot account email."
      return
    }
    if (-not $password -or $password -match "your-bot-account-password") {
      $status.Text = "Enter the Chronica bot account password."
      return
    }
    if ($webhook -notmatch "^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/") {
      $status.Text = "Enter a Discord webhook URL from Server Settings > Integrations > Webhooks."
      return
    }

    try {
      Write-SetupFiles $campaignId $email $password $webhook
      $script:setupSaved = $true
      $wizard.DialogResult = [System.Windows.Forms.DialogResult]::OK
      $wizard.Close()
    } catch {
      $status.Text = "Could not save setup: $($_.Exception.Message)"
    }
  })

  $cancelButton.Add_Click({
    $wizard.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $wizard.Close()
  })

  $wizard.AcceptButton = $saveButton
  $wizard.CancelButton = $cancelButton
  $wizard.ShowDialog() | Out-Null
  return $script:setupSaved
}

function Get-KnownPageCount {
  if (-not (Test-Path $knownPagesPath)) { return 0 }
  try {
    $known = Get-Content -Raw $knownPagesPath | ConvertFrom-Json
    if ($known.pages) {
      return ($known.pages.PSObject.Properties | Measure-Object).Count
    }
  } catch {}
  return 0
}

function Get-CacheFileCount {
  if (-not (Test-Path $cacheDir)) { return 0 }
  return (Get-ChildItem -Path $cacheDir -Filter *.txt -ErrorAction SilentlyContinue | Measure-Object).Count
}

function Test-StartupInstalled {
  return Test-Path $startupShortcut
}

function Test-NotificationsPaused {
  return Test-Path $pauseFile
}

function Get-AppConfig {
  if (-not (Test-Path $configPath)) { return $null }
  try {
    return Get-Content -Raw $configPath -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Save-AppConfig {
  param($Config)
  $json = $Config | ConvertTo-Json -Depth 12
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($configPath, $json + "`r`n", $utf8NoBom)
  if ($configBox) { $configBox.Text = Get-ConfigText }
}

function Test-NewPageAnnouncementsEnabled {
  $config = Get-AppConfig
  if (-not $config) { return $false }
  return [bool]$config.notify_on_first_seen
}

function Set-NewPageAnnouncements {
  param([bool]$Enabled)
  $config = Get-AppConfig
  if (-not $config) {
    [System.Windows.Forms.MessageBox]::Show("Run the setup wizard first so config.json exists.", "Missing config") | Out-Null
    return
  }
  $config | Add-Member -NotePropertyName notify_on_first_seen -NotePropertyValue $Enabled -Force
  Save-AppConfig $config
  $state = if ($Enabled) { "enabled" } else { "disabled" }
  Append-Output "New page announcements $state. Restart the background watcher for this to affect an already-running watcher.`r`n"
  Refresh-Dashboard
}

function Pause-Notifications {
  Ensure-DataFolders
  Set-Content -Path $pauseFile -Value "Discord notifications paused from the Chronica Watcher GUI." -Encoding UTF8
  Append-Output "Discord notifications paused. The watcher will still cache changes, but it will not post them.`r`n"
  Refresh-Dashboard
}

function Resume-Notifications {
  if (Test-Path $pauseFile) {
    Remove-Item -LiteralPath $pauseFile -Force
  }
  Append-Output "Discord notifications resumed.`r`n"
  Refresh-Dashboard
}

function Add-IgnoreUrl {
  if (-not $pageTestUrlBox) { return }
  $url = $pageTestUrlBox.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($url)) {
    [System.Windows.Forms.MessageBox]::Show("Paste a Chronica page URL first.", "No page URL") | Out-Null
    return
  }
  try {
    $config = Get-Content -Raw $configPath -Encoding UTF8 | ConvertFrom-Json
    $current = @()
    if ($config.ignore_urls) { $current = @($config.ignore_urls) }
    if ($current -notcontains $url) {
      $current += $url
    }
    $config | Add-Member -NotePropertyName ignore_urls -NotePropertyValue $current -Force
    $json = $config | ConvertTo-Json -Depth 10
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($configPath, $json, $utf8NoBom)
    $configBox.Text = Get-ConfigText
    Append-Output "Added page to ignore list: $url`r`n"
    Refresh-Dashboard
  } catch {
    [System.Windows.Forms.MessageBox]::Show("Could not update ignore list: $($_.Exception.Message)", "Ignore list error") | Out-Null
  }
}

function Test-BackgroundWatcherRunning {
  if (-not (Test-Path $lockPath)) { return $false }
  try {
    $lock = Get-Content -Raw $lockPath | ConvertFrom-Json
    $watcherPid = [int]$lock.pid
    return [bool](Get-Process -Id $watcherPid -ErrorAction SilentlyContinue)
  } catch {
    return $false
  }
}

function Get-BackgroundWatcherInfo {
  $info = [ordered]@{
    Running = $false
    Status = "Not running"
    Pid = "-"
    Started = "-"
    Heartbeat = "-"
  }

  if (-not (Test-Path $lockPath)) {
    return $info
  }

  try {
    $lock = Get-Content -Raw $lockPath | ConvertFrom-Json
    $watcherPid = [int]$lock.pid
    $info.Pid = "$watcherPid"
    if ($lock.started_at) {
      $started = [DateTimeOffset]::FromUnixTimeSeconds([int64]$lock.started_at).LocalDateTime
      $info.Started = $started.ToString("yyyy-MM-dd HH:mm:ss")
    }
    if ($lock.heartbeat_at) {
      $heartbeat = [DateTimeOffset]::FromUnixTimeSeconds([int64]$lock.heartbeat_at).LocalDateTime
      $info.Heartbeat = $heartbeat.ToString("HH:mm:ss")
      $heartbeatAge = ([DateTime]::Now - $heartbeat).TotalSeconds
    } else {
      $heartbeatAge = 999999
    }

    $proc = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
    if ($proc -and $heartbeatAge -le 120) {
      $info.Running = $true
      $info.Status = "Running in background"
    } elseif ($proc) {
      $info.Status = "No recent heartbeat"
    } else {
      $info.Status = "Stale lock found"
    }
  } catch {
    $info.Status = "Status unknown"
  }

  return $info
}

function Refresh-Dashboard {
  $secrets = Get-SecretStatus
  $guiWatcherStatus = if ($script:process -and -not $script:process.HasExited) { "running in this app" } else { "not running in this app" }
  $backgroundInfo = Get-BackgroundWatcherInfo
  $backgroundStatus = $backgroundInfo.Status.ToLowerInvariant()
  $startupStatus = if (Test-StartupInstalled) { "installed" } else { "not installed" }
  $knownPages = Get-KnownPageCount
  $cacheFiles = Get-CacheFileCount
  $lastLog = if (Test-Path $logPath) { (Get-Item $logPath).LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "no log yet" }
  $notificationStatus = if (Test-NotificationsPaused) { "paused" } else { "active" }
  $newPageStatus = if (Test-NewPageAnnouncementsEnabled) { "on" } else { "off" }
  $healthLine = if ($backgroundInfo.Status -match "heartbeat|Stale|unknown") {
    "Health warning: watcher may have stopped. Use Restart Background Watcher."
  } elseif ($backgroundInfo.Running) {
    "Health: watcher is alive."
  } else {
    "Health: watcher is not running."
  }

  if ($script:backgroundStatusLabel) {
    $script:backgroundStatusLabel.Text = $backgroundInfo.Status
    $script:backgroundStatusLabel.BackColor = if ($backgroundInfo.Running) { $colorSuccess } elseif ($backgroundInfo.Status -match "Stale|heartbeat") { $colorWarning } else { $colorDanger }
  }
  if ($script:backgroundPidLabel) { $script:backgroundPidLabel.Text = "Process: $($backgroundInfo.Pid)" }
  if ($script:backgroundPagesLabel) { $script:backgroundPagesLabel.Text = "Watching: $knownPages page(s)" }
  if ($script:backgroundStartedLabel) { $script:backgroundStartedLabel.Text = "Started: $($backgroundInfo.Started) / Last: $($backgroundInfo.Heartbeat)" }
  if ($script:backgroundStartupLabel) { $script:backgroundStartupLabel.Text = "Auto-start: $startupStatus" }
  if ($script:webhookStatusLabel) {
    $webhookStatus = $secrets.DISCORD_WEBHOOK_URL
    $script:webhookStatusLabel.Text = "Webhook: $webhookStatus"
    $script:webhookStatusLabel.ForeColor = if ($webhookStatus -eq "set") { $colorSuccess } elseif ($webhookStatus -eq "missing") { $colorDanger } else { $colorWarning }
  }
  if ($script:notificationStatusLabel) {
    $script:notificationStatusLabel.Text = "Notices: $notificationStatus"
    $script:notificationStatusLabel.ForeColor = if ($notificationStatus -eq "active") { $colorSuccess } else { $colorWarning }
  }
  if ($script:newPageStatusLabel) {
    $script:newPageStatusLabel.Text = "New pages: $newPageStatus"
    $script:newPageStatusLabel.ForeColor = if ($newPageStatus -eq "on") { $colorWarning } else { $colorMuted }
  }
  if ($script:backgroundToggleButton) {
    if ($backgroundInfo.Running) {
      $script:backgroundToggleButton.Text = "Background: On"
      $script:backgroundToggleButton.BackColor = $colorDanger
      $script:backgroundToggleButton.ForeColor = [System.Drawing.Color]::White
    } else {
      $script:backgroundToggleButton.Text = "Background: Off"
      $script:backgroundToggleButton.BackColor = $colorPrimary
      $script:backgroundToggleButton.ForeColor = [System.Drawing.Color]::White
    }
  }
  if ($script:noticesToggleButton) {
    if ($notificationStatus -eq "paused") {
      $script:noticesToggleButton.Text = "Notices: Paused"
      $script:noticesToggleButton.BackColor = $colorSuccess
      $script:noticesToggleButton.ForeColor = [System.Drawing.Color]::White
    } else {
      $script:noticesToggleButton.Text = "Notices: Active"
      $script:noticesToggleButton.BackColor = $colorWarning
      $script:noticesToggleButton.ForeColor = [System.Drawing.Color]::White
    }
  }
  if ($script:newPagesToggleButton) {
    if ($newPageStatus -eq "on") {
      $script:newPagesToggleButton.Text = "New Pages: On"
      $script:newPagesToggleButton.BackColor = $colorSoft
      $script:newPagesToggleButton.ForeColor = $colorInk
    } else {
      $script:newPagesToggleButton.Text = "New Pages: Off"
      $script:newPagesToggleButton.BackColor = $colorWarning
      $script:newPagesToggleButton.ForeColor = [System.Drawing.Color]::White
    }
  }

  $dashboardText.Text = @"
Background watcher: $backgroundStatus
GUI debug watcher: $guiWatcherStatus
Startup shortcut: $startupStatus
Discord notices: $notificationStatus
New page announcements: $newPageStatus
$healthLine
Known pages: $knownPages
Cached page snapshots: $cacheFiles
Last log update: $lastLog

Secrets:
  CHRONICA_EMAIL: $($secrets.CHRONICA_EMAIL)
  CHRONICA_PASSWORD: $($secrets.CHRONICA_PASSWORD)
  DISCORD_WEBHOOK_URL: $($secrets.DISCORD_WEBHOOK_URL)

Important paths:
  Config: $configPath
  Secrets: $envPath
  Log: $logPath
  Cache: $cacheDir
  Known pages: $knownPagesPath
"@
}

function Start-WatcherCommand {
  param([string[]]$ArgsList, [string]$Label = "Watcher command")

  Ensure-DataFolders
  if ($script:process -and -not $script:process.HasExited) {
    [System.Windows.Forms.MessageBox]::Show("Stop the current watcher command before starting another one.", "Already running") | Out-Null
    return
  }
  $runner = Resolve-PythonRunner
  if (-not $runner) {
    [System.Windows.Forms.MessageBox]::Show("Could not find Python 3. Install Python 3 from python.org and tick 'Add python.exe to PATH'.", "Missing Python") | Out-Null
    return
  }

  $arguments = @($runner.Prefix + @("-u", "`"$watcher`"", "--verbose") + $ArgsList)
  Append-Output "`r`n[$(Get-Date -Format 'HH:mm:ss')] $Label`r`n> python $($arguments -join ' ')`r`n"
  Set-AppStatus "Running: $Label"

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $runner.File
  $startInfo.Arguments = $arguments -join " "
  $startInfo.WorkingDirectory = $rootDir
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $script:process = New-Object System.Diagnostics.Process
  $script:process.StartInfo = $startInfo
  $script:process.EnableRaisingEvents = $true

  Register-ObjectEvent -InputObject $script:process -EventName OutputDataReceived -Action {
    if ($EventArgs.Data) { Append-Output "$($EventArgs.Data)`r`n" }
  } | Out-Null

  Register-ObjectEvent -InputObject $script:process -EventName ErrorDataReceived -Action {
    if ($EventArgs.Data) { Append-Output "$($EventArgs.Data)`r`n" }
  } | Out-Null

  Register-ObjectEvent -InputObject $script:process -EventName Exited -Action {
    Append-Output "`r`nCommand finished with exit code $($Event.Sender.ExitCode).`r`n"
    Set-AppStatus "Ready"
    Refresh-Dashboard
  } | Out-Null

  $script:process.Start() | Out-Null
  $script:process.BeginOutputReadLine()
  $script:process.BeginErrorReadLine()
  Refresh-Dashboard
}

function Stop-WatcherCommand {
  if ($script:process -and -not $script:process.HasExited) {
    $script:process.Kill()
    Append-Output "`r`nStopped watcher command.`r`n"
    Set-AppStatus "Ready"
  } else {
    Set-AppStatus "Nothing running"
  }
  Refresh-Dashboard
}

function Stop-BackgroundWatcher {
  Run-ScriptCommand "stop-watcher-background.ps1" "Stop background watcher"
  Refresh-Dashboard
}

function Toggle-BackgroundWatcher {
  $backgroundInfo = Get-BackgroundWatcherInfo
  if ($backgroundInfo.Running) {
    Stop-BackgroundWatcher
  } else {
    Start-BackgroundWatcherScript
  }
}

function Restart-BackgroundWatcher {
  Run-ScriptCommand "restart-watcher-background.ps1" "Restart background watcher"
  Refresh-Dashboard
}

function Toggle-Notifications {
  if (Test-NotificationsPaused) {
    Resume-Notifications
  } else {
    Pause-Notifications
  }
}

function Toggle-NewPageAnnouncements {
  Set-NewPageAnnouncements (-not (Test-NewPageAnnouncementsEnabled))
}

function Run-ScriptCommand {
  param([string]$ScriptName, [string]$Label)
  Select-ToolTab "Debug"
  if ($script:helperProcess -and -not $script:helperProcess.HasExited) {
    Append-Output "`r`nA helper command is already running. Please wait for it to finish.`r`n"
    Set-AppStatus "Helper already running"
    return
  }
  $scriptPath = Join-Path $scriptDir $ScriptName
  if (-not (Test-Path $scriptPath)) {
    Append-Output "`r`n[$(Get-Date -Format 'HH:mm:ss')] $Label`r`nMissing helper script: $scriptPath`r`n"
    Set-AppStatus "Missing helper script"
    return
  }

  $extension = [System.IO.Path]::GetExtension($scriptPath).ToLowerInvariant()
  Append-Output "`r`n[$(Get-Date -Format 'HH:mm:ss')] $Label`r`n> $scriptPath`r`n"
  Set-AppStatus "Running helper: $Label"
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  if ($extension -eq ".cmd" -or $extension -eq ".bat") {
    $startInfo.FileName = "cmd.exe"
    $startInfo.Arguments = "/c `"$scriptPath`""
  } else {
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
  }
  $startInfo.WorkingDirectory = $rootDir
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $script:helperProcess = New-Object System.Diagnostics.Process
  $script:helperProcess.StartInfo = $startInfo
  $script:helperProcess.EnableRaisingEvents = $true

  Register-ObjectEvent -InputObject $script:helperProcess -EventName OutputDataReceived -Action {
    if ($EventArgs.Data) { Append-Output "$($EventArgs.Data)`r`n" }
  } | Out-Null

  Register-ObjectEvent -InputObject $script:helperProcess -EventName ErrorDataReceived -Action {
    if ($EventArgs.Data) { Append-Output "$($EventArgs.Data)`r`n" }
  } | Out-Null

  Register-ObjectEvent -InputObject $script:helperProcess -EventName Exited -Action {
    Append-Output "Command finished with exit code $($Event.Sender.ExitCode).`r`n"
    Set-AppStatus "Ready"
    Refresh-Dashboard
  } | Out-Null

  $script:helperProcess.Start() | Out-Null
  $script:helperProcess.BeginOutputReadLine()
  $script:helperProcess.BeginErrorReadLine()
  Refresh-Dashboard
}

function Start-BackgroundWatcherScript {
  if ($script:process -and -not $script:process.HasExited) {
    [System.Windows.Forms.MessageBox]::Show("A command is already running in this app.", "Already running") | Out-Null
    return
  }
  Run-ScriptCommand "run-watcher-hidden.ps1" "Run hidden watcher helper"
  Refresh-Dashboard
}

function Run-SelfCheck {
  $requiredFiles = @(
    "app\chronica_discord_watcher.py",
    "app\chronica_watcher_gui.ps1",
    "config\config.json",
    "config\.env",
    "scripts\run-with-codex-python.ps1",
    "scripts\run-watcher-hidden.ps1",
    "scripts\restart-watcher-background.ps1",
    "scripts\run-watcher-background-worker.ps1",
    "scripts\stop-watcher-background.ps1",
    "scripts\install-windows-startup-shortcut.ps1",
    "scripts\uninstall-windows-startup-shortcut.ps1",
    "scripts\install-windows-startup-task.ps1",
    "scripts\uninstall-windows-startup-task.ps1"
  )

  Append-Output "`r`n[$(Get-Date -Format 'HH:mm:ss')] App self-check`r`n"
  foreach ($relative in $requiredFiles) {
    $path = Join-Path $rootDir $relative
    if (Test-Path $path) {
      Append-Output "OK      $relative`r`n"
    } else {
      Append-Output "MISSING $relative`r`n"
    }
  }

  $runner = Resolve-PythonRunner
  if ($runner) {
    Append-Output "OK      Python: $($runner.File)`r`n"
  } else {
    Append-Output "MISSING Python 3. Install Python 3 and tick 'Add python.exe to PATH'.`r`n"
  }

  Refresh-Dashboard
}

function Open-Path {
  param([string]$Path)
  if ($Path -match '\\$') { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
  Start-Process $Path
}

function Select-ToolTab {
  param([string]$Name)
  foreach ($tab in $tabs.TabPages) {
    if ($tab.Text -eq $Name) {
      $tabs.SelectedTab = $tab
      if ($Name -eq "Live Log") { Load-LogView }
      return
    }
  }
}

function Test-LiveLogVisible {
  return $tabs -and $tabs.SelectedTab -and $tabs.SelectedTab.Text -eq "Live Log"
}

function Load-LogView {
  if (-not $logBox) { return }
  if (-not (Test-Path $logPath)) {
    $logBox.Text = "No watcher history yet. Press Start Background Watcher first."
    return
  }
  try {
    $file = Get-Item $logPath
    $maxBytes = 220000
    $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
      $startByte = [Math]::Max(0, $stream.Length - $maxBytes)
      $stream.Seek($startByte, [System.IO.SeekOrigin]::Begin) | Out-Null
      $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
      $tailText = $reader.ReadToEnd()
    } finally {
      $stream.Close()
    }
    $allLines = [Regex]::Split($tailText, "\r?\n")
    if ($allLines.Count -gt 0) {
      $start = [Math]::Max(0, $allLines.Count - 500)
      $lines = $allLines[$start..($allLines.Count - 1)]
    } else {
      $lines = @()
    }
    if ($lines) {
      $logBox.Text = ($lines -join "`r`n") + "`r`n"
    } else {
      $logBox.Text = "The watcher history file exists, but it is empty."
    }
    $script:logPosition = $file.Length
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
  } catch {
    $logBox.Text = "Could not read the watcher history file: $($_.Exception.Message)"
  }
}

function Tail-Log {
  param([switch]$ShowStatus)
  if (-not (Test-LiveLogVisible)) {
    if (Test-Path $logPath) {
      $script:logPosition = (Get-Item $logPath).Length
    }
    return
  }
  if (-not (Test-Path $logPath)) {
    if ($ShowStatus -and $logBox) {
      $logBox.Text = "No log file exists yet. Start the watcher once, then come back here."
    }
    return
  }
  $stream = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    if ($script:logPosition -le 0 -or $script:logPosition -gt $stream.Length) {
      $script:logPosition = $stream.Length
    }
    $stream.Seek($script:logPosition, [System.IO.SeekOrigin]::Begin) | Out-Null
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
    $text = $reader.ReadToEnd()
    $script:logPosition = $stream.Position
    if ($text) {
      if ($text.Length -gt 120000) {
        $text = $text.Substring($text.Length - 120000)
      }
      $logBox.AppendText($text)
      if ($logBox.TextLength -gt 250000) {
        $logBox.Text = $logBox.Text.Substring($logBox.TextLength - 200000)
      }
      $logBox.SelectionStart = $logBox.TextLength
      $logBox.ScrollToCaret()
    }
    elseif ($ShowStatus) { $logBox.AppendText("No new log entries.`r`n") }
  } finally {
    $stream.Close()
  }
}

[System.Windows.Forms.Application]::EnableVisualStyles()
if (Test-SetupNeeded) {
  Show-SetupWizard -FirstRun | Out-Null
}

Ensure-DataFolders

$form = New-Object System.Windows.Forms.Form
$form.Text = "Chronica Discord Watcher Control Center"
$form.Size = New-Object System.Drawing.Size(1180, 780)
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)
$form.StartPosition = "CenterScreen"
$form.BackColor = $colorBg
$form.Font = $fontUi

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = "Fill"
$rootLayout.RowCount = 4
$rootLayout.ColumnCount = 1
$rootLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$rootLayout.Padding = New-Object System.Windows.Forms.Padding(0)
$rootLayout.BackColor = $colorBg
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28))) | Out-Null
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 88))) | Out-Null
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 30))) | Out-Null
$form.Controls.Add($rootLayout)

$menu = New-Object System.Windows.Forms.MenuStrip
$menu.Dock = "Fill"
$menu.BackColor = $colorPanel
$menu.ForeColor = $colorInk
$menu.Font = $fontUi
$form.MainMenuStrip = $menu
$rootLayout.Controls.Add($menu, 0, 0)

function Add-Menu {
  param([string]$Text)
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $Text
  $menu.Items.Add($item) | Out-Null
  return $item
}

function Add-MenuAction {
  param($Parent, [string]$Text, [scriptblock]$Action)
  $item = New-Object System.Windows.Forms.ToolStripMenuItem
  $item.Text = $Text
  $item.Add_Click($Action)
  $Parent.DropDownItems.Add($item) | Out-Null
  return $item
}

$watcherMenu = Add-Menu "Watcher"
Add-MenuAction $watcherMenu "Start / Stop Background Watcher" { Select-ToolTab "Dashboard"; Toggle-BackgroundWatcher } | Out-Null
Add-MenuAction $watcherMenu "Restart Background Watcher" { Select-ToolTab "Dashboard"; Restart-BackgroundWatcher } | Out-Null
Add-MenuAction $watcherMenu "Debug In This Window" { Select-ToolTab "Dashboard"; Start-WatcherCommand @() "Continuous watcher in this window" } | Out-Null
Add-MenuAction $watcherMenu "Stop Debug Command" { Stop-WatcherCommand } | Out-Null
Add-MenuAction $watcherMenu "Quiet Cache Rebuild" { Select-ToolTab "Dashboard"; Start-WatcherCommand @("--baseline") "Quiet cache rebuild" } | Out-Null
Add-MenuAction $watcherMenu "Pause / Resume Discord Notices" { Select-ToolTab "Dashboard"; Toggle-Notifications } | Out-Null
Add-MenuAction $watcherMenu "Toggle New Page Announcements" { Select-ToolTab "Dashboard"; Toggle-NewPageAnnouncements } | Out-Null
Add-MenuAction $watcherMenu "Dry Run Once" { Select-ToolTab "Dashboard"; Start-WatcherCommand @("--once", "--dry-run") "Dry run once" } | Out-Null
Add-MenuAction $watcherMenu "Test Discord" { Select-ToolTab "Dashboard"; Start-WatcherCommand @("--test-discord") "Discord test message" } | Out-Null

$pagesMenu = Add-Menu "Pages"
Add-MenuAction $pagesMenu "Find New Pages" { Select-ToolTab "Pages"; Start-WatcherCommand @("--list-pages") "Discover campaign pages" } | Out-Null
Add-MenuAction $pagesMenu "Show Watched Pages" { Select-ToolTab "Pages"; Start-WatcherCommand @("--list-known-pages") "List known cached pages" } | Out-Null
Add-MenuAction $pagesMenu "Quiet Cache Rebuild" { Select-ToolTab "Pages"; Start-WatcherCommand @("--baseline") "Quiet cache rebuild" } | Out-Null
Add-MenuAction $pagesMenu "Repair Development Titles" { Select-ToolTab "Pages"; Start-WatcherCommand @("--repair-development-titles") "Repair development titles" } | Out-Null
Add-MenuAction $pagesMenu "Test One Page" { Select-ToolTab "Pages" } | Out-Null
Add-MenuAction $pagesMenu "Open Page Cache" { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null; Start-Process explorer.exe $cacheDir } | Out-Null

$startupMenu = Add-Menu "Startup"
Add-MenuAction $startupMenu "Install Auto-Start" { Select-ToolTab "Startup"; Run-ScriptCommand "install-windows-startup-shortcut.ps1" "Install startup shortcut" } | Out-Null
Add-MenuAction $startupMenu "Remove Auto-Start" { Select-ToolTab "Startup"; Run-ScriptCommand "uninstall-windows-startup-shortcut.ps1" "Remove startup shortcut" } | Out-Null
Add-MenuAction $startupMenu "Try Scheduled Task" { Select-ToolTab "Startup"; Run-ScriptCommand "install-windows-startup-task.ps1" "Install scheduled task" } | Out-Null

$configMenu = Add-Menu "Config"
Add-MenuAction $configMenu "Open Settings" { Select-ToolTab "Config" } | Out-Null
Add-MenuAction $configMenu "Run Setup Wizard" { if (Show-SetupWizard) { $configBox.Text = Get-ConfigText; Refresh-Dashboard } } | Out-Null
Add-MenuAction $configMenu "Save Settings" { Save-ConfigText } | Out-Null
Add-MenuAction $configMenu "Open Secrets (.env)" { Start-Process notepad.exe $envPath } | Out-Null

$logsMenu = Add-Menu "Logs"
Add-MenuAction $logsMenu "Open Live Log" { Select-ToolTab "Live Log" } | Out-Null
Add-MenuAction $logsMenu "Last Posted Messages" { Select-ToolTab "Debug"; Start-WatcherCommand @("--list-sent") "Last posted messages" } | Out-Null
Add-MenuAction $logsMenu "Open Log File" { Start-Process notepad.exe $logPath } | Out-Null
Add-MenuAction $logsMenu "Run App Self-Check" { Select-ToolTab "Debug"; Run-SelfCheck } | Out-Null

$helpMenu = Add-Menu "Help"
Add-MenuAction $helpMenu "Open Simple Guide" { Start-Process notepad.exe (Join-Path $rootDir "SIMPLE-README.md") } | Out-Null
Add-MenuAction $helpMenu "Open Project Folder" { Start-Process explorer.exe $rootDir } | Out-Null

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Dock = "Fill"
$statusLabel.Height = 30
$statusLabel.Text = "Ready"
$statusLabel.Padding = New-Object System.Windows.Forms.Padding(14, 6, 0, 0)
$statusLabel.ForeColor = [System.Drawing.Color]::White
$statusLabel.BackColor = $colorSuccess
$statusLabel.Font = $fontUiBold
$rootLayout.Controls.Add($statusLabel, 0, 3)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = "Fill"
$header.Height = 88
$header.BackColor = $colorInk
$rootLayout.Controls.Add($header, 0, 1)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Chronica Updates"
$titleLabel.Font = $fontTitle
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Location = New-Object System.Drawing.Point(18, 14)
$titleLabel.AutoSize = $true
$header.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = "Watches characters, kinships, places, and developments, then posts page edits to Discord."
$subtitleLabel.Font = $fontSubtitle
$subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
$subtitleLabel.Location = New-Object System.Drawing.Point(20, 50)
$subtitleLabel.AutoSize = $true
$header.Controls.Add($subtitleLabel)

$mainPanel = New-Object System.Windows.Forms.TableLayoutPanel
$mainPanel.Dock = "Fill"
$mainPanel.RowCount = 1
$mainPanel.ColumnCount = 2
$mainPanel.BackColor = $colorBg
$mainPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$mainPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$mainPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 176))) | Out-Null
$mainPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$mainPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$rootLayout.Controls.Add($mainPanel, 0, 2)

$navPanel = New-Object System.Windows.Forms.Panel
$navPanel.Dock = "Fill"
$navPanel.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$mainPanel.Controls.Add($navPanel, 0, 0)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = "Fill"
$tabs.Font = $fontUiBold
$tabs.Appearance = "FlatButtons"
$tabs.SizeMode = "Fixed"
$tabs.ItemSize = New-Object System.Drawing.Size(1, 1)
$tabs.Padding = New-Object System.Drawing.Point(0, 0)
$mainPanel.Controls.Add($tabs, 1, 0)

$navTitle = New-Object System.Windows.Forms.Label
$navTitle.Text = "Tools"
$navTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 11)
$navTitle.ForeColor = $colorMuted
$navTitle.Location = New-Object System.Drawing.Point(16, 14)
$navTitle.AutoSize = $true
$navPanel.Controls.Add($navTitle)

function New-Tab {
  param([string]$Name)
  $tab = New-Object System.Windows.Forms.TabPage
  $tab.Text = $Name
  $tab.BackColor = $colorBg
  $tabs.TabPages.Add($tab) | Out-Null
  return $tab
}

function New-Button {
  param(
    [string]$Text,
    [scriptblock]$OnClick,
    [int]$Width = 150,
    [System.Drawing.Color]$BackColor = $colorSoft,
    [System.Drawing.Color]$ForeColor = $colorInk
  )
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Width = $Width
  $button.Height = 38
  $button.Margin = New-Object System.Windows.Forms.Padding(5)
  $button.FlatStyle = "Flat"
  $button.FlatAppearance.BorderSize = 0
  $button.BackColor = $BackColor
  $button.ForeColor = $ForeColor
  $button.Font = $fontUiBold
$button.Cursor = [System.Windows.Forms.Cursors]::Hand
  $button.Add_Click($OnClick)
  return $button
}

function New-StatusTextLabel {
  param([string]$Text, [int]$Left, [int]$Top, [int]$Width = 210)
  $label = New-Object System.Windows.Forms.Label
  $label.Text = $Text
  $label.Location = New-Object System.Drawing.Point($Left, $Top)
  $label.Size = New-Object System.Drawing.Size($Width, 24)
  $label.Font = $fontUiBold
  $label.ForeColor = $colorInk
  return $label
}

function New-NavButton {
  param([string]$Text, [string]$TabName, [int]$Top)
  $button = New-Object System.Windows.Forms.Button
  $button.Text = $Text
  $button.Width = 144
  $button.Height = 38
  $button.Location = New-Object System.Drawing.Point(16, $Top)
  $button.FlatStyle = "Flat"
  $button.FlatAppearance.BorderSize = 0
  $button.BackColor = $colorPanel
  $button.ForeColor = $colorInk
  $button.Font = $fontUiBold
  $button.TextAlign = "MiddleLeft"
  $button.Cursor = [System.Windows.Forms.Cursors]::Hand
  $button.Add_Click({ Select-ToolTab $TabName }.GetNewClosure())
  $navPanel.Controls.Add($button)
}

New-NavButton "Dashboard" "Dashboard" 48
New-NavButton "Pages" "Pages" 92
New-NavButton "Config" "Config" 136
New-NavButton "Startup" "Startup" 180
New-NavButton "Debug" "Debug" 224
New-NavButton "Live Log" "Live Log" 268
New-NavButton "Files" "Files" 312

$dashboardTab = New-Tab "Dashboard"

$backgroundPanel = New-Object System.Windows.Forms.Panel
$backgroundPanel.Dock = "Top"
$backgroundPanel.Height = 92
$backgroundPanel.Padding = New-Object System.Windows.Forms.Padding(16)
$backgroundPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$dashboardTab.Controls.Add($backgroundPanel)

$backgroundTitle = New-Object System.Windows.Forms.Label
$backgroundTitle.Text = "Background Watcher"
$backgroundTitle.Location = New-Object System.Drawing.Point(18, 12)
$backgroundTitle.Size = New-Object System.Drawing.Size(190, 24)
$backgroundTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12)
$backgroundTitle.ForeColor = $colorInk
$backgroundPanel.Controls.Add($backgroundTitle)

$script:backgroundStatusLabel = New-Object System.Windows.Forms.Label
$script:backgroundStatusLabel.Text = "Checking..."
$script:backgroundStatusLabel.Location = New-Object System.Drawing.Point(210, 12)
$script:backgroundStatusLabel.Size = New-Object System.Drawing.Size(190, 26)
$script:backgroundStatusLabel.TextAlign = "MiddleCenter"
$script:backgroundStatusLabel.Font = $fontUiBold
$script:backgroundStatusLabel.ForeColor = [System.Drawing.Color]::White
$script:backgroundStatusLabel.BackColor = $colorWarning
$backgroundPanel.Controls.Add($script:backgroundStatusLabel)

$script:backgroundPidLabel = New-StatusTextLabel "Process: -" 18 52 120
$script:backgroundPagesLabel = New-StatusTextLabel "Watching: 0 page(s)" 150 52 170
$script:backgroundStartedLabel = New-StatusTextLabel "Started: - / Last: -" 330 52 300
$script:backgroundStartupLabel = New-StatusTextLabel "Auto-start: -" 650 52 170
$script:webhookStatusLabel = New-StatusTextLabel "Webhook: -" 830 52 130
$script:notificationStatusLabel = New-StatusTextLabel "Notices: -" 970 52 130
$script:newPageStatusLabel = New-StatusTextLabel "New pages: -" 18 72 180
$backgroundPanel.Controls.Add($script:backgroundPidLabel)
$backgroundPanel.Controls.Add($script:backgroundPagesLabel)
$backgroundPanel.Controls.Add($script:backgroundStartedLabel)
$backgroundPanel.Controls.Add($script:backgroundStartupLabel)
$backgroundPanel.Controls.Add($script:webhookStatusLabel)
$backgroundPanel.Controls.Add($script:notificationStatusLabel)
$backgroundPanel.Controls.Add($script:newPageStatusLabel)

$dashPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$dashPanel.Dock = "Top"
$dashPanel.Height = 150
$dashPanel.Padding = New-Object System.Windows.Forms.Padding(14)
$dashPanel.BackColor = $colorPanel
$dashboardTab.Controls.Add($dashPanel)
$script:backgroundToggleButton = New-Button "Background: Off" { Toggle-BackgroundWatcher } 190 $colorPrimary ([System.Drawing.Color]::White)
$dashPanel.Controls.Add($script:backgroundToggleButton)
$dashPanel.Controls.Add((New-Button "Restart Background" { Restart-BackgroundWatcher } 170 $colorWarning ([System.Drawing.Color]::White)))
$dashPanel.Controls.Add((New-Button "Test Discord" { Start-WatcherCommand @("--test-discord") "Discord test message" } 150 $colorSuccess ([System.Drawing.Color]::White)))
$dashPanel.Controls.Add((New-Button "Quiet Cache Rebuild" { Start-WatcherCommand @("--baseline") "Quiet cache rebuild" } 180))
$script:noticesToggleButton = New-Button "Notices: Active" { Toggle-Notifications } 150 $colorWarning ([System.Drawing.Color]::White)
$dashPanel.Controls.Add($script:noticesToggleButton)
$script:newPagesToggleButton = New-Button "New Pages: Off" { Toggle-NewPageAnnouncements } 150
$dashPanel.Controls.Add($script:newPagesToggleButton)
$dashPanel.Controls.Add((New-Button "Dry Run" { Start-WatcherCommand @("--once", "--dry-run") "Dry run once" } 120))
$dashPanel.Controls.Add((New-Button "Debug In This Window" { Start-WatcherCommand @() "Continuous watcher in this window" } 180))
$dashPanel.Controls.Add((New-Button "Refresh" { Refresh-Dashboard } 110))
$dashboardText = New-Object System.Windows.Forms.RichTextBox
$dashboardText.Multiline = $true
$dashboardText.Dock = "Fill"
$dashboardText.ReadOnly = $true
$dashboardText.Font = $fontMono
$dashboardText.BackColor = $colorPanel
$dashboardText.ForeColor = $colorInk
$dashboardText.BorderStyle = "None"
$dashboardText.Margin = New-Object System.Windows.Forms.Padding(12)
$dashboardTab.Controls.Add($dashboardText)
$dashboardTab.Controls.SetChildIndex($backgroundPanel, 0)
$dashboardTab.Controls.SetChildIndex($dashPanel, 1)
$dashboardTab.Controls.SetChildIndex($dashboardText, 2)

$pagesTab = New-Tab "Pages"
$pagesPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$pagesPanel.Dock = "Top"
$pagesPanel.Height = 118
$pagesPanel.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 8)
$pagesPanel.BackColor = $colorPanel
$pagesTab.Controls.Add($pagesPanel)
$pagesPanel.Controls.Add((New-Button "Find New Pages" { Start-WatcherCommand @("--list-pages") "Discover campaign pages" } 150 $colorPrimary ([System.Drawing.Color]::White)))
$pagesPanel.Controls.Add((New-Button "Show Watched Pages" { Start-WatcherCommand @("--list-known-pages") "List known cached pages" } 170))
$pagesPanel.Controls.Add((New-Button "Quiet Cache Rebuild" { Start-WatcherCommand @("--baseline") "Quiet cache rebuild" } 180))
$pagesPanel.Controls.Add((New-Button "Repair Dev Titles" { Start-WatcherCommand @("--repair-development-titles") "Repair development titles" } 160 $colorWarning ([System.Drawing.Color]::White)))
$pagesPanel.Controls.Add((New-Button "Open Page Cache" { New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null; Start-Process explorer.exe $cacheDir } 160))
$pagesPanel.Controls.Add((New-Button "Known Pages File" { Start-Process notepad.exe $knownPagesPath } 160))
$pagesPanel.Controls.Add((New-Button "State File" { Start-Process notepad.exe $statePath } 110))
$pageTestLabel = New-Object System.Windows.Forms.Label
$pageTestLabel.Text = "Test page URL:"
$pageTestLabel.Width = 92
$pageTestLabel.Height = 32
$pageTestLabel.Margin = New-Object System.Windows.Forms.Padding(5, 12, 5, 5)
$pageTestLabel.TextAlign = "MiddleLeft"
$pagesPanel.Controls.Add($pageTestLabel)
$pageTestUrlBox = New-Object System.Windows.Forms.TextBox
$pageTestUrlBox.Width = 430
$pageTestUrlBox.Height = 28
$pageTestUrlBox.Margin = New-Object System.Windows.Forms.Padding(5, 12, 5, 5)
$pagesPanel.Controls.Add($pageTestUrlBox)
$pagesPanel.Controls.Add((New-Button "Test One Page" { if ($pageTestUrlBox.Text.Trim()) { Start-WatcherCommand @("--test-page", $pageTestUrlBox.Text.Trim()) "Test one Chronica page" } } 150 $colorPrimary ([System.Drawing.Color]::White)))
$pagesPanel.Controls.Add((New-Button "Ignore This Page" { Add-IgnoreUrl } 160 $colorWarning ([System.Drawing.Color]::White)))

$configTab = New-Tab "Config"
$configPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$configPanel.Dock = "Top"
$configPanel.Height = 62
$configPanel.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 8)
$configPanel.BackColor = $colorPanel
$configTab.Controls.Add($configPanel)
$configPanel.Controls.Add((New-Button "Save Settings" { Save-ConfigText } 140 $colorPrimary ([System.Drawing.Color]::White)))
$configPanel.Controls.Add((New-Button "Reload" { $configBox.Text = Get-ConfigText } 110))
$configPanel.Controls.Add((New-Button "Open Secrets (.env)" { Start-Process notepad.exe $envPath } 170))
$configBox = New-Object System.Windows.Forms.TextBox
$configBox.Multiline = $true
$configBox.Dock = "Fill"
$configBox.ScrollBars = "Both"
$configBox.Font = $fontMono
$configBox.BackColor = $colorPanel
$configBox.ForeColor = $colorInk
$configBox.Text = Get-ConfigText
$configTab.Controls.Add($configBox)

$startupTab = New-Tab "Startup"
$startupPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$startupPanel.Dock = "Top"
$startupPanel.Height = 92
$startupPanel.Padding = New-Object System.Windows.Forms.Padding(14)
$startupPanel.BackColor = $colorPanel
$startupTab.Controls.Add($startupPanel)
$startupPanel.Controls.Add((New-Button "Install Auto-Start" { Run-ScriptCommand "install-windows-startup-shortcut.ps1" "Install startup shortcut" } 170 $colorSuccess ([System.Drawing.Color]::White)))
$startupPanel.Controls.Add((New-Button "Remove Auto-Start" { Run-ScriptCommand "uninstall-windows-startup-shortcut.ps1" "Remove startup shortcut" } 170 $colorDanger ([System.Drawing.Color]::White)))
$startupPanel.Controls.Add((New-Button "Try Scheduled Task" { Run-ScriptCommand "install-windows-startup-task.ps1" "Install scheduled task" } 170))
$startupPanel.Controls.Add((New-Button "Remove Task" { Run-ScriptCommand "uninstall-windows-startup-task.ps1" "Remove scheduled task" } 130))
$startupInfo = New-Object System.Windows.Forms.TextBox
$startupInfo.Multiline = $true
$startupInfo.Dock = "Fill"
$startupInfo.ReadOnly = $true
$startupInfo.Font = $fontMono
$startupInfo.BackColor = $colorPanel
$startupInfo.BorderStyle = "None"
$startupInfo.Text = "Recommended: use Install Auto-Start. It runs the watcher when you log into Windows and does not need the GUI to stay open.`r`n`r`nIf Scheduled Task says Access is denied, ignore it and use Auto-Start instead.`r`n`r`nStartup shortcut path:`r`n$startupShortcut"
$startupTab.Controls.Add($startupInfo)

$debugTab = New-Tab "Debug"
$debugPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$debugPanel.Dock = "Top"
$debugPanel.Height = 106
$debugPanel.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 8)
$debugPanel.BackColor = $colorPanel
$debugTab.Controls.Add($debugPanel)
$debugPanel.Controls.Add((New-Button "Backend Status" { Start-WatcherCommand @("--status") "Backend status" }))
$debugPanel.Controls.Add((New-Button "App Self-Check" { Run-SelfCheck }))
$debugPanel.Controls.Add((New-Button "Last Posted" { Start-WatcherCommand @("--list-sent") "Last posted messages" }))
$debugPanel.Controls.Add((New-Button "GM Safety Check" { Start-WatcherCommand @("--safety-check") "Bot account safety check" }))
$debugPanel.Controls.Add((New-Button "Clear Output" { $output.Clear() }))
$debugPanel.Controls.Add((New-Button "Open Log File" { Start-Process notepad.exe $logPath }))
$output = New-Object System.Windows.Forms.RichTextBox
$output.Dock = "Fill"
$output.Font = $fontMono
$output.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$output.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$output.ReadOnly = $true
$output.Text = "Ready. This panel shows live command output and errors.`r`n"
$debugTab.Controls.Add($output)

$logTab = New-Tab "Live Log"
$logPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$logPanel.Dock = "Top"
$logPanel.Height = 62
$logPanel.Padding = New-Object System.Windows.Forms.Padding(14, 10, 14, 8)
$logPanel.BackColor = $colorPanel
$logTab.Controls.Add($logPanel)
$logPanel.Controls.Add((New-Button "Refresh Log" { Load-LogView }))
$logPanel.Controls.Add((New-Button "Clear View" { $logBox.Clear(); $script:logPosition = 0 }))
$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = "Fill"
$logBox.Font = $fontMono
$logBox.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$logBox.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$logBox.ReadOnly = $true
$logBox.Text = "Live contents of data/chronica-watcher.log will appear here.`r`n"
$logTab.Controls.Add($logBox)

$filesTab = New-Tab "Files"
$filesPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$filesPanel.Dock = "Fill"
$filesPanel.Padding = New-Object System.Windows.Forms.Padding(18)
$filesPanel.BackColor = $colorPanel
$filesTab.Controls.Add($filesPanel)
$filesPanel.Controls.Add((New-Button "Project Folder" { Start-Process explorer.exe $rootDir } 180))
$filesPanel.Controls.Add((New-Button "Config Folder" { Start-Process explorer.exe (Join-Path $rootDir "config") } 180))
$filesPanel.Controls.Add((New-Button "Data + Logs" { Start-Process explorer.exe (Join-Path $rootDir "data") } 180))
$filesPanel.Controls.Add((New-Button "Scripts" { Start-Process explorer.exe $scriptDir } 140))
$filesPanel.Controls.Add((New-Button "App Code" { Start-Process explorer.exe $appDir } 140))

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({
  if ($form.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
    Refresh-Dashboard
  }
  if (Test-LiveLogVisible) { Tail-Log }
})
$timer.Start()

$form.Add_FormClosing({
  if ($script:process -and -not $script:process.HasExited) {
    $script:process.Kill()
  }
})

Refresh-Dashboard
[System.Windows.Forms.Application]::Run($form)
