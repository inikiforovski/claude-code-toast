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

  // Un-minimize without stealing focus/Z-order. Needed before reading a Terminal's
  // tabs: while minimized, Windows Terminal does not realize its XAML tab strip, so
  // UI Automation finds zero TabItems and tab matching silently fails.
  public static void Restore(IntPtr hWnd) {
    if (hWnd == IntPtr.Zero) return;
    if (IsIconic(hWnd)) ShowWindow(hWnd, SW_RESTORE);
  }

  public static bool Iconic(IntPtr hWnd) { return IsIconic(hWnd); }

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

# --- Optional diagnostics ---------------------------------------------------
# Logging is opt-in: create an empty file named 'debug' in the stable dir
#   %LOCALAPPDATA%\claude-code-toast\debug
# to capture what the handler sees on each click (window list, tab names, the
# code path taken). Off by default so released installs stay silent.
$LogPath = $null
try {
  $dbgDir  = Join-Path $env:LOCALAPPDATA 'claude-code-toast'
  if (Test-Path (Join-Path $dbgDir 'debug')) { $LogPath = Join-Path $dbgDir 'focus-session.log' }
} catch {}
function Log {
  param([string]$Msg)
  if (-not $LogPath) { return }
  try { Add-Content -Path $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg) -Encoding UTF8 } catch {}
}

# --- Resolve the target window/tab via UI Automation -------------------------
$target = Normalize-Title (Get-TargetTitle $Uri)
Log "--- click: uri='$Uri' target='$target' ---"

$uiaReady = $false
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $uiaReady = $true
} catch { Log "UIA load failed: $_" }

function Find-MatchingTab {
  # Returns a hashtable @{ Hwnd; Tab } for the first TabItem whose normalized name
  # equals $target, or $null. Re-queries UIA fresh each call so it can be retried
  # after a window is restored (its tab strip only realizes once un-minimized).
  param([string]$target)
  if (-not $uiaReady -or -not $target) { return $null }
  $AE = [System.Windows.Automation.AutomationElement]
  $winCond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $WT_CLASS)
  $wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)
  $tabCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
  foreach ($w in $wins) {
    $h = [IntPtr]$w.Current.NativeWindowHandle
    $names = @()
    $found = $null
    foreach ($tb in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)) {
      $n = Normalize-Title $tb.Current.Name
      $names += $n
      if (-not $found -and $n -eq $target) { $found = $tb }
    }
    Log ("  win {0} iconic={1} tabs=[{2}]" -f $h, ([WinFocus]::Iconic($h)), ($names -join ' | '))
    if ($found) { return @{ Hwnd = $h; Tab = $found } }
  }
  return $null
}

$match = $null
if ($target) { try { $match = Find-MatchingTab $target } catch { Log "search 1 error: $_" } }

# Miss on the first pass is usually a minimized Terminal whose tab strip hasn't been
# realized. Un-minimize every Terminal window, then retry the search a few times to
# let XAML build the tab elements.
if (-not $match -and $target) {
  $wts = [WinFocus]::ByClass($WT_CLASS)
  $restored = $false
  foreach ($h in $wts) { if ([WinFocus]::Iconic($h)) { [WinFocus]::Restore($h); $restored = $true } }
  Log "first pass miss; restored minimized windows=$restored count=$($wts.Count)"
  if ($restored) {
    for ($i = 0; $i -lt 10 -and -not $match; $i++) {
      Start-Sleep -Milliseconds 100
      try { $match = Find-MatchingTab $target } catch { Log "search 2 error: $_" }
    }
  }
}

if ($match) {
  # Raise the window first, THEN select the tab. SelectionItemPattern.Select() is
  # unreliable while the window is still animating out of the minimized state, so
  # retry until the tab reports selected.
  Log "matched hwnd=$($match.Hwnd) -> force + select"
  [WinFocus]::Force($match.Hwnd)
  try {
    $sel = $match.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    for ($i = 0; $i -lt 20; $i++) {
      try {
        $sel.Select()
        if ($sel.Current.IsSelected) { break }
      } catch {}
      Start-Sleep -Milliseconds 25
    }
  } catch { Log "select error: $_" }
  exit 0
}

# Fallback: no tab matched (renamed tab, topic changed, etc.) -- raise a Terminal
# window. EnumWindows returns top-of-Z-order first, i.e. the most recently active.
Log "no match -> fallback raise top window"
$wt = [WinFocus]::ByClass($WT_CLASS)
if ($wt.Count -gt 0) { [WinFocus]::Force($wt[0]) }
exit 0
