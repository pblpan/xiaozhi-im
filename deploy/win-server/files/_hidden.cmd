@echo off
rem ============================================================
rem  小智IM 服务端 —— 内部脚本：后台（隐藏窗口）运行
rem  由「后台启动服务端.vbs」调用；开机自启走的也是它。
rem  日志一律写进 data\logs\server.log（隐藏窗口看不到控制台输出）。
rem
rem  【编码】本文件是 **GBK**（中文 Windows 的默认代码页），全程不调用 chcp。
rem     原因：cmd.exe 按**字节偏移**逐行读批处理文件，中途切代码页会让它对
rem     多字节字符的长度判断错位，于是从注释行中间开始解析 —— 中文注释的后
rem     半截被当成命令执行，客户看到满屏「不是内部或外部命令」并闪退。
rem
rem  【编码】也正因为本文件是 GBK，**绝不能用 echo 往日志里写中文**：echo 出去的是
rem     GBK 字节，而日志文件是 UTF-8，混进去就是乱码（记事本里一片花屏）。
rem     `%DATE%` / `%TIME%` 同样不能用 —— 中文 Windows 下它们带"周四"这种
rem     本地化字符。日志里的每一行都交给 node 写（_ascii_stamp.cmd），
rem     这样整篇日志才是同一种编码。
rem ============================================================
call "%~dp0_env.cmd"
set "LOG=%XZ_DATA%\logs\server.log"

rem 单代轮转：超过 5 MB 就把当前日志改名成 server.log.1（旧的直接覆盖）。
rem 后台常驻、日志只增不减的话，跑几个月能到几百 MB ——
rem 客户只会发现"盘莫名其妙少了一块"，还找不到是谁吃的。
if exist "%LOG%" for %%A in ("%LOG%") do if %%~zA GTR 5242880 move /y "%LOG%" "%LOG%.1" >nul

rem 首次创建日志时先写一个 UTF-8 BOM。
rem 为什么必须写：node 写进去的是**无 BOM 的 UTF-8**，
rem 而 Windows 记事本遇到无 BOM 的文件会按本地代码页（GBK）解释 ——
rem 客户打开日志看到满屏乱码，反而以为服务端出问题了。
if not exist "%LOG%" "%XZ_NODE%" -e "require('fs').writeFileSync(process.argv[1],'\ufeff')" "%LOG%"

rem 已经在跑就别再起一个 —— 第二个进程会因端口被占直接退出，
rem 只在日志里留下一串 EADDRINUSE，看着像"服务端老是自己崩"。
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
if "%ERRORLEVEL%"=="0" (
  call "%~dp0_ascii_stamp.cmd" "%LOG%" skipped already-running
  exit /b 0
)

call "%~dp0_ascii_stamp.cmd" "%LOG%" start v__VERSION__
"%XZ_NODE%" "%XZ_APP%\src\index.js" >> "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
call "%~dp0_ascii_stamp.cmd" "%LOG%" exit code %RC%
