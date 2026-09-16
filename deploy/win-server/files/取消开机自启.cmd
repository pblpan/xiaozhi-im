@echo off
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "XiaozhiIMServer" /f >nul 2>&1
echo.
echo   已取消开机自启（已启动的服务端不会因此停止，可用「停止服务端.cmd」）。
echo.
pause
