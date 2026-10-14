# ============================================================
#  小智IM 服务端控制台
#
#  一个窗口管完服务端日常运维：启动 / 停止 / 重启、开机自启、
#  实时日志、打开管理后台、查看管理员密码、配置防火墙、打开数据目录。
#  取代原来散在安装目录里的一堆 .cmd（它们现在收进 _sys\ 子目录，
#  只有排障时才用得上，入口在开始菜单「高级工具」）。
#
#  技术选型：PowerShell 5.1 + WinForms。
#  为什么不用编译型 exe：客户机零依赖 —— Win10/11 自带 PowerShell 与 .NET，
#  不用带运行时、不用签名、不会有杀软误报"未知 exe"。
#  ⚠️ 安装目录里客户看到的入口是「小智IM 服务端控制台.exe」（NSIS 编的启动器），
#     它把这个脚本拉起来。别把入口又改回 .cmd —— 那是龙哥明确否掉的形态。
#
#  ⚠️ 本文件必须存成 **UTF-8 带 BOM**：PowerShell 5.1 读无 BOM 的 .ps1 时
#     按系统 ANSI(GBK) 解释，中文全变乱码。
# ============================================================

param(
    # 安装根目录，由「小智IM 服务端控制台.exe」启动器传入。
    # 本脚本收在安装根的 _sys\ 子目录里，所以不能再拿"脚本自己所在目录"当安装根。
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 安装根：优先用 exe 传来的 -AppRoot；万一有人直接跑这个 .ps1，再自己推一次。
if ([string]::IsNullOrWhiteSpace($AppRoot)) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
    # 兜底：本 .ps1 位于 _sys\ 时，上一级才是安装根（判据是 node\ 在哪一级）
    if (-not (Test-Path (Join-Path $Root 'node\node.exe'))) {
        $up = Split-Path -Parent $Root
        if (Test-Path (Join-Path $up 'node\node.exe')) { $Root = $up }
    }
} else {
    $Root = $AppRoot.TrimEnd('\')
}

$Node = Join-Path $Root 'node\node.exe'
$App  = Join-Path $Root 'app'

# ---------------- Windows 服务 ----------------
# 服务名固定（安装/卸载/状态查询都用它），显示名给用户看。
$ServiceName = 'XiaozhiIMServer'
$ServiceDisplay = '小智IM 服务端'

function Get-ServiceState {
    # not-installed / stopped / running / startpending / stoppending …
    $s = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $s) { return 'not-installed' }
    return $s.Status.ToString().ToLower()
}

function Test-ServiceMode { return (Get-ServiceState) -ne 'not-installed' }

# ⚠️ 服务**注册/卸载**的实体不在这里，在同目录的 svc_tool.ps1（提权子进程跑它）。
#    曾经放在本脚本里、由按钮提权重拉本脚本 —— 那条链在 2026-10-14 炸过：
#    装机文件因打包脚本双 BOM，首行 # 注释失效、param 块没绑上，
#    提权进程把整个 UI 又拉了起来，服务却没注册。拆成专用小脚本后，
#    "只干活不起界面"这件事不再依赖 900 行 UI 脚本的正确解析。

# 内部脚本目录：后台启动服务端.vbs / 配置防火墙.cmd / svc_tool.ps1 都在这里。
# （直接跑源码树里的 .ps1 时 _sys\ 不存在，那就退回安装根。）
$SysDir = Join-Path $Root '_sys'
if (-not (Test-Path $SysDir)) { $SysDir = $Root }

# ---------------- 数据目录 / 端口 ----------------
function Get-DataDir {
    $d = $null
    try {
        $d = (Get-ItemProperty -Path 'HKCU:\Software\小智IM服务端' -Name DataDir -ErrorAction Stop).DataDir
    } catch { $d = $null }
    if ($d -and $d.Trim()) { return $d.Trim() }
    return (Join-Path $env:LOCALAPPDATA '小智IM服务端\data')
}

$DataDir = Get-DataDir
$LogFile = Join-Path $DataDir 'logs\server.log'
$EnvFile = Join-Path $DataDir '.env'

function Get-Port {
    $p = 3602
    if (Test-Path $EnvFile) {
        foreach ($line in (Get-Content $EnvFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*PORT\s*=\s*(\d+)\s*$') { $p = [int]$Matches[1] }
        }
    }
    return $p
}

function Get-ServerVersion {
    try {
        $j = Get-Content (Join-Path $App 'package.json') -Raw | ConvertFrom-Json
        return $j.version
    } catch { return '' }
}

# ---------------- 进程状态 ----------------
# 不要用 Get-NetTCPConnection 查端口/进程：它走 CIM/WMI，本机实测单次约 3.5 秒；
# 下面的定时器每 2 秒跑一次 Update-Status，一次至少调它两次 → UI 线程被连续占死，
# 窗口表现为"卡死/假死"。改用 netstat -ano 解析（同机实测约 0.3 秒）。
function Get-ServerPid {
    $port = Get-Port
    try {
        $hit = netstat -ano -p tcp | Select-String -Pattern (':' + $port + '\s+\S+\s+LISTENING') | Select-Object -First 1
        if ($hit) {
            $tk = ($hit.Line.Trim() -split '\s+')
            $last = $tk[$tk.Count - 1]
            if ($last -match '^\d+$') { return [int]$last }
        }
    } catch { }
    return 0
}

# 快速探活：TCP 连接测试（本机实测约 18ms），不碰 WMI；用于起停时的轮询等待。
function Test-Running {
    $port = Get-Port
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(500)) { $c.EndConnect($iar); $c.Close(); return $true }
    } catch { }
    try { $c.Close() } catch { }
    return $false
}

# ---------------- 一键备份 ----------------
# NAS 上有 Docker 卷快照，Windows 上原来只能手动去拷 data 目录 —— 补上这个按钮。
# 🔴 SQLite 在 WAL 模式下直接拷 .db 会丢没 checkpoint 的写入，所以备份前
#    先停服务、备完自动起回（原本没在跑就保持不跑），保证拷出来的是干净快照。
function Backup-Data {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $desktop = [Environment]::GetFolderPath('Desktop')
    $zip = Join-Path $desktop "小智IM服务端备份-$stamp.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    $wasRunning = Test-Running
    if ($wasRunning) {
        Stop-Server | Out-Null
        Start-Sleep -Milliseconds 800
    }
    $tmp = Join-Path $env:TEMP "xz-backup-$stamp"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    # data 全拷，只排除 logs（价值低、体积大）
    Get-ChildItem -Path $DataDir -Force | Where-Object { $_.Name -ne 'logs' } | ForEach-Object {
        if ($_.PSIsContainer) {
            Copy-Item $_.FullName -Destination $tmp -Recurse -Force
        } else {
            Copy-Item $_.FullName -Destination $tmp -Force
        }
    }
    Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($wasRunning) { Start-Server | Out-Null }
    return $zip
}

# ---------------- 一键外网（免费 · Cloudflare 快速隧道）----------------
# 龙哥 2026-10-13：「Win 服务端的网络连接和 NAS 有很多不同，没有 NAS 方便」——
# 这个按钮把外网接入的门槛砍到零：连 Cloudflare 账号和域名都不用，
# cloudflared 自动下载（只下第一次，缓存在 data\tools\），起 quick tunnel
# 把本机服务转出去，地址自动抓出来给用户复制。
# ⚠️ 临时地址重启会变，适合试用/应急；正式用引导管理台 CF 向导配固定域名。
# ⚠️ cloudflared 是独立进程：控制台退出它照跑（隧道要继续服务）。
$script:cfProc = $null
function Start-QuickTunnel {
    $port = Get-Port
    if (-not (Test-Running)) {
        $r = [System.Windows.Forms.MessageBox]::Show('服务端还没启动，隧道没人可转。先启动服务端吗？', '提示', 'YesNo', 'Question')
        if ($r -eq 'Yes') { Start-Server | Out-Null }
        if (-not (Test-Running)) { return }
    }
    $toolsDir = Join-Path $DataDir 'tools'
    if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null }
    $cf = Join-Path $toolsDir 'cloudflared.exe'
    if (-not (Test-Path $cf)) {
        $r = [System.Windows.Forms.MessageBox]::Show('首次使用要从 GitHub 下载 cloudflared.exe（约 30MB，国内可能偏慢，只下一次）。现在下载吗？', '下载 cloudflared', 'YesNo', 'Question')
        if ($r -ne 'Yes') { return }
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $cf -UseBasicParsing
        } catch {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            [System.Windows.Forms.MessageBox]::Show("下载失败：$($_.Exception.Message)`n也可以自己下载 cloudflared.exe 放到这个目录再试：$toolsDir", '下载失败', 'OK', 'Error')
            return
        }
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    # 清掉上一次可能残留的 quick tunnel（同路径的才算，别误杀别人的 cloudflared）
    Get-Process cloudflared -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $cf } | Stop-Process -Force -ErrorAction SilentlyContinue
    $out = Join-Path $env:TEMP 'xz-cloudflared.log'
    if (Test-Path $out) { Remove-Item $out -Force }
    try {
        $script:cfProc = Start-Process -FilePath $cf -ArgumentList @('tunnel', '--url', "http://127.0.0.1:$port", '--no-autoupdate') -RedirectStandardOutput $out -RedirectStandardError $out -PassThru -WindowStyle Hidden
    } catch {
        [System.Windows.Forms.MessageBox]::Show("启动 cloudflared 失败：$($_.Exception.Message)", '未成功', 'OK', 'Error')
        return
    }
    # 轮询日志抓 trycloudflare.com 地址（最多 40 秒）
    $url = $null
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 500
        if ($script:cfProc -and $script:cfProc.HasExited) { break }
        if (Test-Path $out) {
            $m = Select-String -Path $out -Pattern '(https://[a-z0-9-]+\.trycloudflare\.com)' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Groups[1].Value; break }
        }
    }
    if (-not $url) {
        [System.Windows.Forms.MessageBox]::Show('没拿到外网地址（可能网络连不上 cloudflare）。`n诊断日志：' + $out, '未成功', 'OK', 'Warning')
        return
    }
    $msg = "外网地址已就绪（免费，不用账号不用域名）：`n`n$url`n`n点「是」复制地址；然后粘到管理台「部署向导 → Cloudflare Tunnel」第 5 步，写入客户端地址候选即可。`n注意：这是临时地址，cloudflared 重启会变；长期用请按向导配固定域名。"
    $r = [System.Windows.Forms.MessageBox]::Show($msg, '一键外网（免费）', 'YesNo', 'Information')
    try { Set-Clipboard -Value $url } catch { }
    Start-Process "http://127.0.0.1:$port/admin/"
}

# ---------------- 启停 ----------------
# 服务模式下（注册过 Windows 服务）启停走 Start/Stop-Service ——
# 用户看到的按钮和行为完全一样，不用关心背后是服务还是用户进程。
function Start-Server {
    if (Test-Running) { return $true }
    if (Test-ServiceMode) {
        try { Start-Service -Name $ServiceName -ErrorAction SilentlyContinue } catch { }
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 500
            if (Test-Running) { return $true }
        }
        return $false
    }
    $vbs = Join-Path $SysDir '后台启动服务端.vbs'
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
    } else {
        # 兜底：直接起 node（等价 _hidden.cmd 的做法）
        # 🔴 端口必须跟 _env.cmd 同源（.env 的 PORT）—— 写死 3602 的话，
        #    改过端口的机器走兜底会起在错误端口上。
        $dataDirEnv = $DataDir
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $Node
        $si.Arguments = '"' + (Join-Path $App 'src\index.js') + '"'
        $si.WorkingDirectory = $Root
        $si.UseShellExecute = $false
        $si.CreateNoWindow = $true
        $si.EnvironmentVariables['PORT'] = (Get-Port).ToString()
        $si.EnvironmentVariables['NODE_ENV'] = 'production'
        $si.EnvironmentVariables['DATA_DIR'] = $dataDirEnv
        $si.EnvironmentVariables['MAX_FILE_MB'] = '50'
        [System.Diagnostics.Process]::Start($si) | Out-Null
    }
    # 等端口起来（最多 20 秒）
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Running) { return $true }
    }
    return $false
}

function Stop-Server {
    $pid2 = Get-ServerPid
    if ($pid2 -le 0) { return $true }
    if (Test-ServiceMode) {
        try { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } catch { }
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 300
            if (-not (Test-Running)) { return $true }
        }
        return $false
    }
    try { Stop-Process -Id $pid2 -Force -ErrorAction Stop } catch { }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 300
        if (-not (Test-Running)) { return $true }
    }
    return $false
}

# ---------------- 开机自启 ----------------
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Test-Autostart {
    $v = $null
    try { $v = (Get-ItemProperty -Path $RunKey -Name 'XiaozhiIMServer' -ErrorAction Stop).XiaozhiIMServer } catch { $v = $null }
    return [bool]$v
}

function Set-Autostart([bool]$on) {
    if ($on) {
        $vbs = Join-Path $SysDir '后台启动服务端.vbs'
        $val = 'wscript.exe "' + $vbs + '"'
        New-ItemProperty -Path $RunKey -Name 'XiaozhiIMServer' -Value $val -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $RunKey -Name 'XiaozhiIMServer' -ErrorAction SilentlyContinue
    }
}

# ============================================================
#  界面
# ============================================================
$FontUI = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$FontBig = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$FontLog = New-Object System.Drawing.Font('Consolas', 9)
$ColorBrand = [System.Drawing.Color]::FromArgb(16, 185, 129)
$ColorDark = [System.Drawing.Color]::FromArgb(31, 42, 51)
$ColorWeak = [System.Drawing.Color]::FromArgb(123, 135, 144)
$ColorBg = [System.Drawing.Color]::FromArgb(244, 246, 247)

$form = New-Object System.Windows.Forms.Form
$form.Text = '小智IM 服务端控制台'
$form.Size = New-Object System.Drawing.Size(720, 668)
$form.MinimumSize = New-Object System.Drawing.Size(720, 668)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $ColorBg
$form.Font = $FontUI

# 真图标：任务栏、窗口标题栏、托盘都用它。
# 为什么不能图省事用 SystemIcons：托盘里一个"通用应用"样子的图标，
# 用户根本注意不到 —— "关掉窗口找不着软件"一半是这么来的。
$IcoFile = Join-Path $Root 'console.ico'
$AppIcon = [System.Drawing.SystemIcons]::Application
if (Test-Path $IcoFile) {
    try { $AppIcon = New-Object System.Drawing.Icon($IcoFile) } catch { }
}
$form.Icon = $AppIcon

# ---- 状态卡 ----
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(16, 14)
$statusPanel.Size = New-Object System.Drawing.Size(672, 66)
$statusPanel.BackColor = [System.Drawing.Color]::White

$lamp = New-Object System.Windows.Forms.Label
$lamp.Text = [char]0x25CF   # ●
$lamp.Font = New-Object System.Drawing.Font('Segoe UI', 20)
$lamp.ForeColor = [System.Drawing.Color]::FromArgb(160, 170, 176)
$lamp.Location = New-Object System.Drawing.Point(14, 12)
$lamp.Size = New-Object System.Drawing.Size(34, 40)
$statusPanel.Controls.Add($lamp)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = '正在检测…'
$lblState.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$lblState.Location = New-Object System.Drawing.Point(52, 12)
$lblState.Size = New-Object System.Drawing.Size(180, 24)
$statusPanel.Controls.Add($lblState)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = ''
$lblInfo.ForeColor = $ColorWeak
$lblInfo.Location = New-Object System.Drawing.Point(52, 38)
$lblInfo.Size = New-Object System.Drawing.Size(600, 20)
$statusPanel.Controls.Add($lblInfo)

$form.Controls.Add($statusPanel)

# ---- 主按钮 ----
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '启动服务端'
$btnStart.Location = New-Object System.Drawing.Point(16, 92)
$btnStart.Size = New-Object System.Drawing.Size(160, 42)
$btnStart.FlatStyle = 'Flat'
$btnStart.BackColor = $ColorBrand
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatAppearance.BorderSize = 0
$btnStart.Font = $FontBig
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '停止服务端'
$btnStop.Location = New-Object System.Drawing.Point(186, 92)
$btnStop.Size = New-Object System.Drawing.Size(160, 42)
$btnStop.FlatStyle = 'Flat'
$btnStop.BackColor = [System.Drawing.Color]::White
$btnStop.ForeColor = [System.Drawing.Color]::FromArgb(179, 70, 47)
$btnStop.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(236, 207, 198)
$form.Controls.Add($btnStop)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = '重启服务端'
$btnRestart.Location = New-Object System.Drawing.Point(356, 92)
$btnRestart.Size = New-Object System.Drawing.Size(160, 42)
$btnRestart.FlatStyle = 'Flat'
$btnRestart.BackColor = [System.Drawing.Color]::White
$btnRestart.ForeColor = [System.Drawing.Color]::FromArgb(74, 85, 94)
$form.Controls.Add($btnRestart)

$btnAdmin = New-Object System.Windows.Forms.Button
$btnAdmin.Text = '打开管理后台'
$btnAdmin.Location = New-Object System.Drawing.Point(526, 92)
$btnAdmin.Size = New-Object System.Drawing.Size(162, 42)
$btnAdmin.FlatStyle = 'Flat'
$btnAdmin.BackColor = [System.Drawing.Color]::White
$btnAdmin.ForeColor = [System.Drawing.Color]::FromArgb(13, 122, 86)
$form.Controls.Add($btnAdmin)

# ---- 自启开关 ----
$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = '开机自动启动（登录 Windows 后自动在后台运行）'
$chkAuto.Location = New-Object System.Drawing.Point(20, 146)
$chkAuto.Size = New-Object System.Drawing.Size(400, 24)
$form.Controls.Add($chkAuto)

# ---- 日志区 ----
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '运行日志（自动刷新，最新 300 行）'
$lblLog.ForeColor = $ColorWeak
$lblLog.Location = New-Object System.Drawing.Point(18, 178)
$lblLog.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(16, 200)
$txtLog.Size = New-Object System.Drawing.Size(672, 330)
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.WordWrap = $false
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(20, 27, 32)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(159, 216, 185)
$txtLog.Font = $FontLog
$txtLog.BorderStyle = 'FixedSingle'
$form.Controls.Add($txtLog)

# ---- 底部工具（三行：运维 / 数据 / 服务）----
function New-ToolButton($text, $x, $y) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size(130, 30)
    $b.FlatStyle = 'Flat'
    $b.BackColor = [System.Drawing.Color]::White
    $b.ForeColor = [System.Drawing.Color]::FromArgb(74, 85, 94)
    return $b
}

# 第一行：日常运维
$btnPwd = New-ToolButton '查看管理员密码' 16 540
$btnFw = New-ToolButton '配置防火墙' 152 540
$btnData = New-ToolButton '打开数据目录' 288 540
# 第二行：数据 / 外网 / 刷新
$btnBackup = New-ToolButton '一键备份数据' 16 576
$btnTunnel = New-ToolButton '一键外网(免费)' 152 576
$btnRefresh = New-ToolButton '刷新状态' 288 576
# 第三行：Windows 服务（龙哥 2026-10-14：要能以服务进程跑、开机自启不用登录）
$btnSvcReg = New-ToolButton '注册为服务' 16 612
$btnSvcUnreg = New-ToolButton '卸载服务' 152 612
$btnOpenLog = New-ToolButton '用记事本打开日志' 288 612
$form.Controls.Add($btnPwd)
$form.Controls.Add($btnFw)
$form.Controls.Add($btnData)
$form.Controls.Add($btnBackup)
$form.Controls.Add($btnTunnel)
$form.Controls.Add($btnRefresh)
$form.Controls.Add($btnSvcReg)
$form.Controls.Add($btnSvcUnreg)
$form.Controls.Add($btnOpenLog)

# 服务状态标签（紧跟第三行按钮，一眼能看到当前是不是服务模式）
$lblSvc = New-Object System.Windows.Forms.Label
$lblSvc.Text = 'Windows 服务：检测中…'
$lblSvc.ForeColor = $ColorWeak
$lblSvc.Location = New-Object System.Drawing.Point(424, 618)
$lblSvc.Size = New-Object System.Drawing.Size(264, 20)
$lblSvc.TextAlign = 'MiddleLeft'
$form.Controls.Add($lblSvc)

# ---- 托盘 ----
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $AppIcon
$tray.Text = '小智IM 服务端控制台'
$tray.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('打开控制台')
$miTrayStart = $trayMenu.Items.Add('启动服务端')
$miTrayStop = $trayMenu.Items.Add('停止服务端')
$miTrayExit = $trayMenu.Items.Add('退出（服务继续运行）')
$tray.ContextMenuStrip = $trayMenu

# ============================================================
#  逻辑
# ============================================================
$script:startedAt = $null

function Update-Status {
    $port = Get-Port
    $pidNow = Get-ServerPid          # 只查一次（netstat ~0.3s），不要重复调用
    $running = ($pidNow -gt 0)
    if ($running) {
        $lamp.ForeColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
        $lblState.Text = '运行中'
        $mem = ''
        try {
            $proc = Get-Process -Id $pidNow -ErrorAction Stop
            $mem = ' · 内存 ' + [math]::Round($proc.WorkingSet64 / 1MB) + ' MB'
        } catch { }
        $lblInfo.Text = '端口 ' + $port + ' · 进程 ' + $pidNow + $mem + ' · 数据目录 ' + $DataDir
    } else {
        $lamp.ForeColor = [System.Drawing.Color]::FromArgb(200, 80, 70)
        $lblState.Text = '已停止'
        $lblInfo.Text = '端口 ' + $port + ' · 数据目录 ' + $DataDir
    }
    $ver = Get-ServerVersion
    $form.Text = '小智IM 服务端控制台' + $(if ($ver) { '  v' + $ver } else { '' })

    # ---- Windows 服务状态（随 2 秒定时器刷；Get-Service 是本地查询，~10ms 级）----
    $svc = Get-ServiceState
    if ($svc -eq 'not-installed') {
        $lblSvc.Text = 'Windows 服务：未注册（用户进程方式）'
        $lblSvc.ForeColor = $ColorWeak
        $btnSvcReg.Enabled = $true
        $btnSvcUnreg.Enabled = $false
        $chkAuto.Enabled = $true
    } else {
        $svcCn = switch ($svc) {
            'running' { '运行中' }
            'stopped' { '已停止' }
            default { $svc }
        }
        $lblSvc.Text = "Windows 服务：$svcCn（自启由服务接管）"
        $lblSvc.ForeColor = $(if ($svc -eq 'running') {
            [System.Drawing.Color]::FromArgb(22, 163, 74) } else { $ColorWeak })
        $btnSvcReg.Enabled = $false
        $btnSvcUnreg.Enabled = $true
        # 服务模式下开机自启由服务 start=auto 接管，复选框只作展示（禁点）
        $chkAuto.Enabled = $false
        $chkAuto.Checked = $true
    }
    # 托盘悬停提示带运行状态（不用点开就知道服务活着没）
    $tray.Text = '小智IM 服务端 · ' + $(if ($pidNow -gt 0) { '运行中' } else { '已停止' })
}

$script:lastLogText = ''
function Update-Log {
    if (-not (Test-Path $LogFile)) {
        $txtLog.Text = '（还没有日志文件：' + $LogFile + '）'
        return
    }
    $lines = Get-Content $LogFile -Tail 300 -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return }
    $text = ($lines -join "`r`n")
    if ($text -ne $script:lastLogText) {
        $script:lastLogText = $text
        $selStart = $txtLog.SelectionStart
        $txtLog.Text = $text
        # 自动滚到底部（只在用户没在选中文本时）
        if ($selStart -eq 0) {
            $txtLog.SelectionStart = $txtLog.TextLength
            $txtLog.ScrollToCaret()
        }
    }
}

function Set-Busy([bool]$busy, [string]$what) {
    $form.Cursor = $(if ($busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default })
    $btnStart.Enabled = -not $busy
    $btnStop.Enabled = -not $busy
    $btnRestart.Enabled = -not $busy
    if ($busy) {
        $lblState.Text = $what
        $lamp.ForeColor = [System.Drawing.Color]::FromArgb(230, 162, 60)
    }
    [System.Windows.Forms.Application]::DoEvents()
}

$btnStart.Add_Click({
    Set-Busy $true '正在启动…'
    $ok = Start-Server
    Set-Busy $false ''
    Update-Status
    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show(
            "服务端没能启动。`r`n`r`n请点「用记事本打开日志」看最后几行报错；`r`n常见原因：端口被占用、数据目录没有写入权限。",
            '启动失败', 'OK', 'Warning') | Out-Null
    }
})

$btnStop.Add_Click({
    Set-Busy $true '正在停止…'
    $ok = Stop-Server
    Set-Busy $false ''
    Update-Status
    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show('停止失败：进程可能被其他程序保护。可尝试右键「以小管理员身份运行」控制台。', '停止失败', 'OK', 'Warning') | Out-Null
    }
})

$btnRestart.Add_Click({
    Set-Busy $true '正在重启…'
    Stop-Server | Out-Null
    Start-Sleep -Milliseconds 1200
    $ok = Start-Server
    Set-Busy $false ''
    Update-Status
    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show('重启后服务端没能起来，请看日志最后几行。', '重启失败', 'OK', 'Warning') | Out-Null
    }
})

$btnAdmin.Add_Click({
    Start-Process ('http://127.0.0.1:' + (Get-Port) + '/admin')
})

$chkAuto.Add_Click({
    Set-Autostart ([bool]$chkAuto.Checked)
    Update-Status
})

$btnPwd.Add_Click({
    $pwd = ''
    if (Test-Path $EnvFile) {
        foreach ($line in (Get-Content $EnvFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*ADMIN_PASSWORD\s*=\s*(.+?)\s*$') { $pwd = $Matches[1] }
        }
    }
    $msg = "管理账号：admin`r`n`r`n"
    if ($pwd) {
        $msg += "初始密码：$pwd`r`n`r`n"
    } else {
        $msg += "初始密码：未在 .env 里找到（可能已被清掉）`r`n第一次启动时日志里有；也可以在管理台重置。`r`n`r`n"
    }
    $msg += "说明：这个口令只在服务端首次建库时用来创建 admin 账号。`r`n如果已经在管理台改过密码，这里显示的是当初那个初始值，用它登录会失败。`r`n改密码：管理台 →「系统设置」。`r`n`r`n配置文件：$EnvFile"
    [System.Windows.Forms.MessageBox]::Show($msg, '管理账号与初始密码', 'OK', 'Information') | Out-Null
})

$btnFw.Add_Click({
    $cmd = Join-Path $SysDir '配置防火墙.cmd'
    if (-not (Test-Path $cmd)) {
        [System.Windows.Forms.MessageBox]::Show('找不到 配置防火墙.cmd（可能被删了）', '提示', 'OK', 'Warning') | Out-Null
        return
    }
    # 防火墙规则需要管理员权限：提权开一个新窗口跑，本控制台不需要整体提权
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c "' + $cmd + '"') -Verb RunAs
    } catch {
        [System.Windows.Forms.MessageBox]::Show('提权被取消或失败。请改用：开始菜单 → 高级工具 → 配置防火墙（需管理员）', '提示', 'OK', 'Warning') | Out-Null
    }
})

$btnData.Add_Click({
    if (Test-Path $DataDir) { Start-Process explorer.exe $DataDir }
    else { [System.Windows.Forms.MessageBox]::Show('数据目录还不存在：' + $DataDir, '提示', 'OK', 'Warning') | Out-Null }
})

$btnBackup.Add_Click({
    try {
        $zip = Backup-Data
        [System.Windows.Forms.MessageBox]::Show("备份完成：`n$zip`n（数据库 / 上传文件 / 配置都在里面，不含日志）", '备份完成', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("备份失败：$($_.Exception.Message)", '备份失败', 'OK', 'Error') | Out-Null
    }
})

$btnTunnel.Add_Click({ Start-QuickTunnel })

$btnRefresh.Add_Click({ Update-Status; Update-Log })

$btnOpenLog.Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile }
    else { [System.Windows.Forms.MessageBox]::Show('还没有日志文件。', '提示', 'OK', 'Information') | Out-Null }
})

# ---- Windows 服务：注册 / 卸载（提权干活，界面不整体提权）----
# 为什么走 Start-Process -Verb RunAs 再拉一个**专用小脚本**：注册要写 HKLM、
# 改数据目录 ACL，必须管理员；而日常用控制台不该被 UAC 烦。所以只在这两个
# 按钮上提权，弹一次 UAC，干完自动退出，结果由那个脚本自己弹框报给用户。
#
# 🔴🔴 参数必须拼成**一条带引号的字符串**再传给 -ArgumentList，不能用数组：
#     数组形式会被 Start-Process 用空格**无引号**拼接，路径里一带空格
#     （C:\Program Files\小智IM服务端\...）就断成两截，提权进程收到一个
#     残缺的 -File 路径 → 2026-10-14 线上就是这么裂的。
function Invoke-SvcTool {
    param([string]$Act)
    $tool = Join-Path $SysDir 'svc_tool.ps1'
    if (-not (Test-Path $tool)) {
        [System.Windows.Forms.MessageBox]::Show(
            "找不到服务工具脚本：`r`n$tool`r`n`r`n请重新安装服务端。", '无法操作', 'OK', 'Warning') | Out-Null
        return
    }
    # 每个参数值都自带一对双引号 —— 这是唯一稳的写法
    $argline = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden' +
               ' -File "' + $tool + '"' +
               ' -Action ' + $Act +
               ' -AppRoot "' + $Root + '"' +
               ' -DataDir "' + $DataDir + '"' +
               ' -Port ' + (Get-Port).ToString()
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argline
    } catch {
        [System.Windows.Forms.MessageBox]::Show("提权失败：$($_.Exception.Message)", '未成功', 'OK', 'Warning') | Out-Null
    }
}

$btnSvcReg.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "把小智IM 服务端注册为 Windows 服务：`r`n`r`n· 开机自启 —— 不用先登录 Windows`r`n· 崩溃自动重启（5 / 10 / 30 秒三档）`r`n· 以系统服务运行，注销、关窗口都不影响`r`n`r`n接下来会弹 UAC（需要管理员权限）。`r`n注册后日常启停仍在本控制台操作，用法和现在一样。`r`n`r`n数据目录：$DataDir",
        '注册为 Windows 服务', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-SvcTool 'Register'
})

$btnSvcUnreg.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show(
        "卸载 Windows 服务（会先停止服务）。`r`n`r`n之后服务端回到「用户进程」方式：用本控制台启动，`r`n或开始菜单 → 高级工具 → 后台启动服务端。`r`n聊天记录等数据不受影响。`r`n`r`n接下来会弹 UAC（需要管理员权限）。",
        '卸载 Windows 服务', 'YesNo', 'Question')
    if ($r -ne 'Yes') { return }
    Invoke-SvcTool 'Unregister'
})

$miShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$miTrayStart.Add_Click({ Start-Server | Out-Null; Update-Status })
$miTrayStop.Add_Click({ Stop-Server | Out-Null; Update-Status })
$miTrayExit.Add_Click({ $tray.Visible = $false; $form.Close() })
$tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# 关窗口 = 最小化到托盘（服务不停）；真要退出走托盘右键
$script:reallyExit = $false

# 最小化按钮同样进托盘（龙哥 2026-10-14：两个窗口没法最小化到消息栏）——
# 任务栏上留一个图标不如收进托盘，鼠标悬停还能看到运行状态。
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
        $tray.ShowBalloonTip(1500, '小智IM 服务端控制台',
            '已最小化到托盘，服务继续运行。双击托盘图标可恢复。', 'Info')
    }
})

$form.Add_FormClosing({
    param($sender, $e)
    if (-not $script:reallyExit) {
        $e.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(2000, '小智IM 服务端控制台', '已最小化到托盘，服务继续运行。右键托盘图标可再次打开。', 'Info')
    }
})

# 定时刷新
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({ Update-Status; Update-Log })
$timer.Start()

$form.Add_Shown({
    $chkAuto.Checked = Test-Autostart
    Update-Status
    Update-Log
})

[void][System.Windows.Forms.Application]::Run($form)
$tray.Visible = $false
$script:reallyExit = $true
