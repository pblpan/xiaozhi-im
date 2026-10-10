; ============================================================
;  小智IM 服务端控制台 —— 启动器模板（编译成 exe）
;
;  ⚠️ 由 deploy/win-server/pack_server_win.py 读取并替换占位符后编译，
;     直接改这个文件**不会**生效（要改就改模板，下次打包会用新内容）。
;
;  为什么要有这个 exe：
;    控制台本体（那个图形窗口）是 _sys\console.ps1，用 PowerShell + WinForms 写的。
;    如果直接拿一个 .cmd 当入口，客户打开安装目录看到的就是"一堆命令脚本"，
;    不像个正经软件。所以编一个几十 KB 的 exe 当门面：
;      双击 → 不闪黑框 → 弹出控制台窗口
;    所有命令行脚本（.cmd/.vbs/.ps1）收进 _sys\ 内部目录，安装根只剩这一个 exe。
;
;  为什么不用 C# 编译原生 exe：
;    那需要带 .NET 编译链或依赖客户机上的运行时，且客户机上容易被杀软误报
;    "未知发布者"；而 PowerShell 5.1 + .NET 是 Win10/11 自带的，零依赖。
;    这个 exe 只做一件事 —— 把脚本拉起来（真正的界面逻辑仍在 .ps1 里）。
;
;  ⚠️ 本文件必须存成 **UTF-8 带 BOM**（NSIS 的硬要求；不带 BOM 中文全是乱码）。
; ============================================================
Unicode true
SetCompressor /SOLID lzma

!define APP_NAME  "小智IM 服务端控制台"
!define PUBLISHER "潘坚强"
!define VERSION   "__VERSION__"

Name "${APP_NAME}"
OutFile "__OUT_FILE__"
Icon "__ICON__"

; 双击即用：不显示任何安装界面，不弹 UAC（控制台本身不需要管理员权限）
SilentInstall silent
RequestExecutionLevel user
XPStyle on

VIProductVersion "__VI_VERSION__"
VIFileVersion "__VI_VERSION__"
VIAddVersionKey "ProductName"     "${APP_NAME}"
VIAddVersionKey "ProductVersion"  "${VERSION}"
VIAddVersionKey "FileDescription" "${APP_NAME}"
VIAddVersionKey "CompanyName"     "${PUBLISHER}"
VIAddVersionKey "FileVersion"     "__VI_VERSION__"
VIAddVersionKey "LegalCopyright"  "Copyright © ${PUBLISHER}"

Section
  ; 安装根 = 这个 exe 自己所在的目录（客户把 exe 复制到别处也能照常工作）
  IfFileExists "$EXEDIR\_sys\console.ps1" 0 xz_no_console

  ; -WindowStyle Hidden 只隐藏 PowerShell 自己的控制台黑框；
  ; 控制台的图形窗口是脚本里自己创建的，照常显示。
  ; -AppRoot 把安装根显式传进去 —— 脚本现在收在 _sys\ 里，不能再靠
  ; "脚本自己所在目录"推安装根了。
  Exec '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$EXEDIR\_sys\console.ps1" -AppRoot "$EXEDIR"'
  Quit

  xz_no_console:
  MessageBox MB_OK|MB_ICONEXCLAMATION "找不到控制台程序：$\r$\n$EXEDIR\_sys\console.ps1$\r$\n$\r$\n请重新安装「小智IM 服务端」。"
SectionEnd
