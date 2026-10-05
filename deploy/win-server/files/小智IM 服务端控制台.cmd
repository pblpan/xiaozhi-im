@echo off
rem ============================================================
rem  XiaozhiIM Server Console - launcher (ASCII ONLY, keep bytes ASCII)
rem
rem  Double-clicked by the desktop shortcut. Starts the PowerShell
rem  WinForms console with NO window flash, then exits immediately.
rem  All the real logic lives in console.ps1 next to this file.
rem
rem  Why a launcher instead of pointing the shortcut straight at
rem  powershell.exe: this file can also do a friendly "missing file"
rem  message, and the shortcut stays valid even if we later change
rem  how the console is started.
rem ============================================================
setlocal
set "PS1=%~dp0console.ps1"
if not exist "%PS1%" (
  echo.
  echo   [X] console.ps1 not found next to this launcher:
  echo       %PS1%
  echo.
  echo   Please reinstall XiaozhiIM Server.
  echo.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0
