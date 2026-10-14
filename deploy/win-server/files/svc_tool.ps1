# ============================================================
#  小智IM 服务端 —— Windows 服务注册 / 卸载（无界面，由控制台提权后运行）
#
#  为什么单独一个文件，而不是让控制台按钮提权后重拉 console.ps1：
#    ① console.ps1 是 900 行的 WinForms UI 脚本，"无头"重拉它要连带解析
#       整个 param 块和全部 UI 代码 —— 任何一处编码/解析问题都会让提权
#       进程跑偏（2026-10-14 实测过一次：装机文件双 BOM 导致首行 # 注释
#       失效，提权进程把整个 UI 又拉了起来，服务却没注册）。
#    ② 这个脚本只干一件事，出错了用户看到的就是这件事的错。
#
#  调用方式（控制台按钮发起，必然带 UAC）：
#    powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden ^
#      -File "svc_tool.ps1" -Action Register -AppRoot "..." -DataDir "..." -Port 3602
#  ⚠️ 路径带空格（Program Files / 中文目录名），调用方必须自己带引号 ——
#     Start-Process -ArgumentList 用数组会被无引号空格拼接坑到
#     （见 console.ps1 里拼 argline 的注释）。
#
#  编码：UTF-8 带 BOM（PowerShell 5.1 的硬要求，见 pack_server_win.py）。
# ============================================================
param(
    [ValidateSet('Register', 'Unregister')]
    [string]$Action = 'Register',
    [string]$AppRoot = '',
    [string]$DataDir = '',
    [int]$Port = 3602
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'XiaozhiIMServer'
$ServiceDisplay = '小智IM 服务端'

function Write-SvcLog {
    param([string]$DataDir, [string]$Text)
    if ([string]::IsNullOrWhiteSpace($DataDir)) { return }
    try {
        $dir = Join-Path $DataDir 'logs'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path (Join-Path $dir 'svc_register.log') -Value ($stamp + ' ' + $Text) -Encoding UTF8
    } catch { }
}

function Show-Result {
    param([string]$Title, [string]$Body)
    # 提权进程有桌面，可以直接弹框 —— 用户点了按钮总得知道成没成
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($Body, $Title, 'OK', 'Information') | Out-Null
}

# ---------- 基本校验 ----------
if ([string]::IsNullOrWhiteSpace($AppRoot) -or -not (Test-Path $AppRoot)) {
    Write-Host "安装目录无效：$AppRoot"
    exit 2
}
$Node = Join-Path $AppRoot 'node\node.exe'
$AppJs = Join-Path $AppRoot 'app\src\index.js'
if (-not (Test-Path $Node) -or -not (Test-Path $AppJs)) {
    Write-Host "找不到 node 或服务端入口（$Node / $AppJs）"
    exit 2
}
if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $DataDir = Join-Path $env:LOCALAPPDATA '小智IM服务端\data'
}
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

# ============================================================
#  卸载
# ============================================================
if ($Action -eq 'Unregister') {
    $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $s) {
        Write-SvcLog $DataDir 'unregister：服务本就没注册，无事发生'
        Show-Result '卸载完成' '这台电脑上没有注册过小智IM 服务端。'
        exit 0
    }
    if ($s.Status -eq 'Running') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        # 等它真停（最多 10 秒）。Refresh 包 try：服务对象状态异常时
        # 不该刷出一屏错误把用户吓到。
        for ($i = 0; $i -lt 20; $i++) {
            try { $s.Refresh() } catch { break }
            if ($s.Status -ne 'Running') { break }
            Start-Sleep -Milliseconds 500
        }
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Milliseconds 500
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-SvcLog $DataDir 'unregister：删除失败'
        Show-Result '卸载没成功' '服务删除失败，请稍后重试；若反复失败，用「服务」管理控制台（services.msc）手动删除「小智IM 服务端」。'
        exit 3
    }
    Write-SvcLog $DataDir 'unregister：已删除'
    Show-Result '卸载完成' ("已移除 Windows 服务。`r`n`r`n聊天记录等数据不受影响，仍在：`r`n$DataDir")
    exit 0
}

# ============================================================
#  注册
# ============================================================
# 数据目录授权给 LocalSystem（SID S-1-5-18）：服务**不以当前用户身份**跑，
# 不授权的话 node 写不了数据库、日志和上传文件（启动即崩，还查不出原因）。
try {
    & icacls.exe $DataDir /grant '*S-1-5-18:(OI)(CI)F' /T /Q | Out-Null
} catch {
    Write-SvcLog $DataDir "register：icacls 授权失败（$($_.Exception.Message)）—— 继续尝试，起不来的话再排查"
}

# 已注册过：先停再删，免得 New-Service 撞名
$old = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($old) {
    if ($old.Status -eq 'Running') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Milliseconds 500
}

# 摘掉「登录后 VBS 自启」那个 Run 项：开机自启从此由服务接管。
# 不摘的后果是登录时**两个 node 抢同一个端口** —— 后起的那个 EADDRINUSE
# 直接 exit code 1，日志里看着像"服务端老是自己崩"（2026-10-14 线上症状）。
try {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'XiaozhiIMServer' -ErrorAction Stop
    Write-SvcLog $DataDir 'register：已摘除 HKCU Run 自启项（改由服务接管开机自启）'
} catch { }

# 🔴 binPath 引号必须自己带：虽然 New-Service 不过命令行解析，但 SCM 存的就是
#    这个字符串；路径带空格（Program Files、中文目录名）不引的话，
#    服务启动时 SCM 自己解析镜像路径会只认第一段 → "错误 1053/系统找不到指定的路径"。
$bin = '"' + $Node + '" "' + $AppJs + '"'
try {
    New-Service -Name $ServiceName -BinaryPathName $bin -DisplayName $ServiceDisplay `
        -StartupType Automatic -Description '小智IM 服务端：消息 / 通话 / 文件 / 管理后台' | Out-Null
} catch {
    Write-SvcLog $DataDir "register：New-Service 失败（$($_.Exception.Message)）"
    Show-Result '注册失败' "创建 Windows 服务失败：`r`n$($_.Exception.Message)"
    exit 3
}
# 崩溃自动重启（5s/10s/30s 三档）：服务没人盯着，挂了必须自己活过来
& sc.exe failure $ServiceName reset= 0 actions= restart/5000/restart/10000/restart/30000 | Out-Null

# 服务没有控制台，stdout 会进黑洞 → 让 node 自己写日志文件（filelog.js）。
# 这些值必须和前台启动同源（_env.cmd / console.ps1 各读各的），改一头记得改另一头。
$envKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Environment"
New-Item -Path $envKey -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $envKey -Name 'DATA_DIR'    -Value $DataDir    -Type String
Set-ItemProperty -Path $envKey -Name 'NODE_ENV'    -Value 'production' -Type String
Set-ItemProperty -Path $envKey -Name 'MAX_FILE_MB' -Value '50'        -Type String
Set-ItemProperty -Path $envKey -Name 'PORT'        -Value $Port.ToString() -Type String
Set-ItemProperty -Path $envKey -Name 'XZ_LOG_FILE' -Value (Join-Path $DataDir 'logs\server.log') -Type String

& sc.exe start $ServiceName | Out-Null
# sc start 是异步的：等端口真的起来再报成功
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500)) { $c.EndConnect($iar); $c.Close(); $ok = $true; break }
    } catch { }
    try { $c.Close() } catch { }
}
if (-not $ok) {
    $tail = ''
    try {
        $lf = Join-Path $DataDir 'logs\server.log'
        if (Test-Path $lf) { $tail = (Get-Content $lf -Tail 8) -join "`r`n" }
    } catch { }
    Write-SvcLog $DataDir 'register：服务起不来（端口未就绪）'
    Show-Result '注册了但没起来' "服务已创建，但 20 秒内没等到端口 $Port 就绪。`r`n`r`n日志末尾：`r`n$tail`r`n`r`n可以在「服务」里手动启动「小智IM 服务端」再试。"
    exit 4
}
Write-SvcLog $DataDir "register：成功（端口 $Port）"
Show-Result '注册成功' "小智IM 服务端已注册为 Windows 服务并启动。`r`n`r`n· 开机自启（不用先登录 Windows）`r`n· 崩溃自动重启`r`n· 注销、关窗口都不影响`r`n`r`n日常启停仍用「小智IM 服务端控制台」，用法和原来一样。"
exit 0
