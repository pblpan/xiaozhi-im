# -*- coding: utf-8 -*-
"""把 Flutter Windows Release 产物打成 NSIS 单文件安装程序（Setup exe）。

【为什么要改】
以前分发的是 zip 绿色版：用户得自己解压、自己建快捷方式、自己记版本，
升级时新旧文件混在一块儿还容易残留。现在跟「工厂管理系统V2」统一成
**双击安装的 Setup.exe** —— 可选安装目录、自动建桌面/开始菜单快捷方式、
在「添加/删除程序」里能看到版本并能干净卸载。

【本机依赖】
NSIS 3.x（V2 用的也是它）：winget install -e --id NSIS.NSIS
"""
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
InstallDirRegKey HKLM "$${UNINST_KEY}" "InstallLocation"
RequestExecutionLevel admin
ShowInstDetails show
ShowUnInstDetails show
BrandingText "$${APP_NAME}"

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
  ; ⚠️ 覆盖安装时旧版本很可能正缩在托盘里跑着 —— exe/dll 被占用会导致
  ; 文件写不进去，装完一启动就是半新半旧的混合体。所以先把进程请出去。
  nsExec::Exec 'taskkill /F /IM $${EXE_NAME}'
  Sleep 500
FunctionEnd

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
  WriteRegStr   HKLM "$${UNINST_KEY}" "DisplayName"     "$${APP_NAME}"
  WriteRegStr   HKLM "$${UNINST_KEY}" "DisplayVersion"  "$${VERSION}"
  WriteRegStr   HKLM "$${UNINST_KEY}" "Publisher"       "$${PUBLISHER}"
  WriteRegStr   HKLM "$${UNINST_KEY}" "UninstallString" "$INSTDIR\uninst.exe"
  WriteRegStr   HKLM "$${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKLM "$${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\$${EXE_NAME},0"
  WriteRegDWORD HKLM "$${UNINST_KEY}" "EstimatedSize"   $InstSizeKB
  WriteRegDWORD HKLM "$${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "$${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; 同理：缩在托盘里的进程占着文件，不先请出去会留下删不干净的半截目录
  nsExec::Exec 'taskkill /F /IM $${EXE_NAME}'
  Sleep 500

  RMDir /r "$INSTDIR"
  Delete "$DESKTOP\$${APP_NAME}.lnk"
  RMDir /r "$SMPROGRAMS\$${APP_NAME}"
  DeleteRegKey HKLM "$${UNINST_KEY}"
SectionEnd
'''


def vi_version(version):
    """NSIS 的 VIProductVersion 只认 x.x.x.x 四位纯数字，0.9.2 → 0.9.2.0"""
    parts = [re.sub(r'\D', '', p) or '0' for p in version.split('.')]
    while len(parts) < 4:
        parts.append('0')
    return '.'.join(parts[:4])


def build_nsi(version, out_file, nsis_path):
    icon = os.path.join(HERE, 'windows', 'runner', 'resources', 'app_icon.ico')
    if not os.path.isfile(icon):
        raise SystemExit('找不到安装向导图标: ' + icon)

    nsi = NSI_TEMPLATE
    nsi = nsi.replace('__APP_NAME__', APP_NAME)
    nsi = nsi.replace('__EXE_NAME__', EXE_NAME)
    nsi = nsi.replace('__VERSION__', version)
    nsi = nsi.replace('__VI_VERSION__', vi_version(version))
    nsi = nsi.replace('__PUBLISHER__', '潘坚强')
    nsi = nsi.replace('__DEFAULT_DIR__', '$PROGRAMFILES64\\' + APP_NAME)
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
    if not os.path.isdir(SRC):
        print('找不到构建产物:', SRC)
        print('先跑： flutter build windows --release')
        return 1

    version = read_version()
    makensis = find_makensis()
    print('NSIS 编译器:', makensis)

    tmp_root = os.path.join(HERE, 'build', 'windows', 'nsis')
    os.makedirs(tmp_root, exist_ok=True)
    out_name = '小智IM-Setup-v%s.exe' % version
    out_path = os.path.join(tmp_root, out_name)
    if os.path.exists(out_path):
        os.remove(out_path)

    script = build_nsi(version, out_path, os.path.join(tmp_root, 'installer.nsi'))
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

    if os.path.isdir(DESKTOP_DIR):
        dst = os.path.join(DESKTOP_DIR, out_name)
        shutil.copy2(out_path, dst)
        print('已复制到桌面: ' + dst.replace('/', '\\'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
