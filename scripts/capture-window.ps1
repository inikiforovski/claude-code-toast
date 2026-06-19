# capture-window.ps1
# Run synchronously (blocking) by the UserPromptSubmit and SessionStart hooks. Records the
# foreground window HWND -- when it is a Windows Terminal window -- keyed by this session's
# WT_SESSION, so a later toast can raise the exact window the session lives in instead of just
# the most-recently-active Terminal.
#
# Why these events: at prompt-submit (and session start) the user is provably looking at this
# session's window, so GetForegroundWindow() is reliably *this* window. The Stop/Notification
# hooks fire precisely when the user may have switched away, so they can't capture it -- they
# read back what this hook stored (see Get-SessionWindowHwnd).
#
# Why SYNCHRONOUS, not detached: an earlier version launched this detached (via wscript) so the
# hook returned in ~30ms. But a detached helper does not read GetForegroundWindow() until the OS
# gets around to scheduling it -- which, while Claude is busy spinning up the turn, can be most of
# a second later. By then the user has often switched to another Terminal window, and since we
# only overwrite when the foreground is *also* a WT window, switching between Terminal windows
# reliably recorded the WRONG window (the toast then raised the last-active window, not this one).
# Running inline, Claude waits on us, so the read happens within ~one powershell-startup of submit
# -- while the user is still on this window. To keep that blocking time small we use reflection
# emit (DefinePInvokeMethod) instead of Add-Type: declaring the P/Invokes this way skips the C#
# compiler (csc), cutting the in-process cost from ~200-400ms to ~40ms.
#
# It has no useful stdin (it keys purely off the WT_SESSION env var, present iff we're under
# Windows Terminal -- the only host where focusing a window is meaningful).
#
# Kept ASCII-only on purpose: launched under powershell.exe (Windows PowerShell 5.1), which
# reads a UTF-8-no-BOM .ps1 as cp1252 and would mangle any literal non-ASCII characters.
$ErrorActionPreference = 'SilentlyContinue'
if ([string]::IsNullOrWhiteSpace($env:WT_SESSION)) { exit 0 }  # not Windows Terminal -> nothing to focus

# Only the session-store helpers are needed here -- dot-source just those, not all of
# toast-common.ps1, to keep this synchronous hook's blocking time down.
. (Join-Path $PSScriptRoot 'session-store.ps1')

# Reflection-emit P/Invoke for GetForegroundWindow + GetClassName. DefinePInvokeMethod declares
# the native imports without invoking the C# compiler, so this costs ~40ms instead of the
# ~200-400ms Add-Type spends running csc -- the difference that keeps the synchronous hook snappy.
$asm = [System.Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
  [System.Reflection.AssemblyName]::new('FgCap'),
  [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
$tb  = $asm.DefineDynamicModule('FgCap').DefineType('FgWin', 'Public, Class')

$m = $tb.DefinePInvokeMethod('GetForegroundWindow', 'user32.dll', 'Public, Static, PinvokeImpl',
  [System.Reflection.CallingConventions]::Standard, [IntPtr], @(),
  [System.Runtime.InteropServices.CallingConvention]::Winapi,
  [System.Runtime.InteropServices.CharSet]::Auto)
$m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)

$m = $tb.DefinePInvokeMethod('GetClassName', 'user32.dll', 'GetClassNameW', 'Public, Static, PinvokeImpl',
  [System.Reflection.CallingConventions]::Standard, [int],
  @([IntPtr], [System.Text.StringBuilder], [int]),
  [System.Runtime.InteropServices.CallingConvention]::Winapi,
  [System.Runtime.InteropServices.CharSet]::Unicode)
$m.SetImplementationFlags([System.Reflection.MethodImplAttributes]::PreserveSig)

$FgWin = $tb.CreateType()

$h = $FgWin::GetForegroundWindow()
if ($h -ne [IntPtr]::Zero) {
  $sb = New-Object System.Text.StringBuilder 256
  [void]$FgWin::GetClassName($h, $sb, $sb.Capacity)
  # Only record genuine Windows Terminal windows; otherwise keep any prior (correct) capture.
  if ($sb.ToString() -eq 'CASCADIA_HOSTING_WINDOW_CLASS') {
    Save-SessionWindowHwnd -Hwnd $h.ToInt64()
  }
}
exit 0
