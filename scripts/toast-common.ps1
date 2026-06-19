# toast-common.ps1
# Shared helpers for claude-code-toast: clickable-toast activation + rendering.
# Dot-sourced by toast-notification.ps1 and toast-stop.ps1.

# The session window-HWND store (Get-/Save-SessionWindowHwnd, Get-SessionStoreKey, and the
# $script:ToastStableDir / $script:ToastSessionDir paths) lives in session-store.ps1, shared
# verbatim with the capture hook so both sides derive the key the same way.
. (Join-Path $PSScriptRoot 'session-store.ps1')

$script:ToastAppId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$script:ToastProtocol = 'claudetoast'

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

function Get-SessionLabel {
  # Build a short, human-readable identifier for THIS Claude session so the toast can
  # tell the user which tab it belongs to. (We focus only at window level on click -- a
  # hook spawned under Git Bash can enumerate Terminal tabs via UIA but cannot identify
  # or switch to its own tab; see README. Naming the tab is the next best thing.)
  #
  # Uses only what the hook can reliably read -- its stdin fields and the transcript
  # file (file reads work in the hook; only writes to its own Terminal tab do not):
  #   - folder: basename of cwd (the project)
  #   - topic : the first real user prompt from the transcript -- what Claude bases the
  #             tab title on -- with command/caveat wrappers skipped and truncated.
  param([string]$Cwd, [string]$TranscriptPath)

  $folder = ''
  if ($Cwd) { try { $folder = Split-Path -Leaf $Cwd } catch {} }

  $topic = ''
  if ($TranscriptPath -and (Test-Path $TranscriptPath)) {
    try {
      foreach ($line in (Get-Content -LiteralPath $TranscriptPath -TotalCount 200 -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.isMeta -or $o.type -ne 'user' -or -not $o.message -or $o.message.role -ne 'user') { continue }
        $c = $o.message.content
        $text = ''
        if ($c -is [string]) { $text = $c }
        else { foreach ($part in $c) { if ($part.type -eq 'text' -and $part.text) { $text = [string]$part.text; break } } }
        $text = $text.Trim()
        # skip slash-command / local-command wrappers, caveat blocks, and empty turns
        if (-not $text -or $text -match '^\s*<' -or $text -match '^Caveat:') { continue }
        $topic = ($text -replace '\s+', ' ').Trim()
        break
      }
    } catch {}
  }
  if ($topic.Length -gt 70) { $topic = $topic.Substring(0, 67) + '...' }

  if ($folder -and $topic) { return "$folder - $topic" }
  if ($topic) { return $topic }
  return $folder
}

function Get-SessionLaunchUri {
  # Clicking the toast raises the Terminal *window* that hosts this session. When the
  # capture hook (UserPromptSubmit/SessionStart) recorded that window's HWND, we carry it
  # so the click targets the exact window even with several Terminal windows open. Without
  # it (no capture yet, or a non-WT host) we fall back to the most-recently-active window.
  #
  # Tab-level focus is still out of scope: a hook spawned under Git Bash can enumerate tabs
  # via UIA but cannot identify or switch to its own tab (see README). The toast names the
  # session so the user can pick the right tab once the window is up.
  param([long]$Hwnd = 0)
  if ($Hwnd -ne 0) { return "$($script:ToastProtocol):focus?hwnd=$Hwnd" }
  return "$($script:ToastProtocol):focus"
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
