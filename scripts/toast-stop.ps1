# toast-stop.ps1
# Shows a clickable "Finished responding" toast when Claude Code stops.
# Clicking it raises the originating Windows Terminal window (see focus-session.ps1).

$raw = [Console]::In.ReadToEnd()
$data = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) { try { $data = $raw | ConvertFrom-Json } catch {} }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'toast-common.ps1')

# Ensure the claudetoast: handler exists; clicking the toast raises the Terminal window.
$launch = Get-SessionLaunchUri
Ensure-ToastActivation -ScriptDir $scriptDir

# Name the originating session so the user knows which tab finished.
$label = Get-SessionLabel -Cwd $data.cwd -TranscriptPath $data.transcript_path

$lines = @("Claude Code", "Finished responding")
if ($label) { $lines += $label }
Show-ClickableToast -Lines $lines -LaunchUri $launch -IconPath (Get-ToastIconPath -ScriptDir $scriptDir)
