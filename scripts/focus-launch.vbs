' focus-launch.vbs
' Launches focus-session.ps1 with no visible window, so clicking a toast does not
' flash a PowerShell console. WScript.Shell.Run with window style 0 starts the
' process hidden (SW_HIDE in STARTUPINFO) from the first instant, which avoids the
' conhost flash that powershell.exe -WindowStyle Hidden alone cannot prevent.
Option Explicit
Dim sh, dir, ps, uri, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps = dir & "focus-session.ps1"
uri = ""
If WScript.Arguments.Count > 0 Then uri = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """ """ & uri & """"
sh.Run cmd, 0, False
