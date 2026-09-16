@echo off
rem ============================================================
rem  内部：静默停止服务端（不 pause、不打印）
rem  给**安装程序 / 卸载程序**调用 —— 覆盖安装前必须先把旧的请走，
rem  否则 node.exe 被占用，文件写不进去，装出来是"半新半旧"的混合体。
rem
rem  刻意不 call _env.cmd：卸载时数据目录可能已经被清掉，
rem  这个脚本只依赖 netstat / taskkill，任何时候都能跑。
rem ============================================================
setlocal enabledelayedexpansion
set "PID="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":3602 " ^| findstr "LISTENING"') do set "PID=%%a"
if defined PID taskkill /F /PID !PID! >nul 2>&1
exit /b 0
