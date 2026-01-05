# toast-notification.ps1
# Reads Claude Code hook JSON from stdin and shows a Windows toast with the notification message.

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try {
  $data = $raw | ConvertFrom-Json
} catch {
  exit 0
}

# Claude Code Notification input includes `message` and usually `notification_type`
# https://code.claude.com/docs/en/hooks (Notification Input)
$title = "Claude Code"
$line1 = if ($data.notification_type) { "Type: $($data.notification_type)" } else { "Notification" }
$line2 = if ($data.message) { [string]$data.message } else { "(no message)" }

# Icon path relative to script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iconPath = (Resolve-Path (Join-Path $scriptDir "..\assets\icon.png") -ErrorAction SilentlyContinue).Path

# Load Windows.UI.Notifications (native toast API)
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

# Escape XML special characters
function Escape-Xml($text) {
  return [System.Security.SecurityElement]::Escape($text)
}

# Build toast XML with or without icon
$imageXml = if (Test-Path $iconPath) {
  "<image placement=`"appLogoOverride`" src=`"file:///$($iconPath -replace '\\','/')`"/>"
} else { "" }

$toastXml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$(Escape-Xml $title)</text>
      <text>$(Escape-Xml $line1)</text>
      <text>$(Escape-Xml $line2)</text>
      $imageXml
    </binding>
  </visual>
</toast>
"@

# Show the toast notification
$xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
$xml.LoadXml($toastXml)
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
