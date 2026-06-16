# focus-session.ps1
# Protocol handler for the claudetoast: URL scheme, invoked when a toast is clicked.
# Brings the originating Windows Terminal window to the foreground, and switches to
# the exact tab when its title still matches Claude's topic (i.e. the tab hasn't been
# manually renamed). Otherwise it just raises the top-most Terminal window.
#
# Kept ASCII-only on purpose: the registry handler launches this under powershell.exe
# (Windows PowerShell 5.1), which reads a UTF-8-no-BOM .ps1 as cp1252 and would mangle
# any literal non-ASCII characters.
param([string]$Uri)

$WT_CLASS = 'CASCADIA_HOSTING_WINDOW_CLASS'

# --- Win32 window helpers (foreground + class enumeration) ---
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
}
'@

function Get-TargetTitle {
  param([string]$Uri)
  if ([string]::IsNullOrEmpty($Uri)) { return '' }
  $idx = $Uri.IndexOf('?')
  if ($idx -lt 0) { return '' }
  $query = $Uri.Substring($idx + 1)
  foreach ($pair in $query.Split('&')) {
    $kv = $pair.Split('=', 2)
    if ($kv[0] -eq 't' -and $kv.Count -eq 2) {
      # protocol activation can append a trailing slash; strip it before decoding
      $b = $kv[1].Trim().TrimEnd('/').Replace('-', '+').Replace('_', '/')
      switch ($b.Length % 4) { 2 { $b += '==' } 3 { $b += '=' } }
      try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) } catch { return '' }
    }
  }
  return ''
}

function Normalize-Title {
  # Strip Claude Code's leading status glyph plus surrounding whitespace, then
  # lower-case for comparison. The animated braille spinner (U+2800-U+28FF) and the
  # idle marker are all Unicode category So (Symbol, other), so \p{So} matches them
  # without needing any literal non-ASCII in this script. \p{Cf} catches format chars.
  param([string]$Title)
  if ([string]::IsNullOrEmpty($Title)) { return '' }
  $t = $Title -replace '^[\s\p{So}\p{Cf}]+', ''
  return $t.Trim().ToLowerInvariant()
}

# --- Resolve the target window/tab via UI Automation ---
$target = Normalize-Title (Get-TargetTitle $Uri)

$matchedHwnd = [IntPtr]::Zero
$matchedTab  = $null
if ($target) {
  try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $AE = [System.Windows.Automation.AutomationElement]
    $winCond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $WT_CLASS)
    $wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
    $tabCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    foreach ($w in $wins) {
      foreach ($tb in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)) {
        if ((Normalize-Title $tb.Current.Name) -eq $target) {
          $matchedHwnd = [IntPtr]$w.Current.NativeWindowHandle
          $matchedTab  = $tb
          break
        }
      }
      if ($matchedTab) { break }
    }
  } catch {}
}

if ($matchedTab) {
  try {
    $matchedTab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
  } catch {}
  [WinFocus]::Force($matchedHwnd)
  exit 0
}

# Fallback: no tab matched (renamed tab, topic changed, etc.) -- raise a Terminal
# window. EnumWindows returns top-of-Z-order first, i.e. the most recently active.
$wt = [WinFocus]::ByClass($WT_CLASS)
if ($wt.Count -gt 0) { [WinFocus]::Force($wt[0]) }
exit 0
