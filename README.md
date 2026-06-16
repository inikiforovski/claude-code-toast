# claude-code-toast

Windows toast notifications for [Claude Code](https://claude.ai/code) events using native Windows APIs.

> **Fork notice:** This is a fork of [TianqiZhang/claude-code-toast](https://github.com/TianqiZhang/claude-code-toast).
> It **suppresses `idle_prompt` notifications** — the toast that fires when Claude has been
> sitting idle waiting for input. See [What this fork changes](#what-this-fork-changes).

## Features

- **Notification Hook**: Shows a toast notification when Claude Code sends notifications (e.g., asking for input, tool permission requests)
- **Stop Hook**: Shows a toast when Claude Code finishes responding

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
│   ├── toast-notification.ps1  # Notification handler (suppresses idle_prompt)
│   └── toast-stop.ps1          # Stop event handler
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
