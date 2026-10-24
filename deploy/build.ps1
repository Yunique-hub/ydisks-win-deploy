<#
.SYNOPSIS
    构建 Ydisks闲鱼助手：前端资源 + Go 可执行文件。

.DESCRIPTION
    构建顺序不能颠倒：前端必须先构建到 internal/webui/static/，因为 Go 用
    //go:embed 把前端产物编进二进制。先编 Go 再构建前端，二进制里就是旧前端。

    产物：
        runtime/bin/xianyu-server.exe      HTTP API + 账号运行时 + Chromium 宿主
        runtime/bin/xianyu-tray.exe        Windows 托盘控制器
        runtime/bin/browser-install.exe    Chromium 安装辅助程序

.PARAMETER SkipFrontend
    跳过前端构建（前端没改过时可省 10-20 秒）。
.PARAMETER SkipGo
    跳过 Go 构建。
.PARAMETER NoTrim
    不裁剪符号表（保留调试信息，产物更大但可用 delve 调试）。

.EXAMPLE
    .\deploy\build.ps1
    .\deploy\build.ps1 -SkipFrontend
#>
[CmdletBinding()]
param(
    [switch]$SkipFrontend,
    [switch]$SkipGo,
    [switch]$NoTrim
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name 'build'

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Log "构建开始：$($script:RepoRoot)"

# ---------------------------------------------------------------------------
Write-Step '检查源码'
if (-not (Test-Path (Join-Path $script:Paths.App 'go.mod'))) {
    Write-Log "上游源码不存在：$($script:Paths.App)" -Level ERROR
    Write-Log '请先运行 deploy\bootstrap.ps1 完成首次部署' -Level ERROR
    exit 1
}

$commit = ''
$branch = ''
Push-Location $script:Paths.App
try {
    $commit = (& git rev-parse --short HEAD 2>&1 | Select-Object -First 1).Trim()
    $branch = (& git rev-parse --abbrev-ref HEAD 2>&1 | Select-Object -First 1).Trim()
} finally {
    Pop-Location
}
Write-Log "源码：$branch @ $commit" -Level OK

# ---------------------------------------------------------------------------
if (-not $SkipFrontend) {
    Write-Step '构建前端（产物嵌入 Go 二进制的 internal/webui/static）'

    $frontend = Join-Path $script:Paths.App 'frontend'
    if (-not (Test-Path (Join-Path $frontend 'node_modules'))) {
        Write-Log 'node_modules 不存在，先安装依赖...' -Level WARN
        $npm = Get-ToolPath -Name 'npm'
        Invoke-External -FilePath $npm -Arguments @('ci', '--no-audit', '--no-fund') `
            -WorkingDirectory $frontend -Echo $true
    }

    $npmCmd = Get-ToolPath -Name 'npm'
    $r = Invoke-External -FilePath $npmCmd -Arguments @('run', 'build') `
        -WorkingDirectory $frontend
    ($r.Output | Select-Object -Last 4) | ForEach-Object { Write-Log "  $_" }

    $staticDir = Join-Path $script:Paths.App 'internal\webui\static'
    if (-not (Test-Path (Join-Path $staticDir 'index.html'))) {
        Write-Log '前端构建后没有生成 internal\webui\static\index.html' -Level ERROR
        exit 1
    }
    $fileCount = (Get-ChildItem $staticDir -Recurse -File | Measure-Object).Count
    $sizeKb = [math]::Round((Get-ChildItem $staticDir -Recurse -File | Measure-Object Length -Sum).Sum / 1KB, 0)
    Write-Log "前端产物：$fileCount 个文件 / $sizeKb KB" -Level OK
} else {
    Write-Step '跳过前端构建'
}

# ---------------------------------------------------------------------------
if (-not $SkipGo) {
    Write-Step '构建 Go 可执行文件'

    # Windows 不允许覆盖正在运行的 exe：Go 会写出 "xxx.exe~" 然后改名失败，
    # 结果产物是旧的、还多一个垃圾文件。所以构建前必须先停服务。
    $runningServer = Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue
    $restartAfterBuild = $false
    if ($runningServer) {
        Write-Log "服务正在运行（PID $($runningServer.Id)），先停止以释放可执行文件" -Level WARN
        & (Join-Path $PSScriptRoot 'stop.ps1') -Quiet
        $restartAfterBuild = $true
    }
    # 清掉历史遗留的临时产物
    Get-ChildItem $script:Paths.Bin -Filter '*.exe~' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Log "清理遗留临时产物 $($_.Name)" -Level WARN
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }

    Initialize-GoEnvironment
    if (-not (Test-Path $script:Paths.Bin)) {
        New-Item -ItemType Directory -Force -Path $script:Paths.Bin | Out-Null
    }

    # 版本变量在 xianyu-go/internal/version 包里，不是 main ——
    # 写成 -X main.commit 会静默无效，产物永远显示 "dev (commit unknown)"。
    # 变量名必须是 Version / Commit / BuildTime（首字母大写，与包内声明一致）。
    $versionPkg = 'xianyu-go/internal/version'
    $fullCommit = ''
    Push-Location $script:Paths.App
    try {
        $fullCommit = (& git rev-parse HEAD 2>&1 | Select-Object -First 1).Trim()
    } finally {
        Pop-Location
    }
    $buildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    # 版本号：优先取上游 git tag（v1.2.3 形式），没有就用 dev-<短SHA>
    $version = ''
    Push-Location $script:Paths.App
    try {
        $tag = (& git describe --tags --abbrev=0 2>&1 | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -eq 0 -and $tag -match '^v?\d') { $version = $tag -replace '^v', '' }
    } finally {
        Pop-Location
    }
    if (-not $version) { $version = "dev-$commit" }

    $ldflags = "-X $versionPkg.Version=$version -X $versionPkg.Commit=$fullCommit -X $versionPkg.BuildTime=$buildTime"
    if (-not $NoTrim) { $ldflags = "-s -w $ldflags" }

    Write-Log "版本号 $version  提交 $commit"

    $targets = @(
        @{ Name = 'xianyu-server';   Pkg = './cmd/server';           Desc = 'HTTP API 与账号运行时' },
        @{ Name = 'xianyu-tray';     Pkg = './cmd/tray';             Desc = 'Windows 托盘控制器' },
        @{ Name = 'browser-install'; Pkg = './cmd/browser-install';  Desc = 'Chromium 安装辅助' }
    )

    $goExe = Get-GoExe
    foreach ($t in $targets) {
        $outExe = Join-Path $script:Paths.Bin "$($t.Name).exe"
        Write-Log "编译 $($t.Name)（$($t.Desc)）..."
        $swTarget = [System.Diagnostics.Stopwatch]::StartNew()
        # 变量名不能叫 $args：$args 是 PowerShell 自动变量，函数内赋值会报
        # "Cannot overwrite variable args because it is read-only or constant"。
        $buildArgs = @('build', '-trimpath', '-ldflags', $ldflags, '-o', $outExe, $t.Pkg)
        $r = Invoke-External -FilePath $goExe -Arguments $buildArgs -WorkingDirectory $script:Paths.App
        $swTarget.Stop()

        if (-not (Test-Path $outExe)) {
            Write-Log "$($t.Name) 构建失败：未生成 $outExe" -Level ERROR
            exit 1
        }
        $mb = [math]::Round((Get-Item $outExe).Length / 1MB, 1)
        Write-Log "  $($t.Name).exe  $mb MB  $([math]::Round($swTarget.Elapsed.TotalSeconds,1)) 秒" -Level OK
    }
} else {
    Write-Step '跳过 Go 构建'
}

# ---------------------------------------------------------------------------
$sw.Stop()
Write-Step '构建完成'
Write-Log "总耗时 $([math]::Round($sw.Elapsed.TotalSeconds,1)) 秒" -Level OK
Write-Log ''
Write-Log '产物清单：' -Level INFO
Get-ChildItem $script:Paths.Bin -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike '*~' } | ForEach-Object {
    Write-Log ("  {0,-24} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB))
}
# 两个部分都在本脚本里，用局部变量判断是否需要恢复服务
if ($restartAfterBuild) {
    Write-Log ''
    Write-Log '构建前停掉过服务，正在恢复...' -Level INFO
    & (Join-Path $PSScriptRoot 'start.ps1')
}
Write-Log ''
Write-Log '下一步：deploy\start.ps1 启动服务' -Level INFO