# claude-code-toast

Windows toast notifications for [Claude Code](https://claude.ai/code) events using native Windows APIs.

> **Fork notice:** This is a fork of [TianqiZhang/claude-code-toast](https://github.com/TianqiZhang/claude-code-toast)
> with two changes:
> 1. It **suppresses `idle_prompt` notifications** — the toast that fires when Claude has been
>    sitting idle waiting for input. See [What this fork changes](#what-this-fork-changes).
> 2. Toasts are **clickable** — clicking one raises the Windows Terminal window the session is
>    running in (and switches to its tab when possible). See
>    [Click a toast to focus its session](#click-a-toast-to-focus-its-session).

## Features

- **Notification Hook**: Shows a toast notification when Claude Code sends notifications (e.g., asking for input, tool permission requests)
- **Stop Hook**: Shows a toast when Claude Code finishes responding
- **Click to focus** *(fork addition)*: Clicking a toast raises the Windows Terminal window the session is running in — and switches to its tab when the tab still shows Claude's title

## What this fork changes

The upstream plugin shows a toast for **every** Claude Code notification, including
`idle_prompt` — the one that fires after Claude has been waiting on you for a while.
That toast isn't useful for tracking when you actually need to refocus the CLI tab, so
this fork skips it.

`scripts/toast-notification.ps1` exits early before building a toast whenever the
incoming `notification_type` is in a suppress list:

```powershell
$suppressedTypes = @('idle_prompt')
if ($data.notification_type -and $suppressedTypes -contains $data.notification_type) { exit 0 }
```

All other notification types — and the `Stop` ("Finished responding") toast — are
unaffected.

### Customizing which types are suppressed

Add more notification types to the `$suppressedTypes` array near the top of
`scripts/toast-notification.ps1`, e.g.:

```powershell
$suppressedTypes = @('idle_prompt', 'some_other_type')
```

If you installed locally, reinstall and reload afterward so the change takes effect
(see [Option 3](#option-3-local-installation-for-development)).

## Click a toast to focus its session

*(Fork addition.)* In the upstream plugin, clicking a toast does nothing. In this fork,
clicking a toast brings the **Windows Terminal** window that raised it to the foreground —
and, when it can identify the exact tab, switches to that tab too.

### How it works

- Each toast is built with `launch="claudetoast:focus?t=<title>" activationType="protocol"`,
  where `<title>` is the session's tab title (Claude's conversation topic) captured from
  `[Console]::Title` at the moment the toast fired.
- The first time a hook runs it registers a `claudetoast:` URL-protocol handler under
  `HKCU\Software\Classes` (current user only, no admin) and copies the click handler
  (`focus-session.ps1`) plus a hidden launcher (`focus-launch.vbs`) to a stable path,
  `%LOCALAPPDATA%\claude-code-toast\`. The stable path is needed because the plugin's cache
  directory changes on every reinstall, but the registry needs a fixed target. The copy is
  hash-gated, so it self-heals across reinstalls and updates.
- On click, `focus-session.ps1` uses **UI Automation** to find the Terminal tab whose title
  matches, selects it, and foregrounds its window. It runs via `wscript.exe` +
  `focus-launch.vbs` so PowerShell starts hidden and no console window flashes.

### Limitations

Tab-precise targeting has real limits, because the tab title is the only handle Windows
Terminal exposes to identify a tab:

- **Renamed tabs.** If you manually rename a tab, Terminal stops displaying Claude's title and
  there is no other identifier to match on. The click then falls back to raising the
  most-recently-active Terminal window (you pick the tab).
- **Multiple Terminal windows.** When the title still matches, the right window is found and
  raised. When it can't (renamed tab), the fallback raises a best-guess window.
- A single Terminal window holding the session's tab is the case that always works precisely.
- Only **Windows Terminal** is supported. Other terminals (conhost, VS Code, etc.) aren't —
  the click just raises a Terminal window if one exists.

### Removing the click handler

```powershell
Remove-Item -Path 'HKCU:\Software\Classes\claudetoast' -Recurse -Force
Remove-Item -Path "$env:LOCALAPPDATA\claude-code-toast" -Recurse -Force
```

## Prerequisites

- Windows 10/11
- PowerShell 5.1+

No external modules required - uses native Windows toast notification APIs.

## Installation

### Option 1: Via Plugin Marketplace (Recommended)

First, add the marketplace:

```bash
/plugin marketplace add inikiforovski/claude-code-toast
```

Then install the plugin:

```bash
/plugin install toast-notifications@claude-code-toast
```

> **Already running the upstream plugin?** This fork keeps the same marketplace name
> (`claude-code-toast`), so Claude Code won't let you register both at once. Remove the
> upstream copy first:
>
> ```bash
> /plugin uninstall toast-notifications@claude-code-toast
> /plugin marketplace remove claude-code-toast
> ```
>
> then run the two commands above followed by `/reload-plugins`.

### Option 2: Direct Plugin Install

```bash
/plugin install inikiforovski/claude-code-toast
```

### Option 3: Local Installation (for development)

Clone the repo, then add the clone as a local marketplace:

```bash
/plugin marketplace add C:\path\to\claude-code-toast
/plugin install toast-notifications@claude-code-toast
```

A local install **copies** the plugin into Claude Code's plugin cache, so the install is
a snapshot — editing a script in your clone does not update the running plugin. After any
edit, reinstall and reload to pick it up:

```bash
/plugin install toast-notifications@claude-code-toast
/reload-plugins
```

## Usage

Once installed, the plugin automatically:

1. Shows a toast notification when Claude Code needs your attention
2. Shows a "Finished responding" toast when Claude completes a response

Click either toast to jump to the Windows Terminal session that raised it (see
[Click a toast to focus its session](#click-a-toast-to-focus-its-session)).
`idle_prompt` notifications are silently skipped (see [What this fork changes](#what-this-fork-changes)).

## Hook Events

| Event | Description |
|-------|-------------|
| `Notification` | Triggered when Claude Code sends a notification (except suppressed types) |
| `Stop` | Triggered when Claude Code finishes responding |

## Project Structure

```
claude-code-toast/
├── .claude-plugin/
│   ├── plugin.json             # Plugin manifest
│   └── marketplace.json        # Marketplace manifest
├── assets/
│   └── icon.png                # Notification icon
├── hooks/
│   └── hooks.json              # Hook configuration
├── scripts/
│   ├── toast-common.ps1        # Shared helpers: activation install + toast rendering
│   ├── toast-notification.ps1  # Notification handler (suppresses idle_prompt)
│   ├── toast-stop.ps1          # Stop event handler
│   ├── focus-session.ps1       # Click handler: focus the originating Terminal tab/window
│   └── focus-launch.vbs        # Hidden launcher for focus-session.ps1 (no console flash)
├── LICENSE
└── README.md
```

## Testing

```powershell
# Test notification toast (info type → toast shown)
'{"message": "Test notification", "notification_type": "info"}' | powershell -File .\scripts\toast-notification.ps1

# Test suppression (idle_prompt → no toast, silent exit 0)
'{"message": "Idle", "notification_type": "idle_prompt"}' | powershell -File .\scripts\toast-notification.ps1

# Test stop toast
powershell -File .\scripts\toast-stop.ps1
```

## Credits

Forked from [TianqiZhang/claude-code-toast](https://github.com/TianqiZhang/claude-code-toast).

## License

MIT
