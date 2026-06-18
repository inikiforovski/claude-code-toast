# focus-session.ps1
# Protocol handler for the claudetoast: URL scheme, invoked when a toast is clicked.
# Raises (and un-minimizes) the Windows Terminal window that hosts the originating session.
#
# The toast's URI carries that window's HWND ("claudetoast:focus?hwnd=12345"), captured
# while the session was foregrounded (see capture-window.ps1). We raise that exact window,
# so the correct window comes up even with several Terminal windows open. If the HWND is
# missing or stale (window closed since), we fall back to the most-recently-active Terminal.
#
# Window-level only by design: a hook spawned under Git Bash can enumerate Terminal
# tabs via UI Automation but cannot identify or switch to its own tab (the console
# title it can set never reaches WT), so per-tab focus isn't reliable. The toast text
# names the originating session instead (see Get-SessionLabel in toast-common.ps1).
#
# Kept ASCII-only on purpose: the registry handler launches this under powershell.exe
# (Windows PowerShell 5.1), which reads a UTF-8-no-BOM .ps1 as cp1252 and would mangle
# any literal non-ASCII characters.
param([string]$Uri)

$WT_CLASS = 'CASCADIA_HOSTING_WINDOW_CLASS'

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WinFocus {
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int max);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);

  const int SW_RESTORE = 9;
  const int SW_SHOW = 5;

  public static void Force(IntPtr hWnd) {
    if (hWnd == IntPtr.Zero) return;
    if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
    IntPtr fg = GetForegroundWindow();
    uint pid;
    uint fgThread = GetWindowThreadProcessId(fg, out pid);
    uint thisThread = GetCurrentThreadId();
    bool attached = false;
    if (fgThread != 0 && fgThread != thisThread) { attached = AttachThreadInput(thisThread, fgThread, true); }
    SetForegroundWindow(hWnd);
    BringWindowToTop(hWnd);
    ShowWindow(hWnd, SW_SHOW);
    if (attached) AttachThreadInput(thisThread, fgThread, false);
  }

  public static List<IntPtr> ByClass(string cls) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256);
      GetClassName(h, sb, sb.Capacity);
      if (sb.ToString() == cls) list.Add(h);
      return true;
    }, IntPtr.Zero);
    return list;
  }

  public static bool IsClass(IntPtr h, string cls) {
    if (h == IntPtr.Zero || !IsWindow(h)) return false;
    var sb = new StringBuilder(256);
    GetClassName(h, sb, sb.Capacity);
    return sb.ToString() == cls;
  }
}
'@

# Prefer the exact window the toast carries (the session's own window). Parse hwnd=<n>
# from the URI and focus it only if it still exists and is a Terminal window.
$target = [IntPtr]::Zero
if ($Uri -and $Uri -match 'hwnd=(\d+)') {
  $h = [IntPtr][long]$Matches[1]
  if ([WinFocus]::IsClass($h, $WT_CLASS)) { $target = $h }
}

if ($target -ne [IntPtr]::Zero) {
  [WinFocus]::Force($target)
} else {
  # Fallback: no/stale HWND -> most-recently-active Terminal window.
  # EnumWindows returns top-of-Z-order first, i.e. the most recently active window.
  $wt = [WinFocus]::ByClass($WT_CLASS)
  if ($wt.Count -gt 0) { [WinFocus]::Force($wt[0]) }
}
exit 0
