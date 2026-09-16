@echo off
chcp 65001 >nul
rem ============================================================
rem  装完第一次点这个：后台起服务端 → 等服务端就绪 → 打开管理后台
rem  安装程序的「完成」页上那个勾选框就是跑它。
rem
rem  【注意】必须 enabledelayedexpansion：下面的 for 循环里要**边写边读**变量，
rem     用 %READY% 是解析期展开，循环里写的值外面永远看不到（经典坑）。
rem ============================================================
setlocal enabledelayedexpansion
call "%~dp0_env.cmd"

rem 已在跑就别重复启动（安装前若手动起过）
netstat -ano | findstr ":3602 " | findstr "LISTENING" >nul 2>&1
if not "%ERRORLEVEL%"=="0" start "" "%~dp0后台启动服务端.vbs"

rem 等服务端就绪：最多 20 秒。首次启动要建库，客户机器慢 / 杀软扫描还会更久
rem —— 不等就直接开浏览器，客户会看到"无法访问"，以为装坏了。
set "READY=0"
for /l %%i in (1,1,20) do (
  netstat -ano | findstr ":3602 " | findstr "LISTENING" >nul 2>&1
  if !ERRORLEVEL! equ 0 (
    set "READY=1"
    goto openit
  )
  timeout /t 1 /nobreak >nul
)

:openit
if "!READY!"=="0" (
  echo.
  echo   服务端启动较慢或未能启动，先不打开浏览器了。
  echo   请双击「启动服务端.cmd」看具体输出，或看日志：
  echo     %XZ_DATA%\logs\server.log
  echo.
  pause
  exit /b 0
)
start "" "http://127.0.0.1:3602/admin"
exit /b 0
