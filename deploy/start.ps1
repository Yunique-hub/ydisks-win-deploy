<#
.SYNOPSIS
    启动 Ydisks闲鱼助手服务（后台进程 + 健康检查）。

.DESCRIPTION
    以独立后台进程启动 xianyu-server.exe，并把 stdout/stderr 落到
    logs\server.log。启动后轮询 /health，确认真正可用才返回成功。

    进程信息写到 runtime\server.pid，stop.ps1 据此优雅停止。

.PARAMETER Port
    HTTP 监听端口，默认 59188。
.PARAMETER BindAddress
    监听地址。默认 127.0.0.1（仅本机可访问，最安全）。
    改为 0.0.0.0 则同网段可访问，需自行确认网络环境可信。
.PARAMETER SkipBrowser
    以 -no-browser 启动，禁用 Chromium 相关能力。
.PARAMETER Foreground
    前台运行（Ctrl+C 停止），用于排查启动问题。
.PARAMETER ResetAdmin
    顺带把管理员密码重置为 -AdminPassword 指定的值。

.EXAMPLE
    .\deploy\start.ps1
    .\deploy\start.ps1 -Port 8080 -BindAddress 0.0.0.0
#>
[CmdletBinding()]
param(
    [int]$Port = 59188,
    [string]$BindAddress = '127.0.0.1',
    [switch]$SkipBrowser,
    [switch]$Foreground
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name 'start'

$serverExe = Get-ServerExe
if (-not $serverExe) {
    Write-Log '未找到 runtime\bin\xianyu-server.exe，请先运行 deploy\build.ps1' -Level ERROR
    exit 1
}

$pidFile = Join-Path $script:Paths.Runtime 'server.pid'
$stopFile = Get-StopFile

# ---------------------------------------------------------------------------
# 已在运行就不重复启动
if (Test-Path $pidFile) {
    $oldPid = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
        $health = "http://127.0.0.1:$Port/health"
        if (Wait-HttpOk -Url $health -TimeoutSeconds 3) {
            Write-Log "服务已在运行（PID $oldPid，端口 $Port），无需重复启动" -Level OK
            exit 0
        }
        Write-Log "PID 文件指向的进程 $oldPid 还在，但健康检查不通过，先停掉它" -Level WARN
        & (Join-Path $PSScriptRoot 'stop.ps1') -Quiet
    } else {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

if (Test-PortListening -Port $Port) {
    Write-Log "端口 $Port 已被别的进程占用，请换端口或先停掉占用者" -Level ERROR
    $owner = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($owner) {
        $p = Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue
        if ($p) { Write-Log "  占用者：$($p.ProcessName) (PID $($p.Id))" -Level ERROR }
    }
    exit 1
}

# ---------------------------------------------------------------------------
foreach ($d in @($script:Paths.Data, $script:Paths.Logs, (Join-Path $script:Paths.Data 'uploads'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
# 清掉上次遗留的停止标记，否则新进程会立刻退出
Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue

$dbFile = Join-Path $script:Paths.Data $script:DefaultDbFile
$logFile = Join-Path $script:Paths.Logs 'server.log'

$serverArgs = @(
    '-addr', "${BindAddress}:$Port",
    '-db', $dbFile,
    '-workdir', $script:RepoRoot,
    '-playwright-driver-dir', $script:Paths.PwDriver,
    '-playwright-browser-dir', $script:Paths.PwBrowsers,
    '-data-key-file', (Join-Path $script:Paths.Data 'data.key')
)
if ($SkipBrowser) { $serverArgs += '-no-browser' }

Write-Log "启动：$serverExe"
Write-Log "  监听     ${BindAddress}:$Port"
Write-Log "  数据库   $dbFile"
Write-Log "  日志     $logFile"

if ($Foreground) {
    Write-Log '前台运行，Ctrl+C 停止' -Level INFO
    & $serverExe @serverArgs
    exit $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# 后台启动。这里刻意**不用** Start-Process 的重定向参数，原因是一个真实踩到的坑：
#
#   `Start-Process -RedirectStandardOutput/-RedirectStandardError` 会让子进程继承
#   调用者的 stdout/stderr 句柄。服务是长驻进程，句柄一直不释放 ——
#   于是任何「把本脚本输出重定向/管道/包一层」的调用方都会永远等不到 EOF：
#       & .\deploy\start.ps1 2>&1 | Out-String      （CI、编排器、IDE 任务包装）
#       cmd /c 启动.bat 配合某些 shell 组合
#   现象极具误导性：**服务明明起来了，脚本却像卡死**（实测挂满 120 秒不返回）。
#
#   去掉重定向后实测 2.5 秒返回。代价是服务进程的控制台输出不再落
#   server.stdout.log —— 但这不影响可观测性：服务自身有结构化日志
#   logs\server.log，验证脚本（verify.ps1 的 G 段）也是读它。
#
#   曾经试过用「一次性计划任务」真分离（schtasks /create + /run + /delete），
#   在非交互会话（无控制台句柄）下会以 0x80004015 失败，不可靠，已放弃。
$outLog = Join-Path $script:Paths.Logs 'server.stdout.log'
$errLog = Join-Path $script:Paths.Logs 'server.stderr.log'
# 先把旧 PID 文件清掉：下面要靠「PID 文件/进程名」确认新进程起来了，
# 留着旧内容会把历史 PID 当成新进程（上面的运行中分支已经处理过，这里只是收尾）。
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue

# -WindowStyle Hidden：服务在自己的隐藏窗口里跑，不弹黑框。
# $proc.Id 由 Start-Process 直接给出，无需再靠 PID 文件回读。
$proc = Start-Process -FilePath $serverExe -ArgumentList $serverArgs `
    -WorkingDirectory $script:RepoRoot -WindowStyle Hidden -PassThru
$proc.Id | Set-Content -LiteralPath $pidFile -Encoding ASCII
Write-Log "进程已拉起（PID $($proc.Id)），等待健康检查..." -Level INFO

$health = "http://127.0.0.1:$Port/health"
if (Wait-HttpOk -Url $health -TimeoutSeconds 90 -IntervalSeconds 1.5) {
    $body = ''
    try { $body = (Invoke-WebRequest -Uri $health -TimeoutSec 10 -UseBasicParsing).Content } catch { }
    Write-Log "健康检查通过：$body" -Level OK
    Write-Log "管理后台 http://127.0.0.1:$Port" -Level OK
    exit 0
}

Write-Log '健康检查超时，服务可能启动失败。日志尾部：' -Level ERROR
foreach ($f in @($errLog, $outLog)) {
    if (Test-Path $f) {
        Write-Log "--- $([System.IO.Path]::GetFileName($f)) ---" -Level ERROR
        Get-Content -LiteralPath $f -Tail 25 -Encoding UTF8 | ForEach-Object { Write-Log "  $_" -Level ERROR }
    }
}
Write-Log '' 
Write-Log '排查建议：' -Level WARN
Write-Log '  1) 用 -Foreground 前台启动，直接看报错' -Level WARN
Write-Log '  2) 端口被占用时换 -Port' -Level WARN
Write-Log '  3) 数据库损坏时删除 data\xianyu_data.db 重新初始化' -Level WARN
exit 1