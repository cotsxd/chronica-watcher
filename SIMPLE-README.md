# Chronica Discord Watcher

This watches your Chronica campaign and posts Discord updates when real campaign detail pages change.

It watches:

```text
Characters
Kinships
Places
Developments
```

## Normal Use

First-time setup:

```text
1. Install Python 3 from python.org and tick "Add python.exe to PATH"
2. Double-click START HERE.cmd
3. Fill in the setup wizard
```

The wizard asks for your Chronica campaign ID or URL, Chronica bot account login, and Discord webhook URL. It fills in the config files for you.

Double-click:

```text
START HERE.cmd
```

Then use:

```text
Dashboard -> Start Background Watcher
```

You can close the GUI after that. The watcher keeps running in the background.

To stop it without opening the GUI, double-click:

```text
STOP BACKGROUND WATCHER.cmd
```

If the control center freezes, double-click:

```text
KILL FROZEN WATCHER.cmd
```

To start it without opening the GUI, double-click:

```text
START BACKGROUND WATCHER.cmd
```

## Auto-Start

Use:

```text
Startup -> Install Auto-Start
```

This starts the background watcher when you log into Windows. Scheduled Task may need admin rights, so Auto-Start is the recommended option.

## What It Posts

Existing page edits:

```text
The Chronica character Davy Jones has been updated.
https://chronica.ventures/...
```

New pages are learned silently by default to avoid spam after cache resets.

## Useful Safety Buttons

Use `Quiet Cache Rebuild` after clearing caches or changing settings. It scans the campaign and saves the current pages without posting anything to Discord.

Use `Pause Notices` when you want the watcher to keep running but temporarily stop Discord messages. Use `Resume Notices` to turn messages back on.

Use `New Pages On` if you want brand-new Chronica pages announced in Discord. Leave it off when rebuilding caches or adding lots of pages.

Use `Test One Page` to paste a Chronica URL and see the title, page type, hidden/private status, and Discord message preview before anything posts.

Use `Last Posted` in the Debug area to audit the last 20 Discord updates.

Use `Ignore This Page` after pasting a page URL if that page should never post.

Use `GM Safety Check` to check whether the bot account appears to see GM-only controls. A player-level bot account is safest.

Use `Repair Dev Titles` if development posts are using a heading from inside the content instead of the real Chronica development name.

## Sharing A Clean Copy

Use:

```text
scripts/build-shareable-package.ps1
```

The zip it creates does not include your `.env`, live config, cache, logs, or state files.

## Upload To GitHub

Create an empty GitHub repository, then double-click:

```text
UPLOAD TO GITHUB.cmd
```

Paste the GitHub repo URL when asked. The uploader checks that private files are ignored before pushing.

## Private Settings

Secrets live in:

```text
config/.env
```

Do not share that file.
