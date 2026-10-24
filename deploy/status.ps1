<#
.SYNOPSIS
    查看 Ydisks闲鱼助手运行状态。

.DESCRIPTION
    一次性显示：进程、端口、健康检查、版本、数据库、数据目录体积、
    Chromium 运行时、日志位置。排查问题时先跑这个。

.PARAMETER Port
    服务端口，默认 59188。
.PARAMETER Json
    以 JSON 输出（供其它脚本消费）。

.EXAMPLE
    .\deploy\status.ps1
    .\deploy\status.ps1 -Json
#>
[CmdletBinding()]
param(
    [int]$Port = 59188,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')

$result = [ordered]@{
    Running      = $false
    Pid          = $null
    Port         = $Port
    Healthy      = $false
    HealthBody   = ''
    Version      = ''
    Database     = ''
    DatabaseSizeMb = 0
    DataSizeMb   = 0
    ChromiumReady = $false
    Uptime       = ''
    Url          = "http://127.0.0.1:$Port"
}

# ---------------------------------------------------------------------------
# 进程
$pidFile = Join-Path $script:Paths.Runtime 'server.pid'
$proc = $null
if (Test-Path $pidFile) {
    $raw = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($raw -match '^\d+$') { $proc = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue }
}
if (-not $proc) {
    $proc = Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($proc) {
    $result.Running = $true
    $result.Pid = $proc.Id
    try {
        $span = (Get-Date) - $proc.StartTime
        $result.Uptime = if ($span.TotalHours -ge 1) {
            "{0:N1} 小时" -f $span.TotalHours
        } else {
            "{0:N0} 分钟" -f $span.TotalMinutes
        }
    } catch {
        $result.Uptime = '未知'
    }
}

# ---------------------------------------------------------------------------
# 端口
$result.PortListening = Test-PortListening -Port $Port

# ---------------------------------------------------------------------------
# 健康检查
if ($result.PortListening) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 10 -UseBasicParsing
        if ($resp.StatusCode -eq 200) {
            $result.Healthy = $true
            $result.HealthBody = $resp.Content
        }
    } catch {
        $result.HealthBody = "请求失败：$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 版本与数据库
$serverExe = Get-ServerExe
if ($serverExe) {
    try {
        $vOut = & $serverExe -version 2>&1
        $result.Version = ($vOut | Select-Object -First 1)
    } catch {
        $result.Version = '读取失败'
    }
}

$dbFile = Join-Path $script:Paths.Data $script:DefaultDbFile
if (Test-Path $dbFile) {
    $result.Database = $dbFile
    $result.DatabaseSizeMb = [math]::Round((Get-Item $dbFile).Length / 1MB, 2)
}
if (Test-Path $script:Paths.Data) {
    $result.DataSizeMb = [math]::Round(
        (Get-ChildItem $script:Paths.Data -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum / 1MB, 1)
}

# ---------------------------------------------------------------------------
# Chromium 运行时
$browserFiles = Get-ChildItem $script:Paths.PwBrowsers -Recurse -File -ErrorAction SilentlyContinue
$result.ChromiumReady = [bool]($browserFiles -and $browserFiles.Count -gt 50)
$result.ChromiumSizeMb = [math]::Round(($browserFiles | Measure-Object Length -Sum).Sum / 1MB, 1)

# ---------------------------------------------------------------------------
if ($Json) {
    $result | ConvertTo-Json -Depth 4
    exit 0
}

# ---------------------------------------------------------------------------
function Write-Row {
    param([string]$Label, [string]$Value, [string]$Color = 'White')
    Write-Host ("  {0,-14}" -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

Write-Host ''
Write-Host '  Ydisks闲鱼助手 · 运行状态' -ForegroundColor White
Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkGray

if ($result.Running) {
    Write-Row '服务进程' "运行中（PID $($result.Pid)）" 'Green'
    Write-Row '运行时长' $result.Uptime
} else {
    Write-Row '服务进程' '未运行' 'Red'
}

if ($result.PortListening) {
    Write-Row '监听端口' "$Port 已监听" 'Green'
} else {
    Write-Row '监听端口' "$Port 未监听" 'Red'
}

# 注意：(if (...) {...} else {...}) 这种「内联 if 表达式」只有 PowerShell 7 支持，
# 5.1 会把它当成命令名去调用，报 "The term 'if' is not recognized"。
# 要用必须先落到变量里（或写成 $(if ...) 子表达式）。
$healthText = if ($result.HealthBody) { $result.HealthBody } else { '不可用' }
if ($result.Healthy) {
    Write-Row '健康检查' '通过' 'Green'
} else {
    Write-Row '健康检查' $healthText 'Red'
}

if ($result.Version) { Write-Row '版本'   $result.Version }
if ($result.Database) {
    Write-Row '数据库' "$($result.Database)（$($result.DatabaseSizeMb) MB）"
} else {
    Write-Row '数据库' '尚未创建（先运行 bootstrap 或 start）' 'Yellow'
}
Write-Row '数据体积' "$($result.DataSizeMb) MB"

if ($result.ChromiumReady) {
    Write-Row 'Chromium' "就绪（$($result.ChromiumSizeMb) MB）" 'Green'
} else {
    Write-Row 'Chromium' '未安装（浏览器相关能力不可用）' 'Yellow'
}

Write-Host ('  ' + ('─' * 58)) -ForegroundColor DarkGray
if ($result.Healthy) {
    Write-Host "  管理后台  $($result.Url)" -ForegroundColor Cyan
} else {
    Write-Host "  启动服务  .\deploy\start.ps1" -ForegroundColor DarkGray
}
Write-Host "  服务日志  $($script:Paths.Logs)\server.stdout.log" -ForegroundColor DarkGray
Write-Host ''

if ($result.Healthy) { exit 0 } else { exit 1 }