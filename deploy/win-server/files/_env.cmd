@echo off
rem  编码：本文件是 **GBK**（中文 Windows 的默认代码页），全程不调用 chcp。
rem        原因见 pack_server_win.py 里 write_cmd() 的说明：cmd.exe 按字节偏移逐行
rem        读批处理文件，中途切代码页会让它对多字节字符的长度判断错位，
rem        于是从注释行中间开始解析 —— 中文注释的后半截被当成命令执行并报错。
rem ============================================================
rem  小智IM 服务端 —— 内部公共脚本
rem  （由其它脚本 call 调用，不要直接双击）
rem
rem  作用：定下安装目录 / 数据目录 / 端口，并把 data\.env 读成环境变量。
rem
rem  数据目录默认在 %LOCALAPPDATA% 下（安装向导可改到数据盘），不放安装目录里：
rem    安装目录在卸载时会被整个删掉。数据放外面，
rem    卸载重装不丢聊天记录、不丢授权（机器码不变就不用重新出授权码）。
rem ============================================================
set "XZ_HOME=%~dp0"
if "%XZ_HOME:~-1%"=="\" set "XZ_HOME=%XZ_HOME:~0,-1%"
set "XZ_NODE=%XZ_HOME%\node\node.exe"
set "XZ_APP=%XZ_HOME%\app"
rem 数据目录：安装向导选的目录（data_dir.cmd）优先；没选过就回落默认位置。
rem data_dir.cmd 由安装程序生成（GBK 编码，内含一行 set "XZ_DATA=..."）。
set "XZ_DATA=%LOCALAPPDATA%\小智IM服务端\data"
if exist "%XZ_HOME%\data_dir.cmd" call "%XZ_HOME%\data_dir.cmd"
set "PORT=3602"
set "NODE_ENV=production"
set "DATA_DIR=%XZ_DATA%"
set "MAX_FILE_MB=50"

rem 探测本机局域网 IP（只用于界面上显示地址，探测失败不影响服务）
set "XZ_LANIP=127.0.0.1"
for /f "tokens=2 delims=:" %%i in ('ipconfig ^| findstr /c:"IPv4"') do (
  for /f "tokens=1" %%j in ("%%i") do set "XZ_LANIP=%%j"
)

if not exist "%XZ_DATA%" mkdir "%XZ_DATA%"
if not exist "%XZ_DATA%\logs" mkdir "%XZ_DATA%\logs"

rem 读 .env（eol=# 跳过注释行）。值里只会有 hex / base64url 字符，不会撞 cmd 的转义。
if exist "%XZ_DATA%\.env" for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%XZ_DATA%\.env") do set "%%a=%%b"
