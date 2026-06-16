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
  # Mechanism: momentarily stamp a unique token into our own title (which DOES
  # propagate through ConPTY to our WT tab regardless of focus/minimize), find which
  # tab now shows the token via UIA, read that tab's real topic from a pre-stamp
  # snapshot, then restore the title. Returns '' on any failure so the caller can fall
  # back to [Console]::Title. Kept ASCII-only (\p{So}/\p{Cf} strip Claude's leading
  # status glyph without any literal non-ASCII in this file).
  $orig = ''
  try { $orig = [Console]::Title } catch {}
  $restoreTo = $orig
  $topic = ''
  try {
    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]
    $winCond = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $tabCond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
    $wins = $AE::RootElement.FindAll($TS::Children, $winCond)
    if ($wins.Count -eq 0) { return '' }

    # Snapshot every tab's RuntimeId -> raw name BEFORE stamping (so we can recover our
    # tab's real topic once we learn which RuntimeId is ours).
    $snap = @{}
    foreach ($w in $wins) {
      foreach ($tb in $w.FindAll($TS::Descendants, $tabCond)) {
        $snap[(($tb.GetRuntimeId()) -join '.')] = $tb.Current.Name
      }
    }
    if ($snap.Count -eq 0) { return '' }

    # Re-stamp each iteration: Claude re-asserts its title roughly every 100ms while a
    # prompt is running, so a single stamp can be reverted before we read it.
    $token = "CCToastFocus_${PID}_$([DateTime]::UtcNow.Ticks)"
    $tokCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $token)
    $foundRid = $null
    for ($i = 0; $i -lt 10 -and -not $foundRid; $i++) {
      try { [Console]::Title = $token } catch {}
      Start-Sleep -Milliseconds 25
      foreach ($w in $wins) {
        $hit = $w.FindFirst($TS::Descendants, $tokCond)
        if ($hit) { $foundRid = (($hit.GetRuntimeId()) -join '.'); break }
      }
    }

    if ($foundRid -and $snap.ContainsKey($foundRid)) {
      $raw = [string]$snap[$foundRid]
      $topic = ($raw -replace '^[\s\p{So}\p{Cf}]+', '').Trim()
      if ($topic) { $restoreTo = $topic }
    }
  } catch {
    $topic = ''
  } finally {
    # Never leave our tab showing the token. Restore to the recovered topic (clean) or,
    # if we never identified it, to whatever the title was before we stamped.
    try { if ($null -ne $restoreTo) { [Console]::Title = $restoreTo } } catch {}
  }
  return $topic
}

function Get-SessionLaunchUri {
  # Build a protocol-activation URI carrying the originating tab title (Claude's topic)
  # so the click handler can switch to the exact tab. Falls back to [Console]::Title,
  # then to a bare focus verb (raise a Terminal window) when no title is available.
  $title = Get-OriginatingTabTitle
  if ([string]::IsNullOrEmpty($title)) {
    try { $title = [Console]::Title } catch { $title = '' }
  }
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
