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
rem  数据目录在安装向导里选定（位置记在注册表，本文件末尾会去读），
rem  默认建议放数据盘，不放安装目录里：
rem    安装目录在卸载时会被整个删掉。数据放外面，
rem    卸载重装不丢聊天记录、不丢授权（机器码不变就不用重新出授权码）。
rem ============================================================
set "XZ_HOME=%~dp0"
if "%XZ_HOME:~-1%"=="\" set "XZ_HOME=%XZ_HOME:~0,-1%"
rem 2026-10-09：脚本收进了内部子目录 _sys\（安装根只留控制台 exe），
rem 所以"脚本自己所在目录"不再等于安装根 —— 以 node\ 的位置反推安装根。
rem 若本目录下没有 node\ 而上一级有，说明自己在 _sys\ 里，上跳一级。
if not exist "%XZ_HOME%\node\node.exe" if exist "%XZ_HOME%\..\node\node.exe" for %%I in ("%XZ_HOME%\..") do set "XZ_HOME=%%~fI"
set "XZ_NODE=%XZ_HOME%\node\node.exe"
set "XZ_APP=%XZ_HOME%\app"
rem 数据目录 = 安装向导里选的那个位置，安装程序把它记在
rem   HKCU\Software\小智IM服务端\DataDir
rem
rem 【2026-10-09 修】这里原来读 %XZ_HOME%\data_dir.cmd，而那个文件**早就没有任何
rem    地方生成了**（安装器改用注册表 + init-env.js 传参），于是恒定回落到下面
rem    C 盘的默认位置。客户只要把数据目录选到数据盘（安装向导默认就建议
rem    D:\小智IM服务端\data），走本脚本链（后台启动服务端.vbs → _hidden.cmd）
rem    起来的服务端就会在 C 盘另建一套空数据 —— 表现成"装完数据不见了 /
rem    初始密码登不上"。控制台是 PowerShell、直接读注册表，所以只有这条
rem    .cmd/.vbs 链中招，排查时极易看错方向。
set "XZ_DATA=%LOCALAPPDATA%\小智IM服务端\data"
rem reg.exe 在部分机器被安全策略拉黑 → 改用 PowerShell 读注册表（Get-ItemProperty 未被拦）。
rem 注意：本文件需 GBK 落盘（见 pack_server_win.py::write_cmd），中文键名才能被 PowerShell 正确接收。
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "try{(Get-ItemProperty -Path 'HKCU:\Software\小智IM服务端' -Name DataDir -ErrorAction Stop).DataDir}catch{}"`) do set "XZ_DATA=%%a"
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
