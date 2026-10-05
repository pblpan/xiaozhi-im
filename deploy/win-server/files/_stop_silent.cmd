@echo off
rem ============================================================
rem  内部：静默停止服务端（不 pause、不打印）
rem  给**安装程序 / 卸载程序**调用 —— 覆盖安装前必须先把旧的请走，
rem  否则 node.exe 被占用，文件写不进去，装出来是"半新半旧"的混合体。
rem
rem  刻意不 call _env.cmd：卸载时数据目录可能已经被清掉，
rem  这个脚本只依赖 netstat / taskkill，任何时候都能跑。
rem
rem  端口（2026-10-05）：支持自定义端口 —— 从 data\.env 读 PORT，
rem  读不到（.env 不存在 / 没写 PORT 行）就回落默认 3602。
rem  为什么要读：服务端在 .env 里写了 PORT=xxx 后，卸载/覆盖安装时
rem  还按写死的 3602 找进程就会扑空，旧的 node.exe 杀不掉。
rem ============================================================
setlocal enabledelayedexpansion
set "KILLPORT=3602"
set "XZ_DATA=%LOCALAPPDATA%\小智IM服务端\data"
if exist "%XZ_DATA%\.env" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%XZ_DATA%\.env") do (
  if /i "%%a"=="PORT" set "KILLPORT=%%b"
)
set "PID="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":%KILLPORT% " ^| findstr "LISTENING"') do set "PID=%%a"
if defined PID taskkill /F /PID !PID! >nul 2>&1
exit /b 0
