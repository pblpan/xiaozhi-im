' ============================================================
'  XiaozhiIM Server - start in background (no window at all)
'
'  Why VBS: on Windows, the lightest way to run a console program
'  with NO window flash (and without pulling in a third-party tool)
'  is WScript.Shell.Run(..., 0, False).  "cmd /c start" always
'  flashes a black window - which is exactly what you do not want
'  during logon autostart.
'
'  Run() arg 2 = 0 -> hidden window; arg 3 = False -> do not wait.
'
'  NOTE: keep this file pure ASCII.  wscript.exe reads .vbs using the
'  system ANSI codepage, so non-ASCII comments here would be read as
'  garbage (harmless, but pointless) - and it is one less encoding
'  question to worry about when the whole toolchain is UTF-8.
' ============================================================
Option Explicit
Dim sh, fso, here
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
sh.Run """" & here & "\_hidden.cmd""", 0, False
