# toast-common.ps1
# Shared helpers for claude-code-toast: clickable-toast activation + rendering.
# Dot-sourced by toast-notification.ps1 and toast-stop.ps1.

$script:ToastAppId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$script:ToastProtocol = 'claudetoast'
$script:ToastStableDir = Join-Path $env:LOCALAPPDATA 'claude-code-toast'

function Escape-Xml($text) {
  return [System.Security.SecurityElement]::Escape([string]$text)
}

function Get-ToastIconPath {
  param([string]$ScriptDir)
  return (Resolve-Path (Join-Path $ScriptDir "..\assets\icon.png") -ErrorAction SilentlyContinue).Path
}

function ConvertTo-Base64Url {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $b = [System.Text.Encoding]::UTF8.GetBytes($Text)
  return ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Write-CaptureLog {
  # Opt-in hook-side diagnostics: only writes when %LOCALAPPDATA%\claude-code-toast\debug
  # exists (same marker the click handler uses). Off by default for released installs.
  param([string]$Msg)
  try {
    if (-not (Test-Path (Join-Path $script:ToastStableDir 'debug'))) { return }
    $log = Join-Path $script:ToastStableDir 'hook-capture.log'
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg) -Encoding UTF8
  } catch {}
}

function Set-OwnTabTitleRaw {
  # Stamp a title into THIS tab using BOTH channels, because which one actually reaches
  # the Windows Terminal tab depends on how the hook was spawned:
  #   1) SetConsoleTitle API  -- works when on a direct ConPTY
  #   2) OSC escape to CONOUT$ -- works through the terminal byte stream (same channel
  #      Claude itself uses), bypassing a redirected/piped stdout
  param([string]$Title)
  try { [Console]::Title = $Title } catch {}
  try {
    if (-not ('CCToastConsole' -as [type])) {
      Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CCToastConsole {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string n, uint a, uint s, IntPtr sec, uint d, uint f, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool CloseHandle(IntPtr h);
}
'@
    }
    $h = [CCToastConsole]::CreateFileW('CONOUT$', 0x40000000, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    if ($h -ne [IntPtr]-1 -and $h -ne [IntPtr]::Zero) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes("$([char]27)]0;$Title$([char]7)")
      $w = 0
      [CCToastConsole]::WriteFile($h, $bytes, [uint32]$bytes.Length, [ref]$w, [IntPtr]::Zero) | Out-Null
      [CCToastConsole]::CloseHandle($h) | Out-Null
    }
  } catch {}
}

function Get-OriginatingTabTitle {
  # Return THIS session's Windows Terminal tab title (Claude's topic) even when the tab
  # is inactive or the window is minimized.
  #
  # Why not just [Console]::Title? Subprocesses overwrite the console-title buffer:
  # the Bash tool runs git's bash.exe, which calls SetConsoleTitleW("...\bash.exe"),
  # so by the time a hook fires [Console]::Title is usually an exe path, not the topic.
  # Claude sets the *tab* title via an OSC escape (a separate channel) -- that is what
  # UI Automation reads, and what the click handler must match against.
  #
  # Mechanism: momentarily stamp a unique token into our own title (which propagates to
  # our WT tab regardless of focus/minimize), find which tab now shows the token via
  # UIA, read that tab's real topic from a pre-stamp snapshot, then restore the title.
  # Returns '' on any failure so the caller can fall back to [Console]::Title. ASCII-only
  # (\p{So}/\p{Cf} strip Claude's leading status glyph without literal non-ASCII here).
  $orig = ''
  try { $orig = [Console]::Title } catch {}
  $restoreTo = $orig
  $topic = ''
  $dWins = 0; $dSnap = 0; $dFound = ''; $dErr = ''
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]
    $winCond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $tabCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $wins = $AE::RootElement.FindAll($TS::Children, $winCond)
    $dWins = $wins.Count
    if ($wins.Count -gt 0) {
      # Snapshot every tab's RuntimeId -> raw name BEFORE stamping (so we can recover
      # our tab's real topic once we learn which RuntimeId is ours).
      $snap = @{}
      foreach ($w in $wins) {
        foreach ($tb in $w.FindAll($TS::Descendants, $tabCond)) {
          $snap[(($tb.GetRuntimeId()) -join '.')] = $tb.Current.Name
        }
      }
      $dSnap = $snap.Count
      if ($snap.Count -gt 0) {
        # Re-stamp each iteration: Claude re-asserts its title periodically, so a single
        # stamp can be reverted before we read it.
        $token = "CCToastFocus_${PID}_$([DateTime]::UtcNow.Ticks)"
        $tokCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $token)
        $foundRid = $null
        for ($i = 0; $i -lt 12 -and -not $foundRid; $i++) {
          Set-OwnTabTitleRaw $token
          Start-Sleep -Milliseconds 30
          foreach ($w in $wins) {
            $hit = $w.FindFirst($TS::Descendants, $tokCond)
            if ($hit) { $foundRid = (($hit.GetRuntimeId()) -join '.'); break }
          }
        }
        $dFound = "$foundRid"
        if ($foundRid -and $snap.ContainsKey($foundRid)) {
          $raw = [string]$snap[$foundRid]
          $topic = ($raw -replace '^[\s\p{So}\p{Cf}]+', '').Trim()
          if ($topic) { $restoreTo = $topic }
        }
      }
    }
  } catch {
    $dErr = $_.Exception.Message
    $topic = ''
  } finally {
    # Never leave our tab showing the token. Restore to the recovered topic (clean) or,
    # if we never identified it, to whatever the title was before we stamped.
    try { if ($null -ne $restoreTo) { Set-OwnTabTitleRaw $restoreTo } } catch {}
    Write-CaptureLog ("capture: psv={0} wins={1} snap={2} found='{3}' topic='{4}' err='{5}'" -f $PSVersionTable.PSVersion, $dWins, $dSnap, $dFound, $topic, $dErr)
  }
  return $topic
}

function Get-SessionLaunchUri {
  # Build a protocol-activation URI carrying the originating tab title (Claude's topic)
  # so the click handler can switch to the exact tab. Falls back to [Console]::Title,
  # then to a bare focus verb (raise a Terminal window) when no title is available.
  $consoleBefore = ''
  try { $consoleBefore = [Console]::Title } catch {}
  $captured = Get-OriginatingTabTitle
  $title = $captured
  if ([string]::IsNullOrEmpty($title)) {
    try { $title = [Console]::Title } catch { $title = '' }
  }
  Write-CaptureLog ("launch: consoleBefore='{0}' captured='{1}' final='{2}'" -f $consoleBefore, $captured, $title)
  $enc = ConvertTo-Base64Url $title
  if ([string]::IsNullOrEmpty($enc)) { return "$($script:ToastProtocol):focus" }
  return "$($script:ToastProtocol):focus?t=$enc"
}

function Ensure-ToastActivation {
  # Best-effort: never let activation setup block (or break) the toast itself.
  param([string]$ScriptDir)
  try {
    # 1. Copy the handler + its hidden launcher to a stable path. The registry handler
    #    needs a fixed target, but the plugin cache path changes on every reinstall /
    #    version bump. Hash-gated so we only write when the content actually changed.
    if (-not (Test-Path $script:ToastStableDir)) {
      New-Item -ItemType Directory -Path $script:ToastStableDir -Force | Out-Null
    }
    foreach ($name in @('focus-session.ps1', 'focus-launch.vbs')) {
      $s = Join-Path $ScriptDir $name
      $d = Join-Path $script:ToastStableDir $name
      if (Test-Path $s) {
        $needCopy = $true
        if (Test-Path $d) {
          $needCopy = (Get-FileHash $s -Algorithm SHA256).Hash -ne (Get-FileHash $d -Algorithm SHA256).Hash
        }
        if ($needCopy) { Copy-Item $s $d -Force }
      }
    }

    # 2. Register the URL-protocol handler under HKCU (no admin required). Launch via
    #    wscript.exe + a .vbs shim so PowerShell starts hidden (SW_HIDE) from the first
    #    instant - this avoids the console flash -WindowStyle Hidden alone can't prevent.
    $vbs    = Join-Path $script:ToastStableDir 'focus-launch.vbs'
    $cmd    = "wscript.exe `"$vbs`" `"%1`""
    $base   = "HKCU:\Software\Classes\$($script:ToastProtocol)"
    $cmdKey = "$base\shell\open\command"
    $existing = $null
    try { $existing = (Get-ItemProperty -Path $cmdKey -ErrorAction Stop).'(default)' } catch {}
    if ($existing -ne $cmd) {
      New-Item -Path $cmdKey -Force | Out-Null
      Set-ItemProperty -Path $base   -Name '(default)'    -Value 'URL:Claude Toast Focus'
      Set-ItemProperty -Path $base   -Name 'URL Protocol' -Value ''
      Set-ItemProperty -Path $cmdKey -Name '(default)'    -Value $cmd
    }
  } catch {
    # swallow - a missing click handler just means the toast isn't clickable
  }
}

function Show-ClickableToast {
  param(
    [string[]]$Lines,
    [string]$LaunchUri,
    [string]$IconPath
  )
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

  $textXml  = ($Lines | ForEach-Object { "      <text>$(Escape-Xml $_)</text>" }) -join "`n"
  $imageXml = if ($IconPath -and (Test-Path $IconPath)) {
    "<image placement=`"appLogoOverride`" src=`"file:///$($IconPath -replace '\\','/')`"/>"
  } else { "" }
  $launchAttr = if ($LaunchUri) { " launch=`"$(Escape-Xml $LaunchUri)`" activationType=`"protocol`"" } else { "" }

  $toastXml = @"
<toast$launchAttr>
  <visual>
    <binding template="ToastGeneric">
$textXml
      $imageXml
    </binding>
  </visual>
</toast>
"@

  $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
  $xml.LoadXml($toastXml)
  $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:ToastAppId).Show($toast)
}
