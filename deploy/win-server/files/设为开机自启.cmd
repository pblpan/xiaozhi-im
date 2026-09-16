@echo off
chcp 65001 >nul
call "%~dp0_env.cmd"
rem 写 HKCU\...\Run：登录 Windows 后自动在后台起服务端（不显示窗口）。
rem 用 HKCU 而不是 HKLM：用户级写入不需要管理员权限，卸载也好清。
set "VBS=%XZ_HOME%\后台启动服务端.vbs"
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "XiaozhiIMServer" /t REG_SZ /d "\"%VBS%\"" /f >nul 2>&1
if "%ERRORLEVEL%"=="0" (
  echo.
  echo   已设为开机自启：登录 Windows 后自动在后台运行。
  echo   注册表位置：HKCU\Software\Microsoft\Windows\CurrentVersion\Run → XiaozhiIMServer
  echo.
  echo   注意：它随**用户登录**启动。如果这台电脑开机后没人登录，
  echo         服务不会自己起来 —— 请让机器自动登录，或把它做成 Windows 服务。
  echo.
) else (
  echo.
  echo   设置失败，请以管理员身份重试。
  echo.
)
pause
