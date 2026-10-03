; ============================================================
;  小智 IM 客户端 Windows 安装器（NSIS）
;  版本 0.22.0
;
;  用途：把 CI 打出来的 **绿色版**（xiaozhi-im-windows-<ver>.zip）包成
;        一个双击就能装的 Setup.exe。
;
;  为什么要有这一步（2026-10-03）：
;    CI 只产绿色版 zip。对普通用户来说"解压到哪儿、怎么建快捷方式"是负担，
;    而且**升级时不知道该删哪些旧文件**（flutter 换版本会留下上一版的
;    data/ 残留）。所以交付默认给 Setup.exe，zip 作为绿色版附加。
;
;  三个必须做对的地方：
;  1. 安装前先杀进程 —— 正在运行的 exe 文件被锁住，写不进去，
;     NSIS 会弹"文件正在使用"然后留下半个安装（最难缠的一类）。
;  2. 升级时**清干净旧目录再装**（/RMDIR /r）—— 不然上一版的 data/ 残留会
;     让新版本行为诡异（Flutter 的 AOT 快照与引擎版本必须配套）。
;  3. 建开始菜单 + 桌面快捷方式，并写卸载项 —— 让人能正常卸载，
;     卸载时只删自己装的东西，不碰用户数据（数据在 %APPDATA%）。
;
;  生成：makensis client_installer.nsi   （在 client_nsistaging/ 目录下执行）
; ============================================================

!define APPNAME        "小智IM"
!define APPVERSION     "0.22.0"
!define APPEXE         "xiaozhi_im_client.exe"
!define BUILDDIR       "payload"
!define OUTFILE        "小智IM-Setup-v${APPVERSION}.exe"

Name "${APPNAME} ${APPVERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel user          ; 不需要管理员：装到用户目录即可
InstallDir "$LOCALAPPDATA\${APPNAME}"
InstallDirRegKey HKCU "Software\${APPNAME}" "InstallDir"
SetCompressor /SOLID lzma            ; 安装包小一点，解压快一点

!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APPEXE}"
!define MUI_FINISHPAGE_RUN_TEXT "启动 ${APPNAME}"

!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; 安装/卸载前先杀进程：正在运行的 exe 文件被锁住，写不进去，
; NSIS 会弹「文件正在使用」然后留下半个安装。
!macro guard_running
  nsExec::Exec 'taskkill /F /IM ${APPEXE} 2>NUL'
  Sleep 400
!macroend


; ---- 卸载时不要删用户数据（聊天登录态、配置都在 %APPDATA%，那是用户的）----
Section "安装"
  StrCpy $0 "$INSTDIR"
  !insertmacro guard_running

  ; ① 先把旧目录整个清掉（升级场景最关键的一步，见文件头第 2 条）
  ;    只在已存在时清，且不删 %APPDATA%（它不在 $INSTDIR 里，天然安全）
  IfFileExists "$INSTDIR\*.*" 0 +2
    RMDir /r "$INSTDIR"

  SetOutPath "$INSTDIR"
  ; ---- 打进安装包的文件：绿色版 zip 解出来的全部内容 ----
  File "${BUILDDIR}\${APPEXE}"
  File /r "${BUILDDIR}\data"
  File "${BUILDDIR}\flutter_windows.dll"
  File "${BUILDDIR}\libwebrtc.dll"
  File "${BUILDDIR}\sqlite3.dll"
  File "${BUILDDIR}\dartjni.dll"
  File /r "${BUILDDIR}\*.dll"

  ; ---- 快捷方式 ----
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortCut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$INSTDIR\${APPEXE}"
  CreateShortCut "$SMPROGRAMS\${APPNAME}\卸载.lnk" "$INSTDIR\uninstall.exe"
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\${APPEXE}"

  ; ---- 写注册表：便于"修改/重新安装"时记住安装位置与版本 ----
  ; ⚠️ 只写 HKCU（当前用户）：安装器是 RequestExecutionLevel user，
  ;    写 HKLM 需要管理员权限，会失败。写到 HKCU 已经够"控制面板能卸载"用了。
  WriteRegStr HKCU "Software\${APPNAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\${APPNAME}" "Version" "${APPVERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayVersion" "${APPVERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoRepair" 1

  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  !insertmacro guard_running
  ; 只删 $INSTDIR（安装时建的东西），不动 %APPDATA% 的用户数据
  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\卸载.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"
  Delete "$DESKTOP\${APPNAME}.lnk"
  DeleteRegKey HKCU "Software\${APPNAME}"
  ; ⚠️ 卸载是 RequestExecutionLevel user（普通权限），只删自己写过的 HKCU 键；
  ;    用 /ifnosubkeys 让它在键不存在时安静跳过，而不是弹一个失败框。
  DeleteRegKey /ifnosubkeys HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
SectionEnd
