# Chronica Discord Updates

Authenticated watcher for `chronica.ventures`. It logs in with the Chronica bot account, checks campaign detail pages, caches focused page content, and posts Discord webhook messages when watched pages change.

## Main Launchers

```text
START HERE.cmd                 open the control center
START BACKGROUND WATCHER.cmd   start watcher without GUI
STOP BACKGROUND WATCHER.cmd    stop watcher without GUI
KILL FROZEN WATCHER.cmd        force-close stuck watcher/GUI processes
UPLOAD TO GITHUB.cmd           publish the source project to a GitHub repo
```

The GUI is a control panel. The background watcher keeps running after the GUI closes.

## Folder Layout

```text
app/       watcher backend and native Windows GUI
config/    config.json, examples, and private .env
data/      live state, active page cache, logs, lock file
scripts/   run/start/stop/setup helper scripts
archive/   old removed assets, if present
```

## Watch Scope

```text
https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/characters
https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/kinships
https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/places
https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/developments
```

Only real detail pages are notified:

```text
/characters/123
/kinships/123
/places/123
/developments/123
```

List, filter, edit, pagination, and settings URLs are ignored.

## Behavior

- Known pages are checked every `check_interval_seconds`.
- New-page discovery runs every `discovery_interval_seconds`.
- First-seen page notifications are off by default to avoid spam after a cache reset.
- Hidden/private/secret-looking pages are skipped.
- Discord messages include the page kind and link.
- Quiet Cache Rebuild scans and saves the current campaign pages without posting to Discord.
- Pause Discord Notices keeps the watcher running but stops Discord posts until notices are resumed.
- New Pages On/Off controls whether first-seen Chronica pages are announced to Discord.
- Test One Page previews the detected title, page type, hidden/private status, and exact Discord message.
- Last Posted Messages shows the last 20 notifications the watcher successfully sent.
- `ignore_urls` in `config/config.json` blocks specific pages from ever posting.
- GM Safety Check warns if the bot account appears to see GM-style controls or private fields.
- Repair Development Titles fetches every known development and fixes saved titles without posting to Discord.

## Setup

Install Python 3 on Windows if you are not running this from Codex:

```text
https://www.python.org/downloads/windows/
```

During install, tick `Add python.exe to PATH`.

Then double-click `START HERE.cmd`. On first run, the setup wizard asks for:

```text
Chronica campaign ID or campaign URL
Chronica bot account email
Chronica bot account password
Discord webhook URL
```

The wizard creates `config/.env` and `config/config.json` for you. You can rerun it later from `Config -> Run Setup Wizard`.

Private values live in:

```text
config/.env
```

Required keys:

```text
CHRONICA_EMAIL=...
CHRONICA_PASSWORD=...
DISCORD_WEBHOOK_URL=...
```

Keep `.env` private.

## Auto-Start

Recommended:

```text
Startup -> Install Auto-Start
```

Scheduled Task can require admin rights and may fail with `Access is denied`.

## Useful Commands

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --status
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --list-known-pages
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --list-pages
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --baseline
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --test-page "https://chronica.ventures/campaigns/YOUR_CAMPAIGN_ID/characters/123"
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --list-sent
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --safety-check
powershell -ExecutionPolicy Bypass -File .\scripts\run-with-codex-python.ps1 --repair-development-titles
```

## Sharing

Build a clean zip without private files:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-shareable-package.ps1
```

The package excludes `config/.env`, `config/config.json`, `data/`, and `archive/`.

## GitHub Upload

Create an empty GitHub repository first, then double-click:

```text
UPLOAD TO GITHUB.cmd
```

The uploader checks that private/generated files are ignored, commits the safe source files, asks for the GitHub repo URL, and pushes to `main`.
