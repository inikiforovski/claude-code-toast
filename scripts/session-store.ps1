# session-store.ps1
# The per-session window-HWND store: a tiny file per session under
# %LOCALAPPDATA%\claude-code-toast\sessions\, keyed by Get-SessionStoreKey.
#
# Dot-sourced by BOTH sides so the key derivation is defined exactly once:
#   - capture-window.ps1 (writer) records this session's foreground window here.
#   - toast-common.ps1   (reader) reads it back to target the toast's click.
# Keeping this in its own small file lets the capture hook -- which runs synchronously on every
# prompt submit -- dot-source just this (~40 lines) instead of all of toast-common.ps1, shaving
# ~150ms off the blocking time while leaving the read/write key logic a single source of truth.
#
# Kept ASCII-only: loaded under Windows PowerShell 5.1 (cp1252), which would mangle non-ASCII.

$script:ToastStableDir  = Join-Path $env:LOCALAPPDATA 'claude-code-toast'
$script:ToastSessionDir = Join-Path $script:ToastStableDir 'sessions'

function Get-SessionStoreKey {
  # Stable per-session key shared by the capture hook (which records the window) and the
  # toast hooks (which read it back). WT_SESSION is a per-pane GUID inherited by every hook
  # of the same Terminal session -- ideal. Fall back to Claude's session_id when WT_SESSION
  # is absent (e.g. a non-Windows-Terminal host, where there's no WT window to focus anyway).
  param([string]$SessionId)
  $key = $env:WT_SESSION
  if ([string]::IsNullOrWhiteSpace($key)) { $key = $SessionId }
  if ([string]::IsNullOrWhiteSpace($key)) { return '' }
  return ($key -replace '[^A-Za-z0-9_.-]', '_')
}

function Save-SessionWindowHwnd {
  # Persist the window HWND that hosts this session, keyed by Get-SessionStoreKey. One tiny
  # file per session (race-free: concurrent sessions write distinct files). The capture hook
  # keys off the WT_SESSION env var, so SessionId is usually omitted -- WT_SESSION is what
  # both sides agree on.
  param([long]$Hwnd, [string]$SessionId = '')
  $key = Get-SessionStoreKey -SessionId $SessionId
  if (-not $key -or $Hwnd -eq 0) { return }
  try {
    if (-not (Test-Path $script:ToastSessionDir)) {
      New-Item -ItemType Directory -Path $script:ToastSessionDir -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $script:ToastSessionDir "$key.txt") -Value ([string]$Hwnd) -Encoding ASCII
  } catch {}
}

function Get-SessionWindowHwnd {
  # Read back the HWND recorded by the capture hook for this session, or 0 if none.
  param([string]$SessionId)
  $key = Get-SessionStoreKey -SessionId $SessionId
  if (-not $key) { return 0 }
  $f = Join-Path $script:ToastSessionDir "$key.txt"
  if (-not (Test-Path $f)) { return 0 }
  try {
    $v = (Get-Content -LiteralPath $f -TotalCount 1 -ErrorAction Stop).Trim()
    $n = [long]0
    if ([long]::TryParse($v, [ref]$n)) { return $n }
  } catch {}
  return 0
}
