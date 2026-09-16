@echo off
chcp 65001 >nul
title 小智IM 服务端 v__VERSION__
call "%~dp0_env.cmd"
echo ================================================================
echo   小智IM 服务端   v__VERSION__
echo ----------------------------------------------------------------
echo   管理后台（本机）   http://127.0.0.1:3602/admin
echo   管理后台（局域网） http://%XZ_LANIP%:3602/admin
echo   数据目录           %XZ_DATA%
echo ----------------------------------------------------------------
echo   这是「前台运行」：关掉本窗口 = 停止服务。
echo   要长期在后台跑（并随开机自启），请双击「后台启动服务端.vbs」。
echo ================================================================
echo.
"%XZ_NODE%" "%XZ_APP%\src\index.js"
set "RC=%ERRORLEVEL%"
echo.
echo 服务已退出（退出码 %RC%）。
echo 若反复退出，看日志：%XZ_DATA%\logs\server.log
echo.
pause
