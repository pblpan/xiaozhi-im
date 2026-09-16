@echo off
rem  编码：GBK，全程不调用 chcp（原因见 _env.cmd 顶部说明）。
rem  安装程序「完成」页上那个勾选框，跑的就是这个脚本。
rem
rem  【注意】必须 enabledelayedexpansion：下面的 for 循环里要**边写边读**变量，
rem     用 %READY% 是解析期展开，循环里写的值外面永远看不到（经典坑）。
setlocal enabledelayedexpansion
call "%~dp0_env.cmd"

echo.
echo   正在后台启动服务端，请稍候 ...
echo   （首次启动要建数据库，慢的话十几秒，请不要关这个窗口）
echo.

netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
if not "!ERRORLEVEL!"=="0" start "" "%~dp0后台启动服务端.vbs"

set "READY=0"
for /l %%i in (1,1,30) do (
  netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
  if !ERRORLEVEL! equ 0 (
    set "READY=1"
    goto openit
  )
  timeout /t 1 /nobreak >nul
)

:openit
if "!READY!"=="0" goto xz_failed
echo   服务端已启动，正在打开管理后台 ...
start "" "http://127.0.0.1:%PORT%/admin"
timeout /t 2 /nobreak >nul
exit /b 0

:xz_failed
echo.
echo   [!] 服务端没能启动，先不打开浏览器了。
echo.
echo   下一步怎么办：
echo     1) 双击安装目录里的「启动服务端.cmd」，那个窗口会显示具体报错；
echo     2) 或双击「查看运行日志.cmd」看日志；
echo     3) 日志文件： %XZ_DATA%\logs\server.log
echo.
pause
exit /b 0