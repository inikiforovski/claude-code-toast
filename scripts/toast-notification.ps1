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

Import-Module BurntToast -ErrorAction Stop

# Icon path relative to script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iconPath = Join-Path $scriptDir "..\assets\icon.png"

# Show notification with icon if available, otherwise without
if (Test-Path $iconPath) {
  New-BurntToastNotification -Text $title, $line1, $line2 -AppLogo $iconPath
} else {
  New-BurntToastNotification -Text $title, $line1, $line2
}
