@echo off
rem  编码：GBK，全程不调用 chcp（原因见 _env.cmd 顶部说明）。
rem  日志文件是 UTF-8，直接 type 到 GBK 控制台会花屏，
rem  所以开一个**独立的新控制台窗口**，在那里切到 UTF-8 再打印 ——
rem  代码页只影响那个新窗口，不会污染本脚本。
call "%~dp0_env.cmd"
set "LOG=%XZ_DATA%\logs\server.log"
if not exist "%LOG%" (
  echo.
  echo   还没有日志文件（%LOG%）—— 服务端可能从未在后台启动过。
  echo.
  pause
  exit /b 0
)
start "小智IM 运行日志" cmd /c ""%~dp0_ascii_show_log.cmd" "%LOG%""
exit /b 0