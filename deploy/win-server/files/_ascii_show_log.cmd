@echo off
rem ============================================================
rem  XiaozhiIM server - internal bridge script (ASCII ONLY)
rem
rem  Purpose: print a UTF-8 file (log) to the console. The log contains
rem  Chinese; `type`-ing it into a GBK console shows mojibake, so this
rem  window switches to UTF-8 first.
rem
rem  !! EVERY BYTE OF THIS FILE MUST BE ASCII - see the long
rem     explanation in _ascii_run_node.cmd. Short version: cmd.exe reads
rem     .cmd files by byte offset, and a code-page switch shifts those
rem     offsets, turning non-ASCII lines into garbage commands.
rem
rem  !! ORDER MATTERS: `call _env.cmd` first (it is a GBK file), then
rem     chcp. See _ascii_run_node.cmd.
rem
rem  !! Must be launched in its OWN console window.
rem ============================================================
call "%~dp0_env.cmd"
chcp 65001 >nul
if "%~1"=="" exit /b 1
if not exist "%~1" exit /b 1
type "%~1"
exit /b 0
