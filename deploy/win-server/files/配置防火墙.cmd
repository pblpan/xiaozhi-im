@echo off
rem ============================================================
rem  放通 Windows 防火墙入站端口（需要管理员权限）
rem
rem  为什么必须做：
rem    Windows 防火墙默认**阻止入站连接**。不配置的话，
rem    同一局域网的手机连不上 3602、也扫不到 3616，
rem    现象就是"服务端明明在跑，手机就是连不上"。
rem    （首次运行 node.exe 时系统也会弹一次授权框，点了"允许"效果一样。）
rem ============================================================
net session >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo.
  echo   [!] 需要管理员权限。
  echo       请在这个文件上点右键，选「以管理员身份运行」。
  echo.
  pause
  exit /b 1
)

echo.
echo   正在放通入站端口 ...
rem 端口（2026-05）：跟服务端走 —— _env.cmd 会把 data\.env 的 PORT 读进
rem 环境变量（没写就是默认 3602），防火墙规则不再写死端口。
call "%~dp0_env.cmd" >nul 2>&1
netsh advfirewall firewall delete rule name="小智IM 服务端 (TCP %PORT%)" >nul 2>&1
netsh advfirewall firewall delete rule name="小智IM 服务端 (UDP 3616)" >nul 2>&1
netsh advfirewall firewall add rule name="小智IM 服务端 (TCP %PORT%)" dir=in action=allow protocol=TCP localport=%PORT%
netsh advfirewall firewall add rule name="小智IM 服务端 (UDP 3616)" dir=in action=allow protocol=UDP localport=3616
echo.
echo     TCP %PORT%  —— 手机 / 电脑客户端连接服务端
echo   完成：
echo     TCP %PORT%  —— 手机 / 电脑客户端连接服务端
echo     UDP 3616  —— 客户端首次安装时的局域网自动发现
echo.
echo   没配也能用，但同一局域网里的手机可能连不上或扫不到服务器。
echo.
pause
