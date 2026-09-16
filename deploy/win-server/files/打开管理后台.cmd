@echo off
call "%~dp0_env.cmd"
rem 打开管理后台（浏览器访问本机 %PORT%）
start "" "http://127.0.0.1:%PORT%/admin"
