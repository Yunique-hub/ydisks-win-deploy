# 公共层（deploy/common.ps1）单元自测
#
# 覆盖那些「不测就会静默出错」的纯函数：
#   * ConvertTo-ArgumentString —— Windows 命令行参数引号规则
#   * Resolve-ExternalPath    —— npm.ps1 → npm.cmd 的解析
#   * Test-PortListening / Get-SystemProxy 等环境探测的健壮性
#
# 这些函数的失败模式都是「不报错但结果不对」，所以必须有断言。
#
# 用法：.\tests\test_common_selftest.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy\common.ps1')

$failures = New-Object System.Collections.Generic.List[string]
$total = 0

function Assert-Equal {
    <#
    .SYNOPSIS
        断言两个值相等。
    .PARAMETER Expected
        期望值。
    .PARAMETER Actual
        实际值。
    .PARAMETER Label
        用例名称。
    #>
    # AllowEmptyString：有用例专门断言「空参数」的行为，Mandatory 默认会拒绝空串
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory)][string]$Label
    )
    $script:total++
    if ($Expected -ceq $Actual) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        Write-Host "         期望：$Expected" -ForegroundColor DarkGray
        Write-Host "         实际：$Actual" -ForegroundColor DarkGray
        $script:failures.Add($Label)
    }
}

function Assert-True {
    <#
    .SYNOPSIS
        断言条件为真。
    .PARAMETER Condition
        条件。
    .PARAMETER Label
        用例名称。
    #>
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Label)
    $script:total++
    if ($Condition) {
        Write-Host "  [PASS] $Label" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $Label" -ForegroundColor Red
        $script:failures.Add($Label)
    }
}

Write-Host ''
Write-Host '  Ydisks闲鱼助手 · 公共层自测' -ForegroundColor White
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  ConvertTo-ArgumentString（Windows 命令行引号规则）' -ForegroundColor Cyan

# 含空格的参数必须加引号。
# 不加的话 `-ldflags "-s -w"` 会被拆成两个参数，go build 报
# "flag provided but not defined: -w" —— 这是实测踩过的坑。
Assert-Equal `
    -Expected 'build -trimpath -ldflags "-s -w -X main.commit=abc" -o out.exe ./cmd/server' `
    -Actual (ConvertTo-ArgumentString -Arguments @('build', '-trimpath', '-ldflags', '-s -w -X main.commit=abc', '-o', 'out.exe', './cmd/server')) `
    -Label '含空格的 -ldflags 被整体加引号'

# 无空格的参数不应被加引号（避免多余的引号进入程序看到的 argv）
Assert-Equal `
    -Expected '-driver-dir E:\plain\dir -browser-dir E:\plain\b' `
    -Actual (ConvertTo-ArgumentString -Arguments @('-driver-dir', 'E:\plain\dir', '-browser-dir', 'E:\plain\b')) `
    -Label '无空格参数不加引号'

# 内嵌双引号要转义
Assert-Equal `
    -Expected '-x "a\"b"' `
    -Actual (ConvertTo-ArgumentString -Arguments @('-x', 'a"b')) `
    -Label '内嵌双引号被转义'

# 含空格且以反斜杠结尾：末尾反斜杠要翻倍，否则会被当成引号前的转义
Assert-Equal `
    -Expected '-y "C:\dir with space\\"' `
    -Actual (ConvertTo-ArgumentString -Arguments @('-y', 'C:\dir with space\')) `
    -Label '末尾反斜杠 + 空格正确转义'

# 空参数要变成 ""
Assert-Equal -Expected '-z ""' -Actual (ConvertTo-ArgumentString -Arguments @('-z', '')) -Label '空参数变成 ""'

# 空数组
Assert-Equal -Expected '' -Actual (ConvertTo-ArgumentString -Arguments @()) -Label '空参数数组返回空串'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  Resolve-ExternalPath（npm.ps1 → npm.cmd）' -ForegroundColor Cyan

# Windows 上 npm 在 PATH 里是 npm.ps1，Start-Process 无法执行 .ps1。
# 解析结果必须是 .exe / .cmd / .bat，不能是 .ps1。
foreach ($tool in @('npm', 'node', 'git')) {
    try {
        $resolved = Resolve-ExternalPath -Name $tool
        $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
        Assert-True -Condition ($ext -in @('.exe', '.cmd', '.bat')) `
            -Label ("$tool 解析为可执行文件：" + $resolved)
    } catch {
        Assert-True -Condition $false -Label "$tool 解析（异常：$($_.Exception.Message)）"
    }
}

# 具体验证 npm 不是 .ps1 —— 这是那个坑的核心
try {
    $npmPath = Resolve-ExternalPath -Name 'npm'
    Assert-True -Condition ($npmPath -notlike '*.ps1') -Label ("npm 未解析成 .ps1：" + $npmPath)
} catch {
    Write-Host "  [SKIP] npm 解析（环境里没有 npm）：$($_.Exception.Message)" -ForegroundColor Yellow
}

# 不存在的命令要抛错，而不是静默返回空串
$threw = $false
try { Resolve-ExternalPath -Name 'definitely-not-a-real-command-xyz' | Out-Null } catch { $threw = $true }
Assert-True -Condition $threw -Label '不存在的命令会抛错'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  环境探测函数' -ForegroundColor Cyan

# 端口探测：监听的端口返回真，未监听的返回假
Assert-True -Condition (-not (Test-PortListening -Port 1)) -Label '未监听端口返回假'

# Get-SystemProxy 要么返回空串，要么返回带协议的 URL（不能抛错）
$proxy = Get-SystemProxy
Assert-True -Condition ($proxy -eq '' -or $proxy -match '^https?://') `
    -Label ("Get-SystemProxy 返回值合法：" + $proxy)

# Get-StopFile 必须指向 runtime 目录下
$stopFile = Get-StopFile
Assert-True -Condition ($stopFile -like "*runtime*server.stop*") `
    -Label ("停止标记位于 runtime 下：" + $stopFile)

# Get-GoExe：装了返回路径，没装返回 $null（不能抛错）
$goExe = Get-GoExe
Assert-True -Condition ($null -eq $goExe -or $goExe -like '*go.exe') `
    -Label ("Get-GoExe 返回合法：" + $(if ($goExe) { $goExe } else { '未安装' }))

# Get-ServerExe 同理
$serverExe = Get-ServerExe
Assert-True -Condition ($null -eq $serverExe -or $serverExe -like '*xianyu-server.exe') `
    -Label ("Get-ServerExe 返回合法：" + $(if ($serverExe) { '已构建' } else { '未构建' }))

# Test-Prerequisites 必须返回带 Name/Ok/Detail 的对象数组，且不抛错
$prereq = Test-Prerequisites
$shapeOk = ($prereq.Count -ge 4) -and
    (@($prereq | Where-Object { -not $_.PSObject.Properties['Name'] }).Count -eq 0) -and
    (@($prereq | Where-Object { -not $_.PSObject.Properties['Ok'] }).Count -eq 0)
Assert-True -Condition $shapeOk -Label "Test-Prerequisites 返回 $($prereq.Count) 项且结构完整"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('  ' + ('═' * 62)) -ForegroundColor DarkGray
$passed = $total - $failures.Count
$color = if ($failures.Count -eq 0) { 'Green' } else { 'Red' }
Write-Host "  自测结论：通过 $passed / 失败 $($failures.Count) / 共 $total" -ForegroundColor $color
Write-Host ('  ' + ('═' * 62)) -ForegroundColor DarkGray

if ($failures.Count -gt 0) {
    Write-Host ''
    $failures | ForEach-Object { Write-Host "  ✗ $_" -ForegroundColor Red }
    exit 1
}
Write-Host ''
exit 0