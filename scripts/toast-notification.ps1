# toast-notification.ps1
# Reads Claude Code hook JSON from stdin and shows a clickable Windows toast.
# Clicking the toast raises the originating Windows Terminal window (see focus-session.ps1).

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try {
  $data = $raw | ConvertFrom-Json
} catch {
  exit 0
}

# Notification types to suppress (no toast shown). `idle_prompt` fires when Claude
# has been waiting for input for a while - not useful for tracking when to refocus.
$suppressedTypes = @('idle_prompt')
if ($data.notification_type -and $suppressedTypes -contains $data.notification_type) { exit 0 }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'toast-common.ps1')

# Capture the launch URI (current tab title) and ensure the claudetoast: handler exists.
$launch = Get-SessionLaunchUri
Ensure-ToastActivation -ScriptDir $scriptDir

# Claude Code Notification input includes `message` and usually `notification_type`
# https://code.claude.com/docs/en/hooks (Notification Input)
$message = if ($data.message) { [string]$data.message } else { "(no message)" }

# Name the originating session so the user knows which tab needs attention.
$label = Get-SessionLabel -Cwd $data.cwd -TranscriptPath $data.transcript_path

# Keep to 3 text lines total (title + 2 body): the Windows toast popup only renders
# three lines, so a 4th was silently dropped -- which is why the session label never
# showed here even though the Stop toast (also 3 lines) shows it. The `message` already
# conveys what the old "Type: ..." line did, so we drop it to make room for the label.
$lines = @("Claude Code", $message)
if ($label) { $lines += $label }
Show-ClickableToast -Lines $lines -LaunchUri $launch -IconPath (Get-ToastIconPath -ScriptDir $scriptDir)
