# toast-stop.ps1
Import-Module BurntToast -ErrorAction SilentlyContinue

# Icon path relative to script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$iconPath = Join-Path $scriptDir "..\assets\icon.png"

# Show notification with icon if available, otherwise without
if (Test-Path $iconPath) {
  New-BurntToastNotification -Text "Claude Code", "Finished responding" -AppLogo $iconPath
} else {
  New-BurntToastNotification -Text "Claude Code", "Finished responding"
}
