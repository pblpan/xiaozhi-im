@echo off
rem ============================================================
rem  XiaozhiIM server - internal bridge script (ASCII ONLY)
rem
rem  Purpose: append one timestamped separator line to the log file.
rem
rem  Why this script exists:
rem    The caller (_hidden.cmd) is GBK, so anything it echoes is GBK
rem    bytes - but the log file is UTF-8. Writing Chinese from the
rem    caller therefore corrupts the log. On top of that, %DATE% on a
rem    Chinese Windows contains localised text like "Thu" spelled in
rem    Chinese, which is GBK too. So the whole log line is produced by
rem    node here, guaranteeing the log file stays UTF-8 throughout.
rem
rem  !! EVERY BYTE OF THIS FILE MUST BE ASCII - see the long
rem     explanation in _ascii_run_node.cmd.
rem
rem  Usage: _ascii_stamp.cmd "<log file>" <message words...>
rem ============================================================
call "%~dp0_env.cmd"
if "%~1"=="" exit /b 1
rem BOM must be written before the first append, otherwise appendFileSync
rem creates a BOM-less file and Notepad on a Chinese Windows renders it as
rem GBK mojibake. _hidden.cmd only stamps the BOM when the file does not
rem exist yet; any caller reaching this script first must not leave the
rem log without its BOM.
"%XZ_NODE%" -e "const fs=require('fs');if(!fs.existsSync(process.argv[1]))fs.writeFileSync(process.argv[1],'\ufeff');const p=n=>String(n).padStart(2,'0'),d=new Date(),t=d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());fs.appendFileSync(process.argv[1],'\n================ '+t+' '+process.argv.slice(2).join(' ')+' ================\n')" %*
exit /b 0
