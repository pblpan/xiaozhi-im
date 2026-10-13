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

; ---- 数据目录自定义（2026-10-05 加）----
; 为什么：原来一律放 %LOCALAPPDATA%（C 盘用户目录），系统重置、磁盘清理、
; 杀毒软件都可能动它。现在装的时候让客户自己选（默认建议数据盘 D:）。
Var XZ_DATADIR     ; 本次安装使用的数据目录（向导页里可改）
Var XZ_LEGACY      ; 旧版默认数据目录（迁移判断用）
Var XZ_DATA_DLG    ; 数据目录页：窗口句柄
Var XZ_DATA_CTL    ; 数据目录页：输入框
Var XZ_DATA_NOTE   ; 数据目录页：说明文字（按检测结果拼）

!define MUI_ICON      "__ICON__"
!define MUI_UNICON    "__ICON__"
!define MUI_ABORTWARNING

; 完成页 = 客户装完唯一会认真看的一屏。
; 所以这里直接把「用哪个地址登录、账号是什么、密码是什么」摆出来，
; 而不是让人自己去翻目录里的说明文件。
!define MUI_FINISHPAGE_TEXT "小智IM 服务端 ${VERSION} 已安装完成。$\r$\n$\r$\n数据目录：$XZ_DATADIR$\r$\n$\r$\n管理后台（本机）：http://127.0.0.1:3602/admin$\r$\n管理后台（局域网）：http://$XZ_LAN:3602/admin$\r$\n$\r$\n管理账号：admin$\r$\n$XZ_PASS_LINE$\r$\n$\r$\n日常管理请用桌面上的「小智IM 服务端控制台」：启动 / 停止 / 重启、开机自启、$\r$\n实时日志、查看密码、配置防火墙，都在那一个窗口里。$\r$\n$\r$\n提示：要让同一局域网的手机连上，在控制台里点「配置防火墙」即可（会自动放通当前端口）。"
!define MUI_FINISHPAGE_RUN "$INSTDIR\_sys\首次启动并打开后台.cmd"
!define MUI_FINISHPAGE_RUN_TEXT "立即在后台启动服务端，并打开管理后台"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
Page custom xzDataPageCreate xzDataPageLeave
Page custom xzPwdPageCreate xzPwdPageLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

; ============================================================
;  自定义页：选择数据保存位置
;
;  默认策略（.onInit 里已算好 $XZ_DATADIR，这里只负责展示/修改）：
;    · 装过（注册表里有 DataDir）→ 沿用客户上次选的位置，不动
;    · 没装过但有旧数据（__DATA_DIR__ 里有 .env）→ 沿用旧位置，一个字节都不搬
;    · 全新安装 → 有 D 盘就默认 D:\小智IM服务端\data，否则用系统默认位置
;  静默安装（/S）不走这一页，$XZ_DATADIR 直接用 .onInit 算出的值。
; ============================================================
Function xzDataBrowse
  ${NSD_GetText} $XZ_DATA_CTL $0
  nsDialogs::SelectFolderDialog "选择数据目录" "$0"
  Pop $1
  ${If} $1 != error
    ${NSD_SetText} $XZ_DATA_CTL "$1"
  ${EndIf}
FunctionEnd

Function xzDataPageCreate
  !insertmacro MUI_HEADER_TEXT "选择数据保存位置" "数据库、聊天文件、日志都保存在数据目录里"

  nsDialogs::Create 1018
  Pop $XZ_DATA_DLG
  ${If} $XZ_DATA_DLG == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 46u "数据库、聊天文件、日志都保存在这个目录。$\r$\n装在系统盘（C 盘）的用户目录下，容易被系统重置、磁盘清理工具或杀毒软件挪动，建议放在数据盘。$\r$\n升级安装时默认沿用原来的数据目录，已有数据不会被搬动。"
  Pop $0

  ${NSD_CreateLabel} 0 56u 100% 11u "数据目录："
  Pop $0
  ${NSD_CreateText} 0 69u 77% 13u "$XZ_DATADIR"
  Pop $XZ_DATA_CTL
  ${NSD_CreateBrowseButton} 79% 69u 21% 13u "浏览…"
  Pop $1
  ${NSD_OnClick} $1 xzDataBrowse

  ${NSD_CreateLabel} 0 92u 100% 40u "$XZ_DATA_NOTE"
  Pop $0

  nsDialogs::Show
FunctionEnd

Function xzDataPageLeave
  ${NSD_GetText} $XZ_DATA_CTL $XZ_DATADIR
  ${If} $XZ_DATADIR == ""
    MessageBox MB_OK|MB_ICONEXCLAMATION "数据目录不能为空。"
    Abort
  ${EndIf}
  ; 去掉结尾的反斜杠，避免后续拼出 $XZ_DATADIR\.env 变成 D:\data\\.env
  StrCpy $2 $XZ_DATADIR 1 -1
  ${If} $2 == "\"
    StrCpy $XZ_DATADIR $XZ_DATADIR -1
  ${EndIf}
  ; 简单校验：必须带盘符（形如 X:\...），不然 CreateDirectory 会建到 $INSTDIR 里
  StrCpy $2 $XZ_DATADIR 1 1
  ${If} $2 != ":"
    MessageBox MB_OK|MB_ICONEXCLAMATION "请填写完整路径，例如 D:\小智IM服务端\data"
    Abort
  ${EndIf}
FunctionEnd

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
  ; 装过（该数据目录里已经有 .env）就跳过这一页。
  ; 因为那种情况下 init-env.js 会**原样沿用**已有的 .env（刻意的：
  ; 客户可能早就把密码改过了，重装把它冲掉等于把人锁在门外）。
  ; 让客户白设一次、结果设了不生效，比不让他设更糟。
  ;
  ; ⚠️ 这里按**本页之前刚选定的** $XZ_DATADIR 重新判断（不是 .onInit 的老值）：
  ;    客户可能在数据目录页把位置改到了别处，改到哪儿就看哪儿有没有数据。
  StrCpy $XZ_HASENV "0"
  IfFileExists "$XZ_DATADIR\.env" 0 xz_pwd_fresh
    StrCpy $XZ_HASENV "1"
  xz_pwd_fresh:
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

  ${NSD_CreateLabel} 0 120u 100% 26u "密码会写进数据目录的 .env 文件（不是明文存到别处）。$\r$\n以后忘了，打开「小智IM 服务端控制台」点「查看管理员密码」就能再看到。"
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
  ; ⚠️ 两个位置都试：新版收在 _sys\，但老版本是摊在安装根的，
  ;    升级时得能停掉老版本那份装的服务。
  IfFileExists "$INSTDIR\_sys\_stop_silent.cmd" 0 xz_init_try_legacy
    DetailPrint "正在停止旧版本服务端 …"
    nsExec::ExecToLog 'cmd /c ""$INSTDIR\_sys\_stop_silent.cmd""'
    Pop $R0
    ${If} $R0 != 0
      ; nsExec 失败时返回字符串 "error"，成功返回退出码 "0"/"1" —— 必须字符串比较
      MessageBox MB_YESNO|MB_ICONEXCLAMATION "旧服务端可能仍在运行（自动停止未成功，返回：$R0）。$\r$\n$\r$\n继续安装可能提示「无法打开要写入的文件」。$\r$\n建议：先在控制台点「停止服务端」，或重启电脑后再运行本安装程序。$\r$\n$\r$\n仍要继续安装吗？" IDYES xz_init_warn1_go
      Abort
      xz_init_warn1_go:
    ${EndIf}
    Sleep 1200
    Goto xz_init_done
  xz_init_try_legacy:
  IfFileExists "$INSTDIR\_stop_silent.cmd" 0 xz_init_done
    DetailPrint "正在停止旧版本服务端 …"
    nsExec::ExecToLog 'cmd /c ""$INSTDIR\_stop_silent.cmd""'
    Pop $R0
    ${If} $R0 != 0
      MessageBox MB_YESNO|MB_ICONEXCLAMATION "旧服务端可能仍在运行（自动停止未成功，返回：$R0）。$\r$\n$\r$\n继续安装可能提示「无法打开要写入的文件」。$\r$\n建议：先在控制台点「停止服务端」，或重启电脑后再运行本安装程序。$\r$\n$\r$\n仍要继续安装吗？" IDYES xz_init_warn2_go
      Abort
      xz_init_warn2_go:
    ${EndIf}
    Sleep 1200
  xz_init_done:

  ; 装过没有？看数据目录里有没有 .env。有 → 设密码页会被跳过（见那边说明）。
  ; （$XZ_DATADIR 定下来之后，密码页还会按新位置重新判断一次。）
  StrCpy $XZ_HASENV "0"
  IfFileExists "__DATA_DIR__\.env" 0 xz_init_fresh
    StrCpy $XZ_HASENV "1"
  xz_init_fresh:

  ; ---------- 数据目录默认值（三步走）----------
  StrCpy $XZ_LEGACY "__DATA_DIR__"
  ; ① 装过 / 装过又重装的：注册表里记着上次选的位置 → 沿用，绝不擅自搬家
  ReadRegStr $XZ_DATADIR HKCU "Software\小智IM服务端" "DataDir"
  StrCmp $XZ_DATADIR "" 0 xz_dd_note_reuse
  ; ② 没记过但旧位置已有数据 → 沿用旧位置（老版本升级上来的就是这种）
  IfFileExists "__DATA_DIR__\.env" 0 xz_dd_pick_new
    StrCpy $XZ_DATADIR "__DATA_DIR__"
    Goto xz_dd_note_legacy
  xz_dd_pick_new:
  ; ③ 全新安装：有 D 盘就默认 D:\小智IM服务端\data（数据盘更安全），否则用系统默认
  StrCpy $XZ_DATADIR "__DATA_DIR__"
  IfFileExists "D:\*.*" 0 xz_dd_note_new
    StrCpy $XZ_DATADIR "D:\小智IM服务端\data"
  Goto xz_dd_note_new

  xz_dd_note_reuse:
    StrCpy $XZ_DATA_NOTE "已检测到本机装过（沿用上次的数据目录）。要换位置直接改上面的路径，安装时会问你要不要搬旧数据。"
    Goto xz_dd_done
  xz_dd_note_legacy:
    StrCpy $XZ_DATA_NOTE "检测到旧数据目录里有数据，已默认沿用原位置（不会搬动任何文件）。想迁到数据盘就把路径改掉，安装过程中会问你要不要搬。"
    Goto xz_dd_done
  xz_dd_note_new:
    StrCpy $XZ_DATA_NOTE "全新安装。建议放在数据盘（非系统盘）。安装时会自动创建这个目录。"
  xz_dd_done:
FunctionEnd

Section "小智IM 服务端" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "__SRC__\*.*"

  ; 升级清理（2026-10-09）：老版本把一堆 .cmd / .vbs / console.ps1 摊在安装根，
  ; 现在统一收进 _sys\。不清掉的话，升级完客户目录里又是"一堆命令脚本" ——
  ; 这一版改的正是这个观感（龙哥：入口应该是个 exe）。
  ; Delete 不递归，所以 _sys\ 里刚装好的那份不会被动到。
  Delete "$INSTDIR\*.cmd"
  Delete "$INSTDIR\*.vbs"
  Delete "$INSTDIR\console.ps1"

  ; ---------- 数据目录（刻意放在安装目录**之外**）----------
  ; 放里面的话卸载会连聊天记录、上传文件、授权状态一起删光。
  ; 位置来自向导页（$XZ_DATADIR）：默认沿用旧位置，也可选到数据盘。
  CreateDirectory "$XZ_DATADIR"
  CreateDirectory "$XZ_DATADIR\logs"
  CreateDirectory "$XZ_DATADIR\files"

  ; ---------- 旧数据搬迁（改了位置才有这一步）----------
  ; 只在「选了新位置」且「旧位置确实有数据」时问一句，同意就 xcopy 过去。
  ; 旧目录**保留不删** —— 搬一半断电、搬到一半反悔都有退路。
  ${If} $XZ_DATADIR != $XZ_LEGACY
    IfFileExists "$XZ_LEGACY\xiaozhi-im.db" 0 xz_mig_done
      MessageBox MB_YESNO|MB_ICONQUESTION "检测到旧数据目录里有数据：$\r$\n$XZ_LEGACY$\r$\n$\r$\n要搬到新数据目录吗？$\r$\n$XZ_DATADIR$\r$\n$\r$\n选「否」：保留原处不动，新目录以空数据启动（旧数据仍可在上面路径找到）。" IDNO xz_mig_done
      DetailPrint "正在搬迁旧数据（大目录可能要一会儿）…"
      nsExec::ExecToLog 'cmd /c xcopy "$XZ_LEGACY\*" "$XZ_DATADIR\" /E /I /Y /Q'
      Pop $0
      DetailPrint "旧数据搬迁完成（旧目录保留未删）。"
    xz_mig_done:
  ${EndIf}

  ; 记下本次选择的数据目录：重装时默认沿用；控制台 / 内部脚本也从这里读。
  WriteRegStr HKCU "Software\小智IM服务端" "DataDir" "$XZ_DATADIR"

  ; ---------- 生成 data\.env（管理台密码 + JWT 密钥）----------
  DetailPrint "生成配置文件与管理台密码 …"
  StrCmp $XZ_NEWPASS "" xz_env_nocustom
    ; 客户自己设了密码 → 写进临时文件再交给 init-env.js。
    ; 不拼命令行：密码里可能有 $ " 空格，会被 NSIS 和 cmd 二次解析，
    ; 轻则密码对不上，重则整条命令跑飞。
    FileOpen $9 "$TEMP\xz-password.tmp" w
    FileWrite $9 "$XZ_NEWPASS"
    FileClose $9
    nsExec::ExecToStack '"$INSTDIR\node\node.exe" "$INSTDIR\app\tools\init-env.js" "$XZ_DATADIR" "--password-file=$TEMP\xz-password.tmp"'
    Delete "$TEMP\xz-password.tmp"
    Goto xz_env_done
  xz_env_nocustom:
    nsExec::ExecToStack '"$INSTDIR\node\node.exe" "$INSTDIR\app\tools\init-env.js" "$XZ_DATADIR"'
  xz_env_done:
  Pop $0
  Pop $1

  ; 用 ReadINIStr 而不是解析 stdout：少一处"装出来密码是空的"
  ReadINIStr $XZ_PASS   "$XZ_DATADIR\.install-result.ini" "install" "adminPassword"
  ReadINIStr $XZ_CUSTOM "$XZ_DATADIR\.install-result.ini" "install" "passwordIsCustom"
  ReadINIStr $XZ_LAN    "$XZ_DATADIR\.install-result.ini" "install" "lanIp"
  Delete "$XZ_DATADIR\.install-result.ini"

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
    StrCpy $XZ_PASS_LINE "沿用原有密码（忘了的话：打开「小智IM 服务端控制台」点「查看管理员密码」）"
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
  ; 桌面 + 开始菜单都以「服务端控制台」为主入口（现在是一个真 exe，不再是 .cmd）：
  ; 启停/重启、开机自启、日志、查密码、防火墙都在它里面，
  ; 客户不用再记"哪个 .cmd 干什么"。
  ; 原来的单个脚本收进安装目录的 _sys\，只在开始菜单「高级工具」里露出快捷方式。
  CreateShortCut "$DESKTOP\小智IM 服务端控制台.lnk" "$INSTDIR\小智IM 服务端控制台.exe" "" "$INSTDIR\小智IM 服务端控制台.exe" 0
  CreateShortCut "$DESKTOP\小智IM 管理后台.lnk"     "$INSTDIR\_sys\打开管理后台.cmd" "" "$INSTDIR\_sys\打开管理后台.cmd" 0

  CreateDirectory "$SMPROGRAMS\${SHORT_NAME}"
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\小智IM 服务端控制台.lnk" "$INSTDIR\小智IM 服务端控制台.exe" "" "$INSTDIR\小智IM 服务端控制台.exe" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\打开管理后台.lnk"        "$INSTDIR\_sys\打开管理后台.cmd" "" "$INSTDIR\_sys\打开管理后台.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\卸载 ${SHORT_NAME}.lnk"  "$INSTDIR\uninst.exe"

  CreateDirectory "$SMPROGRAMS\${SHORT_NAME}\高级工具"
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\后台启动服务端.lnk"          "$INSTDIR\_sys\后台启动服务端.vbs" "" "$INSTDIR\_sys\后台启动服务端.vbs" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\启动服务端（前台看日志）.lnk" "$INSTDIR\_sys\启动服务端.cmd" "" "$INSTDIR\_sys\启动服务端.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\停止服务端.lnk"             "$INSTDIR\_sys\停止服务端.cmd" "" "$INSTDIR\_sys\停止服务端.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\查看管理员密码.lnk"         "$INSTDIR\_sys\查看管理员密码.cmd" "" "$INSTDIR\_sys\查看管理员密码.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\查看运行日志.lnk"           "$INSTDIR\_sys\查看运行日志.cmd" "" "$INSTDIR\_sys\查看运行日志.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\配置防火墙（需管理员）.lnk"  "$INSTDIR\_sys\配置防火墙.cmd" "" "$INSTDIR\_sys\配置防火墙.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\设为开机自启.lnk"           "$INSTDIR\_sys\设为开机自启.cmd" "" "$INSTDIR\_sys\设为开机自启.cmd" 0
  CreateShortCut "$SMPROGRAMS\${SHORT_NAME}\高级工具\取消开机自启.lnk"           "$INSTDIR\_sys\取消开机自启.cmd" "" "$INSTDIR\_sys\取消开机自启.cmd" 0

  WriteUninstaller "$INSTDIR\uninst.exe"

  ; ---------- 开机自启 ----------
  ; 写 HKCU 的 Run：登录 Windows 后由 wscript 隐藏窗口拉起。
  ; 用 HKCU 而不是 HKLM：用户级写入不需要管理员权限，卸载也好清。
  WriteRegStr HKCU "${RUN_KEY}" "XiaozhiIMServer" 'wscript.exe "$INSTDIR\_sys\后台启动服务端.vbs"'

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
  ; 先停服务 —— 走 _stop_silent.cmd（按端口），不按 node.exe 映像名杀。
  ; 同样两个位置都试：新版在 _sys\，老版本摊在安装根。
  IfFileExists "$INSTDIR\_sys\_stop_silent.cmd" 0 xz_un_try_legacy
    nsExec::ExecToLog 'cmd /c ""$INSTDIR\_sys\_stop_silent.cmd""'
    Pop $R0
    ${If} $R0 != 0
      IfSilent xz_un_warn1_go
      MessageBox MB_YESNO|MB_ICONEXCLAMATION "旧服务端可能仍在运行（自动停止未成功，返回：$R0）。$\r$\n$\r$\n继续卸载可能提示文件被占用。$\r$\n建议先在控制台点「停止服务端」或重启电脑后再卸载。$\r$\n$\r$\n仍要继续卸载吗？" IDYES xz_un_warn1_go
      Abort
      xz_un_warn1_go:
    ${EndIf}
    Sleep 1200
    Goto xz_un_stopped
  xz_un_try_legacy:
  IfFileExists "$INSTDIR\_stop_silent.cmd" 0 xz_un_stopped
    nsExec::ExecToLog 'cmd /c ""$INSTDIR\_stop_silent.cmd""'
    Pop $R0
    ${If} $R0 != 0
      IfSilent xz_un_warn2_go
      MessageBox MB_YESNO|MB_ICONEXCLAMATION "旧服务端可能仍在运行（自动停止未成功，返回：$R0）。$\r$\n$\r$\n继续卸载可能提示文件被占用。$\r$\n建议先在控制台点「停止服务端」或重启电脑后再卸载。$\r$\n$\r$\n仍要继续卸载吗？" IDYES xz_un_warn2_go
      Abort
      xz_un_warn2_go:
    ${EndIf}
    Sleep 1200
  xz_un_stopped:

  DeleteRegValue HKCU "${RUN_KEY}" "XiaozhiIMServer"

  RMDir /r "$INSTDIR"
  Delete "$DESKTOP\小智IM 管理后台.lnk"
  Delete "$DESKTOP\小智IM 服务端控制台.lnk"
  RMDir /r "$SMPROGRAMS\${SHORT_NAME}"
  DeleteRegKey HKCU "${UNINST_KEY}"

  ; ⚠️ 数据目录**刻意不删**：里面有聊天记录、上传的文件、授权状态。
  ;    静默卸载（/S）时不弹窗 —— 弹窗会把自动化部署挂死。
  ;    数据目录位置从注册表读（客户可能装在数据盘，不能写死默认路径）。
  ReadRegStr $XZ_DATADIR HKCU "Software\小智IM服务端" "DataDir"
  StrCmp $XZ_DATADIR "" 0 xz_un_havedir
    StrCpy $XZ_DATADIR "__DATA_DIR__"
  xz_un_havedir:
  IfSilent xz_un_silent
    MessageBox MB_OK "卸载完成。$\r$\n$\r$\n数据（聊天记录 / 上传文件 / 授权状态）已**保留**在：$\r$\n$XZ_DATADIR$\r$\n$\r$\n重新安装后会自动接着用；确定不再需要了，手动删掉上面这个文件夹即可。"
  xz_un_silent:
SectionEnd
