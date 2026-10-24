<#
.SYNOPSIS
    初始化或重置管理员账号。

.DESCRIPTION
    两种情况：
      * 数据库还没有 admin —— 用 -Ensure 只创建，不覆盖已有密码
      * 忘了密码 —— 默认直接重置

    数据库必须可被独占访问，所以脚本会先停掉正在运行的服务，做完再启动回去。

.PARAMETER Password
    新密码。不传则自动生成 20 位强随机密码并打印。
.PARAMETER Email
    管理员邮箱，默认沿用已有的；库还没有记录时用 admin@example.com。
.PARAMETER Ensure
    只在 admin 不存在时创建，已存在则不动密码。
.PARAMETER NoRestart
    做完不自动重启服务。

.EXAMPLE
    .\deploy\reset-admin.ps1
    .\deploy\reset-admin.ps1 -Password 'MyNewPass123' -Email 'me@example.com'
#>
[CmdletBinding()]
param(
    [string]$Password = '',
    [string]$Email = '',
    [switch]$Ensure,
    [int]$Port = 59188,
    [switch]$NoRestart
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name 'reset-admin'

$serverExe = Get-ServerExe
if (-not $serverExe) {
    Write-Log '未构建服务，请先运行 deploy\build.ps1' -Level ERROR
    exit 1
}

$dbFile = Join-Path $script:Paths.Data $script:DefaultDbFile
if (-not (Test-Path $dbFile)) {
    Write-Log "数据库不存在：$dbFile" -Level ERROR
    Write-Log '首次部署请直接跑 deploy\bootstrap.ps1' -Level ERROR
    exit 1
}

# ---------------------------------------------------------------------------
# SQLite 需要独占访问，先停服务
$wasRunning = [bool](Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue)
if ($wasRunning) {
    Write-Log '服务正在运行，先停止以释放数据库...' -Level INFO
    & (Join-Path $PSScriptRoot 'stop.ps1') -Port $Port
    if ($LASTEXITCODE -ne 0) {
        Write-Log '服务停止失败，无法安全改库' -Level ERROR
        exit 1
    }
}

# ---------------------------------------------------------------------------
if (-not $Password) {
    # 与 bootstrap 用同一套字符集：避开 0/O/1/l/I 之类易混字符
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $Password = -join (1..20 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
}

# 变量名不能叫 $args：$args 是 PowerShell 自动变量（未绑定参数的收集器），
# 在某些作用域下赋值会直接抛 "Cannot overwrite variable args"。
$serverArgs = @('-db', $dbFile)
if ($Ensure) {
    $serverArgs += '-ensure-admin'
    Write-Log '模式：仅在 admin 不存在时创建' -Level INFO
} else {
    $serverArgs += '-init-admin'
    Write-Log '模式：重置 admin 密码' -Level INFO
}
$serverArgs += @('-admin-password', $Password)
if ($Email) { $serverArgs += @('-admin-email', $Email) }

$r = Invoke-External -FilePath $serverExe -Arguments $serverArgs `
    -WorkingDirectory $script:RepoRoot -FailOnError $false -Echo $true

if ($r.ExitCode -ne 0) {
    Write-Log '管理员初始化失败' -Level ERROR
    ($r.Output | Select-Object -Last 10) | ForEach-Object { Write-Log "  $_" -Level ERROR }
    exit 1
}

Write-Log '完成' -Level OK
Write-Host ''
Write-Host '  ┌────────────────────────────────────────────────────────┐' -ForegroundColor Yellow
Write-Host '  │  管理员凭据（请立即保存）                              │' -ForegroundColor Yellow
Write-Host '  ├────────────────────────────────────────────────────────┤' -ForegroundColor Yellow
Write-Host ("  │  用户名：admin                                        │") -ForegroundColor Yellow
Write-Host ("  │  密码：{0,-46}│" -f $Password) -ForegroundColor Yellow
if ($Email) {
    Write-Host ("  │  邮箱：{0,-46}│" -f $Email) -ForegroundColor Yellow
}
Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Yellow
Write-Host ''

$credFile = Join-Path $script:Paths.Data '初始管理员凭据.txt'
@"
Ydisks闲鱼助手 —— 管理员凭据
更新时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

用户名：admin
密码：  $Password
$(if ($Email) { "邮箱：  $Email" } else { '' })

请登录后立即在「系统设置」里修改密码，并删除本文件。
"@ | Set-Content -LiteralPath $credFile -Encoding UTF8
Write-Log "凭据已写入 $credFile" -Level INFO

# ---------------------------------------------------------------------------
if ($wasRunning -and -not $NoRestart) {
    Write-Log '重启服务...' -Level INFO
    & (Join-Path $PSScriptRoot 'start.ps1') -Port $Port
}
exit 0