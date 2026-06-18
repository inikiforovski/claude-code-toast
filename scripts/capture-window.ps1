# capture-window.ps1
# Launched detached (and hidden) by capture-launch.vbs from the UserPromptSubmit and
# SessionStart hooks. Records the foreground window HWND -- when it is a Windows Terminal
# window -- keyed by this session's WT_SESSION, so a later toast can raise the exact window
# the session lives in instead of just the most-recently-active Terminal.
#
# Why these events: at prompt-submit (and session start) the user is provably looking at this
# session's window, so GetForegroundWindow() is reliably *this* window. The Stop/Notification
# hooks fire precisely when the user may have switched away, so they can't capture it -- they
# read back what this hook stored (see Get-SessionWindowHwnd).
#
# Runs detached so the UserPromptSubmit hook adds no perceptible latency. It therefore has no
# stdin and keys purely off the WT_SESSION env var (present iff we're under Windows Terminal,
# which is the only host where focusing a window is meaningful).
#
# Kept ASCII-only on purpose: launched under powershell.exe (Windows PowerShell 5.1), which
# reads a UTF-8-no-BOM .ps1 as cp1252 and would mangle any literal non-ASCII characters.
$ErrorActionPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($env:WT_SESSION)) { exit 0 }  # not Windows Terminal -> nothing to focus

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'toast-common.ps1')

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FgWin {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int max);
}
'@

$h = [FgWin]::GetForegroundWindow()
if ($h -ne [IntPtr]::Zero) {
  $sb = New-Object System.Text.StringBuilder 256
  [FgWin]::GetClassName($h, $sb, $sb.Capacity) | Out-Null
  # Only record genuine Windows Terminal windows; otherwise keep any prior (correct) capture.
  if ($sb.ToString() -eq 'CASCADIA_HOSTING_WINDOW_CLASS') {
    Save-SessionWindowHwnd -Hwnd $h.ToInt64()
  }
}
exit 0
