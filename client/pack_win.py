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
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'build', 'windows', 'x64', 'runner', 'Release')
DESKTOP_DIR = os.path.join('D:', os.sep, 'Users', 'pblpa', 'Desktop', '小智 IM')
APP_NAME = '小智 IM'
EXE_NAME = 'xiaozhi_im_client.exe'


def read_version():
    """版本号唯一来源：pubspec.yaml（避免打包脚本和代码里写两处不一致）"""
    with open(os.path.join(HERE, 'pubspec.yaml'), encoding='utf-8') as f:
        m = re.search(r'^version:\s*([0-9A-Za-z.+_-]+)', f.read(), re.M)
    if not m:
        raise SystemExit('pubspec.yaml 里读不到 version')
    return m.group(1).split('+')[0]


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
InstallDirRegKey __REG_ROOT__ "$${UNINST_KEY}" "InstallLocation"
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

Function .onInit
  Call __KILL_MAIN__
FunctionEnd

__KILL_FN__

Section "主程序" SEC_MAIN
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; Flutter Windows 必须整体分发：exe + 各插件 dll + data/flutter_assets，缺一不可
  File /r "__SRC__\*.*"

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


def build_nsi(version, out_file, nsis_path, per_user=True):
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
    nsi = nsi.replace('__ICON__', icon)
    nsi = nsi.replace('__OUT_FILE__', out_file)
    nsi = nsi.replace('$$', '$')  # 模板里写成双写，避免和 NSIS 语法混淆

    # ⚠️ NSIS 按 ANSI 读脚本会把中文变成乱码方块，必须是 UTF-8 **带 BOM**。
    # 少了 BOM 时安装界面上是问号，而且这类问题只有真跑安装才看得出来。
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

    script = build_nsi(version, out_path, os.path.join(tmp_root, 'installer.nsi'),
                       per_user=per_user)
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
