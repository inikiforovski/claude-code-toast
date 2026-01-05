# claude-code-toast

Windows toast notifications for [Claude Code](https://claude.ai/code) events using [BurntToast](https://github.com/Windos/BurntToast).

## Features

- **Notification Hook**: Shows a toast notification when Claude Code sends notifications (e.g., asking for input, tool permission requests)
- **Stop Hook**: Shows a toast when Claude Code finishes responding

## Prerequisites

- Windows 10/11
- PowerShell 5.1+
- [BurntToast](https://github.com/Windos/BurntToast) PowerShell module

Install BurntToast:

```powershell
Install-Module -Name BurntToast -Scope CurrentUser
```

## Installation

### Option 1: Via Plugin Marketplace (Recommended)

First, add the marketplace:

```bash
/plugin marketplace add TianqiZhang/claude-code-toast
```

Then install the plugin:

```bash
/plugin install toast-notifications@claude-code-toast
```

### Option 2: Direct Plugin Install

```bash
/plugin install TianqiZhang/claude-code-toast
```

### Option 3: Local Installation (for development)

```bash
/plugin marketplace add F:\claude\claude-code-toast
/plugin install toast-notifications@claude-code-toast
```

## Usage

Once installed, the plugin automatically:

1. Shows a toast notification when Claude Code needs your attention
2. Shows a "Finished responding" toast when Claude completes a response

## Hook Events

| Event | Description |
|-------|-------------|
| `Notification` | Triggered when Claude Code sends a notification |
| `Stop` | Triggered when Claude Code finishes responding |

## Project Structure

```
claude-code-toast/
├── .claude-plugin/
│   ├── plugin.json         # Plugin manifest
│   └── marketplace.json    # Marketplace manifest
├── hooks/
│   └── hooks.json          # Hook configuration
├── scripts/
│   ├── toast-notification.ps1  # Notification handler
│   └── toast-stop.ps1          # Stop event handler
├── LICENSE
└── README.md
```

## For Marketplace Maintainers

This repo serves as both a plugin and a marketplace. To add more plugins in the future, edit `.claude-plugin/marketplace.json`.

## License

MIT
