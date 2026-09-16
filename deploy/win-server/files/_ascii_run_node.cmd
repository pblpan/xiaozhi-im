@echo off
rem ============================================================
rem  XiaozhiIM server - internal bridge script (ASCII ONLY)
rem
rem  Purpose: run node in the foreground under the UTF-8 code page,
rem  so the server's Chinese output renders correctly.
rem
rem  !! EVERY BYTE OF THIS FILE MUST BE ASCII. Do not add comments
rem     in any other language, not even here.
rem     cmd.exe reads a .cmd file by BYTE OFFSET, line by line.
rem     Calling chcp mid-file makes it re-interpret the remaining
rem     bytes under a different code page, which shifts those offsets:
rem     a non-ASCII line then gets parsed from the middle, and half a
rem     Chinese comment ends up executed as a command - the customer
rem     sees "xxx is not recognized as an internal or external command"
rem     and the window closes. Pure ASCII cannot suffer from this,
rem     because every character is one byte under any code page.
rem
rem  !! ORDER MATTERS: `call _env.cmd` comes FIRST, chcp comes SECOND.
rem     _env.cmd is a GBK file; reading it while the console is already
rem     in UTF-8 mode would corrupt its own parsing. Only this file's
rem     own (ASCII) lines are on the far side of the chcp.
rem
rem  !! Must be launched in its OWN console window (see the boot script
rem     that starts it): chcp changes a property of the console window
rem     itself, so switching it inside a shared window corrupts the
rem     caller's output too.
rem ============================================================
call "%~dp0_env.cmd"
chcp 65001 >nul
"%XZ_NODE%" "%XZ_APP%\src\index.js"
exit /b %ERRORLEVEL%
