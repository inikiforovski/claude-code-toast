# claude-code-toast

Windows toast notifications for [Claude Code](https://claude.ai/code) events using native Windows APIs.

> **Fork notice:** This is a fork of [TianqiZhang/claude-code-toast](https://github.com/TianqiZhang/claude-code-toast)
> with two changes:
> 1. It **suppresses `idle_prompt` notifications** — the toast that fires when Claude has been
>    sitting idle waiting for input. See [What this fork changes](#what-this-fork-changes).
> 2. Toasts are **clickable** — clicking one raises (and un-minimizes) the exact Windows Terminal
>    window the session is running in (even with several windows open), and each toast **names the
>    session** (project folder + prompt) so you know which tab to go to. See
>    [Click a toast to focus its session](#click-a-toast-to-focus-its-session).

## Features

- **Notification Hook**: Shows a toast notification when Claude Code sends notifications (e.g., asking for input, tool permission requests)
- **Stop Hook**: Shows a toast when Claude Code finishes responding
- **Click to focus** *(fork addition)*: Clicking a toast raises (and un-minimizes) the *exact* Windows Terminal window the session is running in — even with several windows open. Each toast also names the originating session (project folder + the prompt that started it) so you can spot the right tab

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
clicking a toast brings the **exact Windows Terminal window** that raised it to the foreground
and un-minimizes it if needed — even when several Terminal windows are open. Because the click
can't reliably switch to the exact *tab* (see
[Why the window, not the exact tab](#why-the-window-not-the-exact-tab)), each toast **names the
session** — the project folder and the prompt that started it — so you can pick the right tab
from the strip.

### How it works

- **Capture (the key bit):** a `UserPromptSubmit` and a `SessionStart` hook fire a tiny,
  detached helper (`capture-launch.vbs` → `capture-window.ps1`) that records the **foreground
  window's HWND** — keyed by the session's `WT_SESSION` GUID — into
  `%LOCALAPPDATA%\claude-code-toast\sessions\`. Those two moments are exactly when you're
  looking at *this* session's window, so the foreground window is reliably the right one. The
  helper launches via `wscript.exe` and returns in ~30 ms, so it adds no perceptible latency
  to prompt submission.
- Each toast is built with `launch="claudetoast:focus?hwnd=<n>" activationType="protocol"`,
  where `<n>` is the captured HWND for the session that raised it. The hook also reads its
  stdin payload (`cwd`, `transcript_path`) to add a **session label** (project folder + the
  first real user prompt) as an extra line on the toast.
- The first time a hook runs it registers a `claudetoast:` URL-protocol handler under
  `HKCU\Software\Classes` (current user only, no admin) and copies the click handler
  (`focus-session.ps1`) plus a hidden launcher (`focus-launch.vbs`) to a stable path,
  `%LOCALAPPDATA%\claude-code-toast\`. The stable path is needed because the plugin's cache
  directory changes on every reinstall, but the registry needs a fixed target. The copy is
  hash-gated, so it self-heals across reinstalls and updates.
- On click, `focus-session.ps1` parses the HWND out of the URI and raises (and un-minimizes)
  **that exact window** — so the correct window comes up even with several Terminal windows
  open. If the HWND is missing or stale (the window was closed since), it falls back to the
  most-recently-active Terminal window. It runs via `wscript.exe` + `focus-launch.vbs` so
  PowerShell starts hidden and no console window flashes.

### Why the window, not the exact tab

The click now raises the **correct window**, but it stops at the window — it does not switch
to the exact *tab*. Two reasons:

- **Windows can't be told apart by process.** Windows Terminal hosts several windows in a
  single `WindowsTerminal.exe` process, so walking the hook's parent processes finds the right
  *process* but not the right *window*. The only per-window identity is the HWND — which is why
  the capture step records the live foreground HWND while the session is focused.
- **Tabs expose no usable handle.** Claude Code runs the hooks as `powershell.exe` under Git
  Bash, in a console **bridged to — but not the same as** — the tab's real ConPTY. The hook
  can enumerate tabs via UI Automation but **cannot identify its own tab**: the only per-tab
  handle Windows Terminal exposes is the tab *title*, and the title the hook can read
  (`[Console]::Title`) is whatever the last subprocess set (often `bash.exe`), while any title
  it tries to *write* never reaches Windows Terminal. Naming the session on the toast is the
  robust alternative for picking the tab.

### Limitations

- **Tab selection** is up to you — the click raises the correct window; the toast text names
  the session so you can pick the tab. With one session per window (or one tab per project)
  this is a non-issue.
- The window is captured on prompt submit / session start. If you **tear a tab off into a new
  window**, the next prompt re-captures it; until then a click may raise the window the tab
  came from.
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
| `UserPromptSubmit` | Records this session's foreground Terminal window so a later toast can raise it (no toast shown) |
| `SessionStart` | Same window capture, at session start (no toast shown) |
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
│   ├── toast-common.ps1        # Shared helpers: activation install, session-window store, toast rendering
│   ├── toast-notification.ps1  # Notification handler (suppresses idle_prompt)
│   ├── toast-stop.ps1          # Stop event handler
│   ├── capture-window.ps1      # Records this session's foreground Terminal window (keyed by WT_SESSION)
│   ├── capture-launch.vbs      # Hidden, non-blocking launcher for capture-window.ps1
│   ├── focus-session.ps1       # Click handler: focus the originating Terminal window
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
