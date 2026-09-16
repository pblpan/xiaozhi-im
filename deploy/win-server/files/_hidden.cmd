@echo off
chcp 65001 >nul
rem ============================================================
rem  小智IM 服务端 —— 内部脚本：后台（隐藏窗口）运行
rem  由「后台启动服务端.vbs」调用；开机自启走的也是它。
rem  日志一律写进 data\logs\server.log（隐藏窗口看不到控制台输出）。
rem ============================================================
call "%~dp0_env.cmd"
set "LOG=%XZ_DATA%\logs\server.log"

rem 单代轮转：超过 5 MB 就把当前日志改名成 server.log.1（旧的直接覆盖）。
rem 后台常驻、日志只增不减的话，跑几个月能到几百 MB ——
rem 客户只会发现"盘莫名其妙少了一块"，还找不到是谁吃的。
if exist "%LOG%" for %%A in ("%LOG%") do if %%~zA GTR 5242880 move /y "%LOG%" "%LOG%.1" >nul

rem 首次创建日志时先写一个 UTF-8 BOM。
rem 为什么必须写：cmd 与 node 写进去的都是**无 BOM 的 UTF-8**，
rem 而 Windows 记事本遇到无 BOM 的文件会按本地代码页（GBK）解释 ——
rem 客户打开日志看到满屏乱码，反而以为服务端出问题了。
rem 补上这三个字节之后，记事本 / VSCode / 任何编辑器都能正确识别。
if not exist "%LOG%" "%XZ_NODE%" -e "require('fs').writeFileSync(process.argv[1],'\ufeff')" "%LOG%"

rem 已经在跑就别再起一个 —— 第二个进程会因端口被占直接退出，
rem 只在日志里留下一串 EADDRINUSE，看着像"服务端老是自己崩"。
netstat -ano | findstr ":3602 " | findstr "LISTENING" >nul 2>&1
if "%ERRORLEVEL%"=="0" (
  echo ================ %DATE% %TIME% already running, skipped ================ >> "%LOG%"
  exit /b 0
)

echo. >> "%LOG%"
echo ================ %DATE% %TIME% 启动 v__VERSION__ ================ >> "%LOG%"
"%XZ_NODE%" "%XZ_APP%\src\index.js" >> "%LOG%" 2>&1
echo ================ %DATE% %TIME% 退出（%ERRORLEVEL%） ================ >> "%LOG%"
