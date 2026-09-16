@echo off
chcp 65001 >nul
call "%~dp0_env.cmd"
set "LOG=%XZ_DATA%\logs\server.log"
if not exist "%LOG%" (
  echo.
  echo   还没有日志文件（%LOG%）—— 服务端可能从未在后台启动过。
  echo.
  pause
  exit /b 0
)
rem 直接打开日志文件（用记事本）。文件很大时记事本会慢，但这里只是为了
rem "客户的电脑上不装任何东西也能看日志"，够用。
start "" notepad "%LOG%"
