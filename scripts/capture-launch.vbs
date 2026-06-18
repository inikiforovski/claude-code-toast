' capture-launch.vbs
' Launches capture-window.ps1 hidden and returns immediately, so the UserPromptSubmit /
' SessionStart hook adds no perceptible latency (wscript returns in ~30ms vs ~230ms+ for a
' blocking powershell hook). WScript.Shell.Run with window style 0 and bWaitOnReturn=False
' starts the capture detached and hidden, so no console flashes. The capture needs no
' arguments or stdin -- it reads the WT_SESSION env var (inherited here) and the live
' foreground window.
Option Explicit
Dim sh, dir, ps, cmd
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps = dir & "capture-window.ps1"
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps & """"
sh.Run cmd, 0, False
