@echo off
setlocal enabledelayedexpansion
call "%~dp0_env.cmd"

rem 按"谁在监听 3602"找进程，而不是 taskkill /IM node.exe ——
rem 客户机上很可能还有别的 node 程序（别的系统、别的脚本），
rem 按映像名杀会把它们一起干掉，属于不可接受的副作用。
set "PID="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%PORT% " ^| findstr "LISTENING"') do set "PID=%%a"

if not defined PID (
  echo.
  echo   服务端当前没有在运行。
  echo.
  pause
  exit /b 0
)

echo.
echo   正在停止服务端（进程号 !PID!）...
taskkill /F /PID !PID! >nul 2>&1
if "%ERRORLEVEL%"=="0" (
  echo   已停止。
) else (
  echo   停止失败 —— 多半是它当初以管理员身份启动的，请用管理员身份再跑一次本文件。
)
echo.
pause
