; ============================================================
;  小智IM 服务端 —— NSIS 安装脚本模板
;
;  ⚠️ 由 deploy/win-server/pack_server_win.py 读取并替换占位符后编译，
;     直接改这个文件**不会**生效（要改就改模板，下次打包会用新内容）。
;
;  __XXX__ 形式的占位符由 Python 替换；$XXX 是 NSIS 自己的变量，别动。
; ============================================================
Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64
SetDatablockOptimize on

!include "MUI2.nsh"
!include "FileFunc.nsh"

!insertmacro GetSize

!define APP_NAME    "__APP_NAME__"
!define SHORT_NAME  "__SHORT_NAME__"
!define VERSION     "__VERSION__"
!define PUBLISHER   "潘坚强"
!define UNINST_KEY  "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaozhiIMServer"
!define RUN_KEY     "Software\Microsoft\Windows\CurrentVersion\Run"

Name "${APP_NAME} ${VERSION}"
OutFile "__OUT_FILE__"

; 用户级安装：装到 %LOCALAPPDATA%\Programs，写 HKCU，**全程不弹 UAC**。
; 服务端本身要以某个用户身份跑，装成用户级和它的运行方式是一致的。
InstallDir "__INSTALL_DIR__"
InstallDirRegKey HKCU "${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel user
ShowInstDetails show
ShowUnInstDetails show
BrandingText "${APP_NAME}"

VIProductVersion "__VI_VERSION__"
VIFileVersion "__VI_VERSION__"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APP_NAME} ${VERSION} 安装程序"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileVersion" "__VI_VERSION__"
VIAddVersionKey "LegalCopyright" "Copyright © ${PUBLISHER}"

Var XZ_PASS       ; 管理台初始口令（安装时从 .env 读出来显示在完成页）
Var XZ_LAN        ; 本机局域网 IP
Var InstSizeKB

!define MUI_ICON      "__ICON__"
!define MUI_UNICON    "__ICON__"
!define MUI_ABORTWARNING

; 完成页 = 客户装完唯一会认真看的一屏。
; 所以这里直接把「用哪个地址登录、账号是什么、密码是什么」摆出来，
; 而不是让人自己去翻目录里的说明文件。
!define MUI_FINISHPAGE_TEXT "小智IM 服务端 ${VERSION} 已安装完成。$\r$\n$\r$\n管理后台（本机）：http://127.0.0.1:3602/admin$\r$\n管理后台（局域网）：http://$XZ_LAN:3602/admin$\r$\n$\r$\n管理账号：admin$\r$\n初始密码：$XZ_PASS$\r$\n$\r$\n这个密码同样保存在数据目录的 .env 文件里，以后可以用安装目录下的「查看管理员密码.cmd」再查。$\r$\n$\r$\n提示：要让同一局域网的手机连上，请右键「配置防火墙.cmd」→「以管理员身份运行」。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\首次启动并打开后台.cmd"
!define MUI_FINISHPAGE_RUN_TEXT "立即在后台启动服务端，并打开管理后台"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  ; 覆盖安装 / 修复安装：先把正在跑的旧服务端请走。
  ; 否则 node.exe 被占用，文件写不进去，装出来是"半新半旧"的混合体。
  ;
  ; ⚠️ 走的是 _stop_silent.cmd（按**端口 3602** 找进程后 taskkill /PID），
  ;    绝不 taskkill /IM node.exe —— 客户机上很可能还跑着别的 node 程序。
  IfFileExists "$INSTDIR\_stop_silent.cmd" 0 xz_init_done
    DetailPrint "正在停止旧版本服务端 …"
    nsExec::ExecToLog 'cmd /c ""$INSTDIR\_stop_silent.cmd""'
    Sleep 1200
  xz_init_done:
FunctionEnd

Section "小智IM 服务端" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "__SRC__\*.*"

  ; ---------- 数据目录（刻意放在安装目录**之外**）----------
  ; 放里面的话卸载会连聊天记录、上传文件、授权状态一起删光。
  CreateDirectory "__DATA_DIR__"
  CreateDirectory "__DATA_DIR__\logs"
  CreateDirectory "__DATA_DIR__\files"

  ; ---------- 生成 data\.env（随机的管理台口令 + JWT 密钥）----------
  ; 为什么非做不可：服务端在 ADMIN_PASSWORD 缺失时会自己生成随机口令，
  ; 但只打进日志；而 Windows 版是隐藏窗口跑的，客户看不到日志 ——
  ; 结果就是"装完了不知道拿什么登录"。这里生成完读回来显示。
  DetailPrint "生成配置文件与管理台初始密码 …"
  nsExec::ExecToStack '"$INSTDIR\node\node.exe" "$INSTDIR\app\tools\init-env.js" "__DATA_DIR__"'
  Pop $0
  Pop $1
  ; 用 ReadINIStr 而不是解析 stdout：少一处"装出来密码是空的"
  ReadINIStr $XZ_PASS "__DATA_DIR__\.install-result.ini" "install" "adminPassword"
  ReadINIStr $XZ_LAN  "__DATA_DIR__\.install-result.ini" "install" "lanIp"
  Delete "__DATA_DIR__\.install-result.ini"
  StrCmp $XZ_LAN "" 0 xz_lan_ok
    StrCpy $XZ_LAN "本机IP"
  xz_lan_ok:
  StrCmp $XZ_PASS "" 0 xz_pass_ok
    StrCpy $XZ_PASS "(生成失败，请查看数据目录里的 .env 文件)"
  xz_pass_ok:

  ${GetSize} "$INSTDIR" "/M=*.* /S=0K" $2 $3 $4
  IntFmt $InstSizeKB "0x%08X" $2

  ; ---------- 快捷方式 ----------
  ; 桌面只放一个最常用的（管理后台）；其余归到开始菜单，免得把客户桌面塞满。
  CreateShortCut "$DESKTOP\小智IM 管理后台.lnk" "$INSTDIR\打开管理后台.cmd" "" "$INSTDIR\打开管理后台.cmd" 0
  CreateDirectory "$SMPROGRAMS\${SHORT_NAME}"
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\后台启动服务端.lnk"          "$INSTDIR\后台启动服务端.vbs" "" "$INSTDIR\后台启动服务端.vbs" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\启动服务端（前台看日志）.lnk" "$INSTDIR\启动服务端.cmd" "" "$INSTDIR\启动服务端.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\停止服务端.lnk"             "$INSTDIR\停止服务端.cmd" "" "$INSTDIR\停止服务端.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\打开管理后台.lnk"           "$INSTDIR\打开管理后台.cmd" "" "$INSTDIR\打开管理后台.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\查看管理员密码.lnk"         "$INSTDIR\查看管理员密码.cmd" "" "$INSTDIR\查看管理员密码.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\查看运行日志.lnk"           "$INSTDIR\查看运行日志.cmd" "" "$INSTDIR\查看运行日志.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\配置防火墙（需管理员）.lnk"  "$INSTDIR\配置防火墙.cmd" "" "$INSTDIR\配置防火墙.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\设为开机自启.lnk"           "$INSTDIR\设为开机自启.cmd" "" "$INSTDIR\设为开机自启.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\取消开机自启.lnk"           "$INSTDIR\取消开机自启.cmd" "" "$INSTDIR\取消开机自启.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\卸载 ${SHORT_NAME}.lnk"     "$INSTDIR\uninst.exe"

  WriteUninstaller "$INSTDIR\uninst.exe"

  ; ---------- 开机自启 ----------
  ; 写 HKCU 的 Run：登录 Windows 后由 wscript 隐藏窗口拉起。
  ; 用 HKCU 而不是 HKLM：用户级写入不需要管理员权限，卸载也好清。
  WriteRegStr HKCU "${RUN_KEY}" "XiaozhiIMServer" 'wscript.exe "$INSTDIR\后台启动服务端.vbs"'

  ; ---------- 「添加/删除程序」里的条目 ----------
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayName"     "${APP_NAME}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayVersion"  "${VERSION}"
  WriteRegStr   HKCU "${UNINST_KEY}" "Publisher"       "${PUBLISHER}"
  WriteRegStr   HKCU "${UNINST_KEY}" "UninstallString" "$INSTDIR\uninst.exe"
  WriteRegStr   HKCU "${UNINST_KEY}" "QuietUninstallString" "$INSTDIR\uninst.exe /S"
  WriteRegStr   HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\uninst.exe,0"
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize"   $InstSizeKB
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; 先停服务 —— 走 _stop_silent.cmd（按端口），不按 node.exe 映像名杀
  IfFileExists "$INSTDIR\_stop_silent.cmd" 0 xz_un_stopped
    nsExec::ExecToLog 'cmd /c ""$INSTDIR\_stop_silent.cmd""'
    Sleep 1200
  xz_un_stopped:

  DeleteRegValue HKCU "${RUN_KEY}" "XiaozhiIMServer"

  RMDir /r "$INSTDIR"
  Delete "$DESKTOP\小智IM 管理后台.lnk"
  RMDir /r "$SMPROGRAMS\${SHORT_NAME}"
  DeleteRegKey HKCU "${UNINST_KEY}"

  ; ⚠️ 数据目录**刻意不删**：里面有聊天记录、上传的文件、授权状态。
  ;    静默卸载（/S）时不弹窗 —— 弹窗会把自动化部署挂死。
  IfSilent xz_un_silent
    MessageBox MB_OK "卸载完成。$\r$\n$\r$\n数据（聊天记录 / 上传文件 / 授权状态）已**保留**在：$\r$\n__DATA_DIR__$\r$\n$\r$\n重新安装后会自动接着用；确定不再需要了，手动删掉上面这个文件夹即可。"
  xz_un_silent:
SectionEnd
