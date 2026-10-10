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

# 内部脚本目录：后台启动服务端.vbs / 配置防火墙.cmd 都在这里。
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

# ---------------- 启停 ----------------
function Start-Server {
    if (Test-Running) { return $true }
    $vbs = Join-Path $SysDir '后台启动服务端.vbs'
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
    } else {
        # 兜底：直接起 node（等价 _hidden.cmd 的做法）
        $dataDirEnv = $DataDir
        $si = New-Object System.Diagnostics.ProcessStartInfo
        $si.FileName = $Node
        $si.Arguments = '"' + (Join-Path $App 'src\index.js') + '"'
        $si.WorkingDirectory = $Root
        $si.UseShellExecute = $false
        $si.CreateNoWindow = $true
        $si.EnvironmentVariables['PORT'] = '3602'
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
$form.Size = New-Object System.Drawing.Size(720, 620)
$form.MinimumSize = New-Object System.Drawing.Size(720, 620)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $ColorBg
$form.Font = $FontUI
$form.Icon = [System.Drawing.SystemIcons]::Application

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

# ---- 底部工具 ----
function New-ToolButton($text, $x) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 540)
    $b.Size = New-Object System.Drawing.Size(130, 30)
    $b.FlatStyle = 'Flat'
    $b.BackColor = [System.Drawing.Color]::White
    $b.ForeColor = [System.Drawing.Color]::FromArgb(74, 85, 94)
    return $b
}

$btnPwd = New-ToolButton '查看管理员密码' 16
$btnFw = New-ToolButton '配置防火墙' 152
$btnData = New-ToolButton '打开数据目录' 288
$btnRefresh = New-ToolButton '刷新状态' 424
$btnOpenLog = New-ToolButton '用记事本打开日志' 560
$form.Controls.Add($btnPwd)
$form.Controls.Add($btnFw)
$form.Controls.Add($btnData)
$form.Controls.Add($btnRefresh)
$form.Controls.Add($btnOpenLog)

# ---- 托盘 ----
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Application
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

$btnRefresh.Add_Click({ Update-Status; Update-Log })

$btnOpenLog.Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile }
    else { [System.Windows.Forms.MessageBox]::Show('还没有日志文件。', '提示', 'OK', 'Information') | Out-Null }
})

$miShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$miTrayStart.Add_Click({ Start-Server | Out-Null; Update-Status })
$miTrayStop.Add_Click({ Stop-Server | Out-Null; Update-Status })
$miTrayExit.Add_Click({ $tray.Visible = $false; $form.Close() })
$tray.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# 关窗口 = 最小化到托盘（服务不停）；真要退出走托盘右键
$script:reallyExit = $false
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
