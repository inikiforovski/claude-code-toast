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

function Get-SessionLaunchUri {
  # Build a protocol-activation URI carrying the current tab title (Claude's topic)
  # so the click handler can try to switch to the exact tab. Falls back to a bare
  # focus verb (raise a Terminal window) when no title is available.
  $title = ''
  try { $title = [Console]::Title } catch {}
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
