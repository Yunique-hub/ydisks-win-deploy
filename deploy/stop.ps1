<#
.SYNOPSIS
    停止 Ydisks闲鱼助手服务。

.DESCRIPTION
    Windows 上给非服务进程发优雅停止信号没有通用做法：Stop-Process 是强杀，
    可能丢正在写的数据。这里按下面的顺序退让：

        1. 写 runtime\server.stop 触发进程内的文件监视（如果该版本支持），
           等待最多 15 秒
        2. 仍未退出则发 CloseMainWindow 请求关闭
        3. 再不行才 Stop-Process 强杀

    最后确认端口已释放。

.PARAMETER Port
    服务端口，用于确认释放，默认 59188。
.PARAMETER Quiet
    已在运行时静默返回（供其它脚本内部调用）。

.EXAMPLE
    .\deploy\stop.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 59188,
    [switch]$Quiet
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name 'stop'

$pidFile = Join-Path $script:Paths.Runtime 'server.pid'
$stopFile = Get-StopFile

# ---------------------------------------------------------------------------
$targetPid = 0
if (Test-Path $pidFile) {
    $raw = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($raw -match '^\d+$') { $targetPid = [int]$raw }
}

$proc = $null
if ($targetPid) { $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue }

# PID 文件失效时，按可执行文件名兜底找（用户可能手工启动过）
if (-not $proc) {
    $proc = Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        Write-Log "PID 文件失效，按进程名找到 xianyu-server (PID $($proc.Id))" -Level WARN
    }
}

if (-not $proc) {
    if (-not $Quiet) { Write-Log '服务未在运行' -Level INFO }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    exit 0
}

$targetPid = $proc.Id
Write-Log "停止 xianyu-server (PID $targetPid)..."

# ---------------------------------------------------------------------------
# 1) 先请求优雅退出
if (-not (Test-Path $script:Paths.Runtime)) {
    New-Item -ItemType Directory -Force -Path $script:Paths.Runtime | Out-Null
}
'stop' | Set-Content -LiteralPath $stopFile -Encoding ASCII
Write-Log '  已写入停止标记，等待优雅退出（最多 15 秒）...' -Level INFO

$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
}

# 2) 还活着就请求关闭窗口
if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
    try {
        $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
        if ($p -and $p.MainWindowHandle -ne 0) {
            Write-Log '  进程仍在，请求关闭主窗口...' -Level WARN
            $p.CloseMainWindow() | Out-Null
            Start-Sleep -Seconds 5
        }
    } catch {
        # 无窗口的进程会走到这里，忽略
    }
}

# 3) 最后强杀
if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
    Write-Log '  仍未退出，强制结束进程' -Level WARN
    Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------------------
Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue

if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
    Write-Log "进程 $targetPid 仍在运行，请手工检查" -Level ERROR
    exit 1
}

# 顺带清掉托盘进程（它挂在服务上，服务没了托盘也没意义）
$tray = Get-Process -Name 'xianyu-tray' -ErrorAction SilentlyContinue
if ($tray) {
    Write-Log "停止托盘进程 xianyu-tray (PID $($tray.Id))"
    Stop-Process -Id $tray.Id -Force -ErrorAction SilentlyContinue
}

if (Test-PortListening -Port $Port) {
    Write-Log "服务进程已退出，但端口 $Port 仍被占用（可能是 TIME_WAIT，稍等即释放）" -Level WARN
    exit 1
}

Write-Log "已停止，端口 $Port 已释放" -Level OK
exit 0