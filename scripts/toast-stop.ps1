# toast-stop.ps1
# Shows a clickable "Finished responding" toast when Claude Code stops.
# Clicking it raises the originating Windows Terminal window (see focus-session.ps1).

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'toast-common.ps1')

# Capture the launch URI (current tab title) and ensure the claudetoast: handler exists.
$launch = Get-SessionLaunchUri
Ensure-ToastActivation -ScriptDir $scriptDir

Show-ClickableToast -Lines @("Claude Code", "Finished responding") -LaunchUri $launch -IconPath (Get-ToastIconPath -ScriptDir $scriptDir)
