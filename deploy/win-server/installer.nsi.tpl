; ============================================================
;  小智IM 服务端 —— NSIS 安装脚本模板
;
;  ⚠️ 由 deploy/win-server/pack_server_win.py 读取并替换占位符后编译，
;     直接改这个文件**不会**生效（要改就改模板，下次打包会用新内容）。
;
;  __XXX__ 形式的占位符由 Python 替换；$XXX 是 NSIS 自己的变量，别动。
;
;  ⚠️ 本文件必须存成 **UTF-8 带 BOM**（NSIS 的硬要求；不带 BOM 的话
;     中文界面全是乱码）。注意这跟 .cmd 的要求正好相反 —— .cmd 绝不能带 BOM。
; ============================================================
Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64
SetDatablockOptimize on

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "nsDialogs.nsh"
!include "LogicLib.nsh"

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

Var XZ_PASS        ; 数据目录 .env 里**实际生效**的管理台密码
Var XZ_CUSTOM      ; 1 = 客户自己在安装向导里设的，0 = 程序随机生成
Var XZ_LAN         ; 本机局域网 IP
Var InstSizeKB

Var XZ_PWD_DIALOG  ; 自定义页：控件句柄
Var XZ_PWD_CTL
Var XZ_PWD_CTL2
Var XZ_NEWPASS     ; 客户在向导里输入的密码（空 = 随机生成）
Var XZ_NEWPASS2
Var XZ_PASS_LINE   ; 完成页上那一行"密码：…"（按上面两种情况拼）
Var XZ_HASENV      ; 1 = 数据目录里已经有 .env（装过）→ 跳过设密码页

!define MUI_ICON      "__ICON__"
!define MUI_UNICON    "__ICON__"
!define MUI_ABORTWARNING

; 完成页 = 客户装完唯一会认真看的一屏。
; 所以这里直接把「用哪个地址登录、账号是什么、密码是什么」摆出来，
; 而不是让人自己去翻目录里的说明文件。
!define MUI_FINISHPAGE_TEXT "小智IM 服务端 ${VERSION} 已安装完成。$\r$\n$\r$\n管理后台（本机）：http://127.0.0.1:3602/admin$\r$\n管理后台（局域网）：http://$XZ_LAN:3602/admin$\r$\n$\r$\n管理账号：admin$\r$\n$XZ_PASS_LINE$\r$\n$\r$\n忘了密码：双击安装目录下的「查看管理员密码.cmd」再查。$\r$\n$\r$\n提示：要让同一局域网的手机连上，请右键「配置防火墙.cmd」→「以管理员身份运行」。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\首次启动并打开后台.cmd"
!define MUI_FINISHPAGE_RUN_TEXT "立即在后台启动服务端，并打开管理后台"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
Page custom xzPwdPageCreate xzPwdPageLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

; ============================================================
;  自定义页：设置管理后台密码
;
;  为什么要这一页：早期版本一律随机生成 20 位 hex、摆到完成页上让客户抄。
;  实际用下来客户根本不抄（反馈原话："装完不知道拿什么登录"），
;  装完就卡在登录页。让他自己设一个记得住的，比给一串随机字符有用得多。
;
;  留空 = 不设，退回随机生成（随机值会显示在完成页上）。
;  静默安装（/S）不走这一页，$XZ_NEWPASS 为空 → 同样退回随机生成，
;  所以自动化部署不受影响。
; ============================================================
Function xzPwdPageCreate
  ; 装过（数据目录里已经有 .env）就跳过这一页。
  ; 因为那种情况下 init-env.js 会**原样沿用**已有的 .env（刻意的：
  ; 客户可能早就把密码改过了，重装把它冲掉等于把人锁在门外）。
  ; 让客户白设一次、结果设了不生效，比不让他设更糟。
  StrCmp $XZ_HASENV "1" 0 xz_pwd_show
    Abort
  xz_pwd_show:

  !insertmacro MUI_HEADER_TEXT "设置管理后台密码" "登录管理后台用的密码（管理账号固定为 admin）"

  nsDialogs::Create 1018
  Pop $XZ_PWD_DIALOG
  ${If} $XZ_PWD_DIALOG == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 34u "请给管理后台设置一个登录密码。$\r$\n密码 6 位以上，建议字母加数字。$\r$\n$\r$\n不想现在设也行 —— 留空，安装完成后由程序随机生成，并显示在「完成」页上等你抄下来。"
  Pop $0

  ${NSD_CreateLabel} 0 50u 100% 11u "密码："
  Pop $0
  ${NSD_CreatePassword} 0 63u 100% 13u ""
  Pop $XZ_PWD_CTL

  ${NSD_CreateLabel} 0 84u 100% 11u "再输一次确认："
  Pop $0
  ${NSD_CreatePassword} 0 97u 100% 13u ""
  Pop $XZ_PWD_CTL2

  ${NSD_CreateLabel} 0 120u 100% 26u "密码会写进数据目录的 .env 文件（不是明文存到别处）。$\r$\n以后忘了，双击安装目录下的「查看管理员密码.cmd」就能再看到。"
  Pop $0

  nsDialogs::Show
FunctionEnd

Function xzPwdPageLeave
  ${NSD_GetText} $XZ_PWD_CTL $XZ_NEWPASS
  ${NSD_GetText} $XZ_PWD_CTL2 $XZ_NEWPASS2

  ; 两个都空 → 客户选择随机生成，放行
  ${If} $XZ_NEWPASS == ""
  ${AndIf} $XZ_NEWPASS2 == ""
    Return
  ${EndIf}

  ${If} $XZ_NEWPASS != $XZ_NEWPASS2
    MessageBox MB_OK|MB_ICONEXCLAMATION "两次输入的密码不一致，请重新输入。"
    Abort
  ${EndIf}

  ; 长度。字符集不在这里卡 —— 由 init-env.js 兜底（它的 CUSTOM_PW_RE），
  ; 万一客户真输了不支持的字符，完成页会显示**实际生效**的那个密码，
  ; 不会出现"我设了 A、结果登录要用 B"这种哑巴亏。
  StrLen $1 $XZ_NEWPASS
  ${If} $1 < 6
    MessageBox MB_OK|MB_ICONEXCLAMATION "密码太短了，至少要 6 位。"
    Abort
  ${EndIf}
  ${If} $1 > 64
    MessageBox MB_OK|MB_ICONEXCLAMATION "密码太长了，最多 64 位。"
    Abort
  ${EndIf}
FunctionEnd

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

  ; 装过没有？看数据目录里有没有 .env。有 → 设密码页会被跳过（见那边说明）。
  StrCpy $XZ_HASENV "0"
  IfFileExists "__DATA_DIR__\.env" 0 xz_init_fresh
    StrCpy $XZ_HASENV "1"
  xz_init_fresh:
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

  ; ---------- 生成 data\.env（管理台密码 + JWT 密钥）----------
  DetailPrint "生成配置文件与管理台密码 …"
  StrCmp $XZ_NEWPASS "" xz_env_nocustom
    ; 客户自己设了密码 → 写进临时文件再交给 init-env.js。
    ; 不拼命令行：密码里可能有 $ " 空格，会被 NSIS 和 cmd 二次解析，
    ; 轻则密码对不上，重则整条命令跑飞。
    FileOpen $9 "$TEMP\xz-password.tmp" w
    FileWrite $9 "$XZ_NEWPASS"
    FileClose $9
    nsExec::ExecToStack '"$INSTDIR\node\node.exe" "$INSTDIR\app\tools\init-env.js" "__DATA_DIR__" "--password-file=$TEMP\xz-password.tmp"'
    Delete "$TEMP\xz-password.tmp"
    Goto xz_env_done
  xz_env_nocustom:
    nsExec::ExecToStack '"$INSTDIR\node\node.exe" "$INSTDIR\app\tools\init-env.js" "__DATA_DIR__"'
  xz_env_done:
  Pop $0
  Pop $1

  ; 用 ReadINIStr 而不是解析 stdout：少一处"装出来密码是空的"
  ReadINIStr $XZ_PASS   "__DATA_DIR__\.install-result.ini" "install" "adminPassword"
  ReadINIStr $XZ_CUSTOM "__DATA_DIR__\.install-result.ini" "install" "passwordIsCustom"
  ReadINIStr $XZ_LAN    "__DATA_DIR__\.install-result.ini" "install" "lanIp"
  Delete "__DATA_DIR__\.install-result.ini"

  StrCmp $XZ_LAN "" 0 xz_lan_ok
    StrCpy $XZ_LAN "本机IP"
  xz_lan_ok:
  StrCmp $XZ_PASS "" 0 xz_pass_ok
    StrCpy $XZ_PASS "(生成失败，请看数据目录里的 .env 文件)"
  xz_pass_ok:

  ; 完成页那一行，分三种情况 —— 关键是**不能报一个可能已经过期的密码**：
  ;   · 这次没走设密码页（装过，HASENV=1）→ .env 里那串可能早就被客户在管理台
  ;     改掉了，照报出来等于让他拿着一个登不上的密码去试。只说明"沿用原有密码"
  ;     并指路去查看，别冒充"初始密码"。
  ;   · 客户在向导里自己设的 → 不回显（他知道自己输了什么）
  ;   · 随机生成的 → 一定要显示，否则他又没得抄
  StrCmp $XZ_HASENV "1" 0 xz_line_fresh
    StrCpy $XZ_PASS_LINE "沿用原有密码（忘了的话：双击安装目录里的「查看管理员密码.cmd」）"
    Goto xz_line_done
  xz_line_fresh:
  StrCmp $XZ_CUSTOM "1" 0 xz_line_random
    StrCpy $XZ_PASS_LINE "密码：你刚才在安装向导里设置的那个"
    Goto xz_line_done
  xz_line_random:
    StrCpy $XZ_PASS_LINE "初始密码：$XZ_PASS"
  xz_line_done:

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
