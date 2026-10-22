# -*- coding: utf-8 -*-
"""把 Flutter Windows Release 产物打成 NSIS 单文件安装程序（Setup exe）。

【为什么要改】
以前分发的是 zip 绿色版：用户得自己解压、自己建快捷方式、自己记版本，
升级时新旧文件混在一块儿还容易残留。现在跟「工厂管理系统V2」统一成
**双击安装的 Setup.exe** —— 可选安装目录、自动建桌面/开始菜单快捷方式、
在「添加/删除程序」里能看到版本并能干净卸载。

【两种安装范围】
默认 **per-user（用户级）**：装到 `%LOCALAPPDATA%\\Programs\\小智 IM`，
卸载信息写 HKCU，**全程不弹 UAC**。这条跟 V2 完全一致 —— V2 的
electron-builder 配置里没写 perMachine（默认 false），装出来就是
`%LOCALAPPDATA%\\Programs\\FactoryV2` + HKCU 卸载项（带 `/currentuser`），
装的时候不会要管理员密码。顺带的好处：以后升级也不用提权，
而且能自动化跑静默安装来验证。

要装到 Program Files（需要 UAC 提权）就加 `--machine`。

【本机依赖】
NSIS 3.x（V2 用的也是它）：winget install -e --id NSIS.NSIS
"""
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'build', 'windows', 'x64', 'runner', 'Release')
DESKTOP_DIR = os.path.join('D:', os.sep, '项目文件夹', '小智 IM')
APP_NAME = '小智 IM'
EXE_NAME = 'xiaozhi_im_client.exe'


def read_version():
    """版本号唯一来源：pubspec.yaml（避免打包脚本和代码里写两处不一致）"""
    with open(os.path.join(HERE, 'pubspec.yaml'), encoding='utf-8') as f:
        m = re.search(r'^version:\s*([0-9A-Za-z.+_-]+)', f.read(), re.M)
    if not m:
        raise SystemExit('pubspec.yaml 里读不到 version')
    return m.group(1).split('+')[0]


def write_integrity_stamp():
    """在 Release 目录写 integrity.dat —— 客户端启动时用它核对程序文件没被改过。

    【为什么是这两个文件】
      小智IM.exe          → 外壳（窗口/插件加载）；被换成别的程序就是最粗暴的替换
      data/app.so         → **真正的 Dart AOT 代码**都在这里。只校验 exe 是没用的：
                            改代码的人动的是 app.so，exe 一个字节都不碰。

    【强度要说清楚，别当成 Android 那套】
      这是**篡改检测（减速带）**，不是密码学保证：清单和程序文件放在一起，
      有心人把校验点一起改掉就过了。Windows 上没有代码签名证书就不存在
      等价于 Android「签名指纹」的硬判据。它的价值是拦住"换个 exe、
      改个 app.so"这类省事的做法，并留下明确痕迹。

    【为什么必须由打包脚本生成】哈希是构建产物的一部分，每次构建都会变；
    写死在代码里等于每次发版都要手工改两个哈希（必漏）。
    """
    targets = ['xiaozhi_im_client.exe', 'data/app.so']
    files = {}
    for rel in targets:
        p = os.path.join(SRC, rel.replace('/', os.sep))
        if not os.path.isfile(p):
            raise SystemExit('完整性清单要用的文件不存在：%s\n'
                             '（先跑 flutter build windows --release）' % p)
        h = hashlib.sha256()
        with open(p, 'rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        files[rel] = h.hexdigest()

    stamp = {
        'algo': 'sha256',
        'build': read_version(),
        'files': files,
    }
    out = os.path.join(SRC, 'integrity.dat')
    # 换行统一成 \n：客户端只做 jsonDecode，不依赖行尾
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(stamp, f, ensure_ascii=False, indent=2)
    for k, v in files.items():
        print('  完整性清单 %-20s %s' % (k, v[:16] + '…'))
    return out


def find_makensis():
    for cand in (
        os.environ.get('MAKENSIS'),
        os.path.join('C:', os.sep, 'Program Files (x86)', 'NSIS', 'makensis.exe'),
        os.path.join('C:', os.sep, 'Program Files', 'NSIS', 'makensis.exe'),
    ):
        if cand and os.path.isfile(cand):
            return cand
    for cand in ('makensis', 'makensis.exe'):
        p = shutil.which(cand)
        if p:
            return p
    raise SystemExit(
        '找不到 NSIS 编译器 makensis.exe。\n'
        '  winget install -e --id NSIS.NSIS\n'
        '装好后重新运行本脚本（或设 MAKENSIS 环境变量指到 makensis.exe）。'
    )


# ── VC++ 运行库随程序目录分发（app-local）──────────────────────────────
# 【为什么必须带】
#   Flutter 产物静态依赖 msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll。
#   这些**不是**每台机器都有（干净的 Win10、LTSC、刚重装的系统都可能没有），
#   用户看到的就是「计算机中丢失 msvcp140.dll」这类报错。
#   用户的要求是"在安装包上解决"，所以把它们随程序目录一起分发 —— 免 UAC、
#   不用装 VC++ Redist、不触发重启（app-local 部署是微软官方支持的方式）。
#
# 【为什么只带这三个，不带 UCRT（api-ms-win-crt-*.dll）】
#   UCRT 只有 Win7/8 才需要单独补；而 Win10 起 UCRT 本身就是操作系统组件。
#   偏偏 Win7/8 又跑不了这个程序（原因见 NSI 模板里的「系统版本闸门」注释），
#   所以带 UCRT 属于"给一个永远用不上的场景增加体积和加载风险"。
#
# 【版本必须和工具集对齐】
#   本机工具集 14.44（实测 PE linker 版本），所以从 VS2022 的
#   Redist\MSVC\14.44.*\x64\Microsoft.VC143.CRT 取 —— 这是微软明确允许再分发的目录。
REDIST_DLLS = ('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')


def _ver_key(path):
    m = re.search(r'MSVC[\\/](\d+(?:\.\d+)+)', path)
    return [int(x) for x in m.group(1).split('.')] if m else [0]


def find_crt_redist():
    """定位可再分发的 VC++ CRT 目录；多个版本时取版本号最高的。"""
    pats = []
    for base in (os.path.join('C:', os.sep, 'Program Files (x86)', 'Microsoft Visual Studio'),
                 os.path.join('C:', os.sep, 'Program Files', 'Microsoft Visual Studio')):
        pats.append(os.path.join(base, '2022', '*', 'VC', 'Redist', 'MSVC',
                                 '*', 'x64', 'Microsoft.VC143.CRT'))
    cands = []
    for p in pats:
        cands += [d for d in glob.glob(p) if os.path.isdir(d)]
    override = os.environ.get('VCCRT_REDIST')
    if override and os.path.isdir(override):
        cands.insert(0, override)
    return sorted(cands, key=_ver_key)[-1] if cands else None


def stage_redist(dst):
    """把所需的 VC++ 运行库拷到暂存目录，返回 (来源目录, 文件名列表)。"""
    src = find_crt_redist()
    if not src:
        raise SystemExit(
            '找不到可再分发的 VC++ 运行库目录 Microsoft.VC143.CRT。\n'
            '  需要装 VS2022 的「使用 C++ 的桌面开发」工作负载，\n'
            '  或设 VCCRT_REDIST 环境变量指向该目录（内含 vcruntime140.dll 等）。\n'
            '  ⚠️ 不要"跳过算了" —— 少了它，干净的 Windows 上装完会报「丢失 msvcp140.dll」。')
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    for name in REDIST_DLLS:
        s = os.path.join(src, name)
        if not os.path.isfile(s):
            raise SystemExit('运行库缺文件：%s' % s)
        shutil.copy2(s, os.path.join(dst, name))
    return src, list(REDIST_DLLS)


# 模板里 $ 是 NSIS 变量前缀，Python 不做格式化，全部用占位符替换，
# 只有本文件自己控制的 twin $ 写成 $$ 会在下面统一还原成单个 $。
NSI_TEMPLATE = r'''; 由 client/pack_win.py 自动生成 —— 手工改动会在下次打包时被覆盖
Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64
SetDatablockOptimize on

!include "MUI2.nsh"
!include "FileFunc.nsh"

!insertmacro GetSize

!define APP_NAME   "__APP_NAME__"
!define EXE_NAME   "__EXE_NAME__"
!define VERSION    "__VERSION__"
!define PUBLISHER  "__PUBLISHER__"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\__APP_NAME__"

Name "$${APP_NAME} $${VERSION}"
OutFile "__OUT_FILE__"
InstallDir "__DEFAULT_DIR__"
; ⚠️ 这里**故意不用** InstallDirRegKey —— 它会把注册表里记的旧 InstallLocation
;    无条件当成安装目录。本机就真踩到过：HKCU 里躺着一条历史遗留的
;    `D:\Program Files (x86)\小智 IM`（早期 --machine 装法留下的），
;    结果新的**用户级**安装包被它劫持到那个目录去，"装到哪了"和预期完全不符。
;    现在改成在 .onInit 里带条件采纳 —— 见 INSTDIR_GUARD。
RequestExecutionLevel __EXEC_LEVEL__
ShowInstDetails show
ShowUnInstDetails show
BrandingText "$${APP_NAME}"

; 快捷方式只建给当前用户：NSIS 的 $DESKTOP / $SMPROGRAMS 默认就是当前用户
; （ShellVarContext 默认 current）。**不要**在全局写 SetShellVarContext
; —— 它只能在 Section / Function 里调用，放全局直接编译不过。
; 顺带记一笔：本机桌面被重定向到 d:\Users\pblpa\Desktop，已用探针确认
; $DESKTOP 会跟随重定向，所以这里不需要自己去读注册表兜底。

; 写进 exe 的版本资源：右键「属性 → 详细信息」里能看到版本号。
; 没有它的话，安装包发出去后谁也分不清手上的 bin 是哪个版本。
VIProductVersion "__VI_VERSION__"
VIFileVersion "__VI_VERSION__"
VIAddVersionKey "ProductName" "$${APP_NAME}"
VIAddVersionKey "ProductVersion" "$${VERSION}"
VIAddVersionKey "FileDescription" "$${APP_NAME} $${VERSION} 安装程序"
VIAddVersionKey "CompanyName" "$${PUBLISHER}"
VIAddVersionKey "FileVersion" "__VI_VERSION__"
VIAddVersionKey "LegalCopyright" "Copyright © $${PUBLISHER}"

; 安装/卸载向导的图标：直接用 Flutter runner 的同款图标，省得再维护一份
!define MUI_ICON      "__ICON__"
!define MUI_UNICON    "__ICON__"
!define MUI_ABORTWARNING
; 装完立刻能启动 —— 这是把"托盘收消息"这件事交给用户看的第一眼
!define MUI_FINISHPAGE_RUN "$INSTDIR\$${EXE_NAME}"
!define MUI_FINISHPAGE_RUN_TEXT "立即启动 $${APP_NAME}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Var InstSizeKB

__OS_GATE__

__KILL_FN__

Section "主程序" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; Flutter Windows 必须整体分发：exe + 各插件 dll + data/flutter_assets，缺一不可
  File /r "__SRC__\*.*"

  ; VC++ 运行库随程序目录分发（app-local）—— 直接摊在 exe 同目录，
  ; 不装 VC++ Redist、不提权、不重启。缺了它们，干净的 Windows 上会报
  ; 「计算机中丢失 msvcp140.dll」。（为什么只带这三个、不带 UCRT：见 pack_win.py 注释）
  File /r "__REDIST__\*.*"

  $${GetSize} "$INSTDIR" "/M=*.* /S=0K" $0 $1 $2
  IntFmt $InstSizeKB "0x%08X" $0

  CreateShortCut "$DESKTOP\$${APP_NAME}.lnk" "$INSTDIR\$${EXE_NAME}" "" "$INSTDIR\$${EXE_NAME}" 0
  CreateDirectory "$SMPROGRAMS\$${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\$${APP_NAME}\$${APP_NAME}.lnk" "$INSTDIR\$${EXE_NAME}" "" "$INSTDIR\$${EXE_NAME}" 0
  CreateShortCut "$SMPROGRAMS\$${APP_NAME}\卸载 $${APP_NAME}.lnk" "$INSTDIR\uninst.exe"

  WriteUninstaller "$INSTDIR\uninst.exe"

  ; 写进「添加/删除程序」，卸载入口永远找得到，版本号也一眼可见
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "DisplayName"     "$${APP_NAME}"
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "DisplayVersion"  "$${VERSION}"
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "Publisher"       "$${PUBLISHER}"
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "UninstallString" "$INSTDIR\uninst.exe"
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "QuietUninstallString" "$INSTDIR\uninst.exe /S"
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   __REG_ROOT__ "$${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\$${EXE_NAME},0"
  WriteRegDWORD __REG_ROOT__ "$${UNINST_KEY}" "EstimatedSize"   $InstSizeKB
  WriteRegDWORD __REG_ROOT__ "$${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD __REG_ROOT__ "$${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; 同理：缩在托盘里的进程占着文件，不先请出去会留下删不干净的半截目录
  Call un.__KILL_MAIN__

  ; ⚠️ 只删安装目录。登录状态和聊天记录在
  ;    %APPDATA%\com.example\xiaozhi_im_client 下，**卸载不能碰**（见文档 3.2）。
  RMDir /r "$INSTDIR"
  Delete "$DESKTOP\$${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\$${APP_NAME}"
  DeleteRegKey __REG_ROOT__ "$${UNINST_KEY}"
SectionEnd
'''


# 安装/卸载共用的「把正在运行的旧实例请出去」逻辑。
# ⚠️ 这段是 Python 侧注入的，里面写**单 `$`**（模板里为了跟 Python 语法区分才双写），
#    注入发生在全局 `$$`→`$` 还原之前，两边互不干扰。
KILL_FN_HEAD = r'''; ---- 把正在运行的旧实例请出去（安装与卸载共用同一套逻辑）----
; 为什么不只一个 taskkill 就完事：
;   1) 覆盖安装时旧版本很可能正缩在托盘里跑着，exe/dll 被占用 → 文件写不进去，
;      装完一启动就是"半新半旧"的混合体。
;   2) ⚠️ **taskkill 会静默失败**。实测（2026-09-13）：旧实例若是以管理员身份
;      启动的，非提权的 taskkill 返回 1「拒绝访问」，而"不管退出码"的旧写法
;      会以为自己请走了 —— 这就是一句假承诺。
; 复核不用解析 tasklist 输出（那个随系统语言变），而是直接**试着写打开**
; $INSTDIR 里的 exe：还在跑 → 拒绝访问；没在跑 → 打开成功（两种状态都实测过）。
Function __KILL_MAIN__
  StrCpy $R0 0                        ; 已重试次数
  kill_loop:
    nsExec::ExecToStack 'taskkill /F /IM ${EXE_NAME}'
    Pop $R1                           ; 退出码：0 已结束 / 128 本来没跑 / 1 拒绝访问
    Pop $R2
    Sleep 400
    IfFileExists "$INSTDIR\${EXE_NAME}" 0 kill_done     ; 首次安装没这文件，收工
    ClearErrors
    FileOpen $R3 "$INSTDIR\${EXE_NAME}" a
    IfErrors 0 kill_release           ; 能写打开 = 确实没在跑了
    IntOp $R0 $R0 + 1
    IntCmp $R0 3 kill_giveup kill_loop kill_loop
'''

KILL_FN_PROMPT = r'''  kill_giveup:
    ; 只有非静默安装才弹窗 —— 静默安装弹窗会把自动化 / 批量部署挂死
    IfSilent kill_done
    MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION "检测到旧版「${APP_NAME}」仍在运行，且无法自动关闭（多半是以管理员身份启动的）。$\r$\n$\r$\n请在右下角托盘图标上右键 →「退出 ${APP_NAME}」，再点「确定」继续；点「取消」放弃安装。" /SD IDOK IDOK kill_done IDCANCEL kill_abort
  kill_abort:
    Abort
'''

# 卸载版的放弃分支：**不弹窗、不中断**。卸载到一半退出只会留下删不干净的
# 半截目录，还不如尽力删完，把残留直接摆给用户看。
KILL_FN_GIVEUP_UNINST = r'''  kill_giveup:
    Goto kill_done
'''

KILL_FN_TAIL = r'''  kill_release:
    FileClose $R3
  kill_done:
FunctionEnd
'''


# 判据函数：单独抽出来是为了**能被测试**（见 tools/verify_win7_gate.py）。
# 安装脚本里的逻辑没法直接单测，所以把"版本号 → 是否不受支持"这一段做成
# 只依赖 $R0 的纯函数，测试脚本用同一份常量编译出测试程序去跑 —— 测的就是生产逻辑本身。
#
# 输入 $R0 = HKLM\...\CurrentVersion（NT 版本号，不是营销版本号！）
#   6.0=Vista  6.1=Win7  6.2=Win8  6.3=Win8.1  10.0=Win10/11
# 输出 $OsIsOld = 1 表示"不支持，要拦"，0 表示放行。
OS_CHECK_FN = r'''Var OsIsOld

Function CheckWinOld
  StrCpy $OsIsOld 0
  StrCmp $R0 "5.0" oscheck_old      ; 2000
  StrCmp $R0 "5.1" oscheck_old      ; XP
  StrCmp $R0 "5.2" oscheck_old      ; 2003
  StrCmp $R0 "6.0" oscheck_old      ; Vista
  StrCmp $R0 "6.1" oscheck_old      ; 7
  StrCmp $R0 "6.2" oscheck_old      ; 8
  StrCmp $R0 "6.3" oscheck_old      ; 8.1
  Goto oscheck_done
  oscheck_old:
    StrCpy $OsIsOld 1
  oscheck_done:
FunctionEnd
'''

# 安装前的「系统版本闸门」。**必须在 Python 侧注入**（写单 `$`）——
# 模板字符串后面还会过一次 `$$`→`$` 的还原，直接写在模板里得把每个 $ 都双写，容易错。
OS_GATE = r'''; ── 系统版本闸门：Win7/8 跑不了，而且**不是补 DLL 能解决的** ──────────
; 【本机实测】pefile 解析 build\windows\x64\runner\Release 下所有 PE：
;   静态导入 Windows 8+ 专属接口共 10 处，且**无一例外全是静态导入**
;   （没有延迟导入 = 加载模块时就要解析符号 = 进程直接起不来）：
;     flutter_windows.dll             -> ws2_32.dll!GetHostNameW          (Win8 新增导出)
;     flutter_windows.dll             -> api-ms-win-core-synch-l1-2-0.dll
;     flutter_webrtc_plugin.dll       -> api-ms-win-core-winrt-l1-1-0.dll!RoInitialize/RoUninitialize
;     libwebrtc.dll                   -> api-ms-win-shcore-scaling-l1-1-1.dll!GetDpiForMonitor 等
;     audioplayers_windows_plugin.dll -> api-ms-win-core-winrt-error-l1-1-1.dll 等
;   Windows 7 的 ws2_32.dll 里**没有** GetHostNameW 这个符号，Win7/8 也没有
;   WinRT 与 Shcore 这两个子系统。而这些符号属于**操作系统自身**，
;   随程序目录放任何 DLL 都提供不了 → 补运行库救不了 Win7，换哪个安装包也一样。
; 【官方旁证】Flutter 自 3.19（Dart 3.3）起正式终止 Windows 7/8 支持；本机 Flutter 3.47.2。
;
; 所以这里做「安装前拦截 + 把原因说清楚」，而不是让用户装完再看到
; 「无法定位程序输入点 GetHostNameW」这种天书 —— 那才会变成"你们的软件是坏的"。
; 静默安装**不弹窗**（弹窗会把批量部署/自动化挂死），直接放行，由部署方自己判断。
__OS_CHECK_FN__
Function .onInit
  SetRegView 64
  ReadRegStr $R0 HKLM "SOFTWARE\Microsoft\Windows NT\CurrentVersion" CurrentVersion
  SetRegView lastused
  Call CheckWinOld
  StrCmp $OsIsOld 0 oscheck_pass
  IfSilent oscheck_pass
  MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION "检测到当前系统是 Windows 8.1 或更早的版本（最常见的是 Windows 7），本程序在它上面无法运行。$\r$\n$\r$\n【原因】小智 IM 桌面端基于 Flutter 构建，Flutter 自 3.19 起已正式停止支持 Windows 7/8。程序依赖 Windows 8 才有的系统接口（ws2_32.dll 的 GetHostNameW）以及 WinRT、Shcore 组件，Windows 7 上不存在这些东西。这不是缺少某个 DLL，随安装包补运行库也无法解决。$\r$\n$\r$\n【建议】$\r$\n  · 把这台电脑升级到 Windows 10 / 11（推荐）$\r$\n  · 或改用手机端（Android 安装包），功能一致$\r$\n$\r$\n点「确定」可以强行继续安装（装完很可能启动失败）；点「取消」退出安装。" IDOK oscheck_pass IDCANCEL oscheck_abort
  oscheck_abort:
    Abort
  oscheck_pass:
  __INSTDIR_GUARD__
  Call __KILL_MAIN__
FunctionEnd
'''

# 安装位置守卫：**有条件**地采纳注册表里记的旧安装位置。
#
# 为什么要带条件：NSIS 的 InstallDirRegKey 是无条件采纳的 —— 只要那条
# InstallLocation 还在，安装就往那儿走，哪怕它指向的是上一个装法留下的、
# 跟本次安装范围（用户级 / 机器级）根本不搭的地方。实测踩坑：
#   HKCU\...\Uninstall\小智 IM 里记着 D:\Program Files (x86)\小智 IM
#   （早期 --machine 的产物），于是用户级的 Setup 静默装到了 Program Files 下，
#   冒烟脚本按预期目录去核对，直接 30 个文件"全缺"。
#
# 现在的口径：**只有那个目录里确实躺着我们的主程序**，才认为这是"就地升级"；
# 否则一律回落到 InstallDir 的默认位置。这样既保住了"装在自定义目录里也能原地
# 升级"，又不会被一条陈旧残留牵着走 —— 判据落在"程序在不在"，而不是"键在不在"。
INSTDIR_GUARD = r'''  ; 有条件的就地升级：注册表里的旧位置必须**真的有我们的 exe** 才采纳
  ReadRegStr $R1 __REG_ROOT__ "${UNINST_KEY}" "InstallLocation"
  StrCmp $R1 "" instdir_use_default
  IfFileExists "$R1\${EXE_NAME}" 0 instdir_use_default
    StrCpy $INSTDIR $R1
  instdir_use_default:'''


def instdir_guard_nsis():
    # ⚠️ 里面的 __REG_ROOT__ 故意**不在这里**替换：write_nsi 里是先插 OS_GATE
    #    （第 468 行）再统一替换 __REG_ROOT__（第 477 行）。在这里硬编成 HKCU，
    #    --machine 装法就会去读用户级的卸载项，等于给个永远匹配不上的位置。
    return INSTDIR_GUARD


def os_gate_nsis():
    return (OS_GATE
            .replace('__OS_CHECK_FN__', OS_CHECK_FN)
            .replace('__INSTDIR_GUARD__', instdir_guard_nsis())
            .replace('__KILL_MAIN__', 'KillRunningApp'))


def kill_functions():
    """生成安装版 + 卸载版的「请走旧实例」函数。

    两版共用 HEAD / TAIL，只有"放弃"分支不同 —— 安装时该拦就拦（装出个
    半新半旧的最难查），卸载时应尽力而为。
    """
    inst = (KILL_FN_HEAD.replace('__KILL_MAIN__', 'KillRunningApp')
            + KILL_FN_PROMPT + KILL_FN_TAIL)
    un = (KILL_FN_HEAD.replace('__KILL_MAIN__', 'un.KillRunningApp')
          + KILL_FN_GIVEUP_UNINST + KILL_FN_TAIL)
    return inst + '\n' + un


def vi_version(version):
    """NSIS 的 VIProductVersion 只认 x.x.x.x 四位纯数字，0.9.2 → 0.9.2.0"""
    parts = [re.sub(r'\D', '', p) or '0' for p in version.split('.')]
    while len(parts) < 4:
        parts.append('0')
    return '.'.join(parts[:4])


def build_nsi(version, out_file, nsis_path, redist_dir, per_user=True):
    icon = os.path.join(HERE, 'windows', 'runner', 'resources', 'app_icon.ico')
    if not os.path.isfile(icon):
        raise SystemExit('找不到安装向导图标: ' + icon)

    if per_user:
        # 跟 V2 的 electron-builder（perMachine: false）一致：用户级、免 UAC
        default_dir = r'$LOCALAPPDATA\Programs' + '\\' + APP_NAME
        reg_root = 'HKCU'
        exec_level = 'user'
    else:
        default_dir = r'$PROGRAMFILES64' + '\\' + APP_NAME
        reg_root = 'HKLM'
        exec_level = 'admin'

    nsi = NSI_TEMPLATE
    nsi = nsi.replace('__OS_GATE__', os_gate_nsis())
    nsi = nsi.replace('__KILL_FN__', kill_functions())
    nsi = nsi.replace('__KILL_MAIN__', 'KillRunningApp')
    nsi = nsi.replace('__APP_NAME__', APP_NAME)
    nsi = nsi.replace('__EXE_NAME__', EXE_NAME)
    nsi = nsi.replace('__VERSION__', version)
    nsi = nsi.replace('__VI_VERSION__', vi_version(version))
    nsi = nsi.replace('__PUBLISHER__', '潘坚强')
    nsi = nsi.replace('__DEFAULT_DIR__', default_dir)
    nsi = nsi.replace('__REG_ROOT__', reg_root)
    nsi = nsi.replace('__EXEC_LEVEL__', exec_level)
    nsi = nsi.replace('__SRC__', SRC)
    nsi = nsi.replace('__REDIST__', redist_dir)
    nsi = nsi.replace('__ICON__', icon)
    nsi = nsi.replace('__OUT_FILE__', out_file)
    nsi = nsi.replace('$$', '$')  # 模板里写成双写，避免和 NSIS 语法混淆

    # ⚠️ NSIS 按 ANSI 读脚本会把中文变成乱码方块，必须是 UTF-8 **带 BOM**。
    # 少了 BOM 时安装界面上是问号，而且这类问题只有真跑安装才看得出来。
    #
    # ⚠️ 写之前先把行尾归一成 LF：本机 git 配了 core.autocrlf=true，这个 .py
    #    被重新检出后会变成 CRLF，模板字符串里也就跟着带 \r\n，而下面
    #    newline='\r\n' 会把每个 \n 再补一个 \r —— 叠加成 \r\r\n。属于
    #    "今天能编、过几天突然编不过"的那类坑，一行归一化挡掉。
    nsi = nsi.replace('\r\n', '\n')
    with open(nsis_path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
        f.write(nsi)
    return nsis_path


def main():
    ap = argparse.ArgumentParser(description='打包 Windows NSIS 安装程序')
    ap.add_argument('--machine', action='store_true',
                    help='装到 Program Files（需要 UAC 提权）。默认是用户级免 UAC 安装。')
    ap.add_argument('--no-deliver', action='store_true',
                    help='只生成到 build 目录，不复制到桌面交付目录（自测用）')
    args = ap.parse_args()

    if not os.path.isdir(SRC):
        print('找不到构建产物:', SRC)
        print('先跑： flutter build windows --release')
        return 1

    version = read_version()
    makensis = find_makensis()
    per_user = not args.machine
    print('NSIS 编译器:', makensis)
    print('安装范围: %s' % ('用户级（免 UAC，%LOCALAPPDATA%\\Programs）' if per_user
                          else '全局（需 UAC，%PROGRAMFILES64%）'))

    tmp_root = os.path.join(HERE, 'build', 'windows', 'nsis')
    os.makedirs(tmp_root, exist_ok=True)
    out_name = '小智IM-Setup-v%s.exe' % version
    out_path = os.path.join(tmp_root, out_name)
    if os.path.exists(out_path):
        os.remove(out_path)

    # ⚠️ 顺序不能反：NSIS 脚本里是 `File /r __SRC__\*.*` —— 把 Release 目录里
    #    **当下存在的一切**打进包。必须先把清单写进去，它才会被一起打包。
    print('生成完整性清单（客户端启动时用它核对程序有没有被改过）…')
    write_integrity_stamp()

    print('准备 VC++ 运行库（随程序目录分发，免得用户遇到「丢失 msvcp140.dll」）…')
    redist_dir = os.path.join(tmp_root, 'redist_x64')
    redist_src, redist_files = stage_redist(redist_dir)
    print('  来源: %s' % redist_src)
    print('  带入: %s' % '、'.join(redist_files))

    script = build_nsi(version, out_path, os.path.join(tmp_root, 'installer.nsi'),
                       redist_dir, per_user=per_user)
    print('已生成安装脚本:', script)

    r = subprocess.run([makensis, '/V2', script], cwd=tmp_root,
                       capture_output=True, text=True, encoding='utf-8',
                       errors='replace')
    tail = '\n'.join((r.stdout or '').splitlines()[-10:])
    if tail:
        print(tail)
    if r.returncode != 0 or not os.path.isfile(out_path):
        print('NSIS 编译失败，退出码', r.returncode)
        print((r.stderr or '')[-2000:])
        return 1

    print('生成安装包: %s（%.1f MB）' %
          (out_path, os.path.getsize(out_path) / 1024 / 1024))

    if not args.no_deliver and os.path.isdir(DESKTOP_DIR):
        dst = os.path.join(DESKTOP_DIR, out_name)
        shutil.copy2(out_path, dst)
        print('已复制到桌面: ' + dst.replace('/', '\\'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
