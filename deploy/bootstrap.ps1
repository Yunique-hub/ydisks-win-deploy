<#
.SYNOPSIS
    Ydisks闲鱼助手 Windows 本地部署 —— 从零一键部署。

.DESCRIPTION
    在干净的 Windows 机器上把整套系统跑起来：

        1. 检查前置条件（Git / Node.js 24）
        2. 下载便携 Go 工具链（不污染系统，装在 runtime\go）
        3. 获取上游源码（git clone，已存在则按需更新）
        4. 安装前端依赖并构建（产物嵌入 Go 二进制）
        5. 编译 Go 可执行文件
        6. 安装 Playwright driver 与 Chromium（浏览器自动化必需）
        7. 初始化管理员账号
        8. 启动服务并做健康检查
        9. 打印访问地址

    每一步都可重复执行：已经完成的步骤会跳过或增量处理。

.PARAMETER Port
    HTTP 监听端口，默认 59188。
.PARAMETER AdminPassword
    管理员密码。不传则自动生成一个强随机密码并打印出来。
.PARAMETER AdminEmail
    管理员邮箱，默认 admin@example.com。
.PARAMETER SkipBrowser
    跳过 Chromium 安装。跳过浏览器后"浏览器指纹读取""token 滑块自动处理"
    等依赖 Chromium 的能力不可用，服务需以 -no-browser 启动。
.PARAMETER Force
    强制重做：重新下载 Go、重新克隆源码。
.PARAMETER NoStart
    只部署不启动（用于先初始化再手工启动）。

.EXAMPLE
    .\deploy\bootstrap.ps1
    .\deploy\bootstrap.ps1 -Port 59188 -AdminPassword 'MyStrongPass123'
#>
[CmdletBinding()]
param(
    [int]$Port = 59188,
    [string]$AdminPassword = '',
    [string]$AdminEmail = 'admin@example.com',
    [switch]$SkipBrowser,
    [switch]$Force,
    [switch]$NoStart
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name 'bootstrap'

$total = [System.Diagnostics.Stopwatch]::StartNew()

Write-Host ''
Write-Host '  Ydisks闲鱼助手 · Windows 本地部署' -ForegroundColor White
Write-Host "  仓库根：$($script:RepoRoot)" -ForegroundColor DarkGray
Write-Host "  日志：$($script:LogFile)" -ForegroundColor DarkGray

# ===========================================================================
Write-Step '1/9 检查前置条件'
$prereq = Test-Prerequisites
$hardFail = $false
foreach ($p in $prereq) {
    if ($p.Ok) {
        Write-Log "$($p.Name)：$($p.Detail)" -Level OK
    } else {
        # Go 与磁盘空间不阻塞（Go 会自动下载），其余缺一不可
        if ($p.Name -like 'Go*' -or $p.Name -like '磁盘*') {
            Write-Log "$($p.Name)：$($p.Detail)" -Level WARN
        } else {
            Write-Log "$($p.Name)：$($p.Detail)" -Level ERROR
            $hardFail = $true
        }
    }
}
if ($hardFail) {
    Write-Log '' 
    Write-Log '缺少必需的前置条件，部署中止。装好后重跑本脚本即可。' -Level ERROR
    exit 1
}

# ===========================================================================
Write-Step "2/9 准备便携 Go 工具链（$($script:GoVersion)）"

$goExe = Get-GoExe
if ($goExe -and -not $Force) {
    Write-Log "已安装：$(& $goExe version 2>&1 | Select-Object -First 1)" -Level OK
} else {
    if (-not (Test-Path $script:Paths.Downloads)) {
        New-Item -ItemType Directory -Force -Path $script:Paths.Downloads | Out-Null
    }
    $zip = Join-Path $script:Paths.Downloads $script:GoZipName

    if ((Test-Path $zip) -and -not $Force) {
        Write-Log "复用已下载的安装包：$($script:GoZipName)" -Level INFO
    } else {
        Write-Log "下载 $($script:GoDownloadUrl)"
        # GitHub/go.dev 直连会被重置，必须走系统代理
        $proxy = Get-SystemProxy
        $iwArgs = @{ Uri = $script:GoDownloadUrl; OutFile = $zip; TimeoutSec = 1800 }
        if ($proxy) { $iwArgs['Proxy'] = $proxy; Write-Log "走系统代理 $proxy" -Level INFO }
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest @iwArgs
        } catch {
            Write-Log "下载失败：$($_.Exception.Message)" -Level ERROR
            Write-Log '可手工下载后放到 downloads\ 目录再重跑本脚本' -Level ERROR
            exit 1
        }
    }

    # 校验哈希：从官方 JSON 取期望值，避免用到被篡改的包
    Write-Log '校验 SHA256...'
    try {
        $meta = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json&include=all' -TimeoutSec 60
        $entry = $meta | Where-Object { $_.version -eq "go$($script:GoVersion)" }
        $fileEntry = $entry.files | Where-Object { $_.filename -eq $script:GoZipName }
        $expect = $fileEntry.sha256
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
        if ($expect -and $actual -eq $expect.ToLower()) {
            Write-Log "哈希一致 ${actual}..." -Level OK
        } elseif ($expect) {
            Write-Log "哈希不一致！期望 $expect 实际 $actual" -Level ERROR
            exit 1
        } else {
            Write-Log '官方 JSON 里没找到对应条目，跳过哈希校验' -Level WARN
        }
    } catch {
        Write-Log "取官方哈希失败（$($_.Exception.Message)），跳过校验" -Level WARN
    }

    Write-Log '解压...'
    $tmpDir = Join-Path $script:Paths.Runtime '_go_extract'
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $tmpDir -Force
    Remove-Item $script:Paths.GoRoot -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item (Join-Path $tmpDir 'go') $script:Paths.GoRoot -Force
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    $goExe = Get-GoExe
    if (-not $goExe) { Write-Log 'Go 解压后仍找不到 go.exe' -Level ERROR; exit 1 }
    Write-Log ((& $goExe version 2>&1 | Select-Object -First 1)) -Level OK
}

# ===========================================================================
Write-Step '3/9 获取上游源码'

if (Test-Path (Join-Path $script:Paths.App '.git')) {
    Write-Log 'app\ 已存在，尝试更新...' -Level INFO
    $git = Get-ToolPath -Name 'git'
    $proxy = Get-SystemProxy
    Push-Location $script:Paths.App
    try {
        # 直连 GitHub 在这类网络环境下会被重置，仓库级配置走代理
        if ($proxy) {
            & git config http.proxy $proxy 2>&1 | Out-Null
            & git config https.proxy $proxy 2>&1 | Out-Null
        }
        $local = (& git rev-parse --short HEAD 2>&1 | Select-Object -First 1).Trim()
        try {
            $r = Invoke-External -FilePath $git -Arguments @('fetch', '--prune', 'origin') `
                -WorkingDirectory $script:Paths.App -FailOnError $false
            if ($r.ExitCode -eq 0) {
                $behind = (& git rev-list --count 'HEAD..origin/main' 2>&1 | Select-Object -First 1).Trim()
                Write-Log "本地 $local，落后 origin/main $behind 个提交" -Level OK
            } else {
                Write-Log '拉取失败（网络？），沿用现有代码继续' -Level WARN
            }
        } catch {
            Write-Log "拉取异常：$($_.Exception.Message)，沿用现有代码" -Level WARN
        }
    } finally {
        Pop-Location
    }
} else {
    if ($Force) { Remove-Item $script:Paths.App -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Log '克隆上游仓库...'
    $git = Get-ToolPath -Name 'git'
    $proxy = Get-SystemProxy
    $cloneArgs = @('clone', '--depth', '1',
        'https://github.com/Christ9038/Ydisks-Xianyu-Helper.git', $script:Paths.App)
    if ($proxy) { $cloneArgs = @('-c', "http.proxy=$proxy") + $cloneArgs }
    $r = Invoke-External -FilePath $git -Arguments $cloneArgs `
        -WorkingDirectory $script:RepoRoot -FailOnError $false -Echo $true
    if ($r.ExitCode -ne 0 -or -not (Test-Path (Join-Path $script:Paths.App 'go.mod'))) {
        Write-Log '克隆失败。可手工 clone 到 app\ 后重跑本脚本' -Level ERROR
        exit 1
    }
    Write-Log '克隆完成' -Level OK
}

# ===========================================================================
Write-Step '4/9 安装前端依赖'
$frontend = Join-Path $script:Paths.App 'frontend'
$npmCmd = Get-ToolPath -Name 'npm'
if (Test-Path (Join-Path $frontend 'node_modules')) {
    Write-Log 'node_modules 已存在，跳过（需要强制重装请先删除该目录）' -Level OK
} else {
    $r = Invoke-External -FilePath $npmCmd -Arguments @('ci', '--no-audit', '--no-fund') `
        -WorkingDirectory $frontend -Echo $true
    Write-Log '依赖安装完成' -Level OK
}

# ===========================================================================
Write-Step '5/9 构建（前端 + Go 可执行文件）'
& (Join-Path $PSScriptRoot 'build.ps1') -Verbose:$false
if ($LASTEXITCODE -ne 0) { Write-Log '构建失败' -Level ERROR; exit 1 }

# ===========================================================================
if (-not $SkipBrowser) {
    Write-Step '6/9 安装 Playwright driver 与 Chromium'
    $existing = Get-ChildItem $script:Paths.PwBrowsers -Recurse -File -ErrorAction SilentlyContinue
    if ($existing -and $existing.Count -gt 50 -and -not $Force) {
        $mb = [math]::Round(($existing | Measure-Object Length -Sum).Sum / 1MB, 1)
        Write-Log "已安装（$($existing.Count) 个文件 / $mb MB），跳过" -Level OK
    } else {
        foreach ($d in @($script:Paths.PwDriver, $script:Paths.PwBrowsers)) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
        }
        $installer = Join-Path $script:Paths.Bin 'browser-install.exe'
        if (-not (Test-Path $installer)) { Write-Log '缺少 browser-install.exe' -Level ERROR; exit 1 }

        # Playwright 从 CDN 拉包，国内直连不稳，走系统代理
        $proxy = Get-SystemProxy
        if ($proxy) { $env:HTTP_PROXY = $proxy; $env:HTTPS_PROXY = $proxy }

        Write-Log '下载 Chromium（约 150 MB，首次较慢）...'
        $r = Invoke-External -FilePath $installer `
            -Arguments @('-driver-dir', $script:Paths.PwDriver, '-browser-dir', $script:Paths.PwBrowsers) `
            -FailOnError $false -Echo $true
        if ($r.ExitCode -ne 0) {
            Write-Log 'Chromium 安装失败。可用 -SkipBrowser 部署无浏览器模式' -Level ERROR
            exit 1
        }
        $installed = Get-ChildItem $script:Paths.PwBrowsers -Recurse -File -ErrorAction SilentlyContinue
        $mb = [math]::Round(($installed | Measure-Object Length -Sum).Sum / 1MB, 1)
        Write-Log "Chromium 安装完成：$($installed.Count) 个文件 / $mb MB" -Level OK
    }
} else {
    Write-Step '6/9 跳过 Chromium 安装'
    Write-Log '注意：浏览器相关能力将不可用，启动时必须加 -no-browser' -Level WARN
}

# ===========================================================================
Write-Step '7/9 初始化数据目录与管理员账号'

foreach ($d in @($script:Paths.Data, (Join-Path $script:Paths.Data 'uploads'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$serverExe = Join-Path $script:Paths.Bin 'xianyu-server.exe'
$dbFile = Join-Path $script:Paths.Data $script:DefaultDbFile

if (Test-Path $dbFile) {
    Write-Log "数据库已存在：$dbFile" -Level OK
    Write-Log '如需重置管理员密码，用 deploy\reset-admin.ps1' -Level INFO
} else {
    if (-not $AdminPassword) {
        # 生成 20 位强随机密码：大小写 + 数字，避开容易混淆的字符
        $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
        $AdminPassword = -join (1..20 | ForEach-Object { $alphabet[(Get-Random -Maximum $alphabet.Length)] })
    }
    Write-Log "创建数据库并初始化管理员（用户名 admin，邮箱 $AdminEmail）"
    $r = Invoke-External -FilePath $serverExe `
        -Arguments @('-init-admin', '-db', $dbFile, '-admin-password', $AdminPassword,
                     '-admin-email', $AdminEmail) `
        -WorkingDirectory $script:RepoRoot -FailOnError $false -Echo $true
    if ($r.ExitCode -ne 0 -or -not (Test-Path $dbFile)) {
        Write-Log '管理员初始化失败' -Level ERROR
        exit 1
    }
    Write-Log '数据库与管理员创建完成' -Level OK

    # 密码只在这里打印一次，之后不再回显
    Write-Host ''
    Write-Host '  ┌────────────────────────────────────────────────────────┐' -ForegroundColor Yellow
    Write-Host '  │  管理员账号（请立即保存，密码不会再次显示）            │' -ForegroundColor Yellow
    Write-Host '  ├────────────────────────────────────────────────────────┤' -ForegroundColor Yellow
    Write-Host ("  │  用户名：admin                                        │") -ForegroundColor Yellow
    Write-Host ("  │  密码：{0,-46}│" -f $AdminPassword) -ForegroundColor Yellow
    Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Yellow
    Write-Host ''
    # 同时写入仅本机可见的凭据文件，方便首次登录后改密
    $credFile = Join-Path $script:Paths.Data '初始管理员凭据.txt'
    @"
Ydisks闲鱼助手 —— 初始管理员凭据
生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

用户名：admin
密码：  $AdminPassword
邮箱：  $AdminEmail

请登录后立即在「系统设置」里修改密码，并删除本文件。
"@ | Set-Content -LiteralPath $credFile -Encoding UTF8
    Write-Log "凭据已另存：$credFile" -Level INFO
}

# ===========================================================================
if (-not $NoStart) {
    Write-Step '8/9 启动服务'
    & (Join-Path $PSScriptRoot 'start.ps1') -Port $Port -SkipBrowser:$SkipBrowser
    if ($LASTEXITCODE -ne 0) { Write-Log '启动失败，见 logs\server.log' -Level ERROR; exit 1 }
} else {
    Write-Step '8/9 跳过启动（-NoStart）'
}

# ===========================================================================
Write-Step '9/9 完成'
$total.Stop()

Write-Host ''
Write-Host '  ┌────────────────────────────────────────────────────────┐' -ForegroundColor Green
Write-Host '  │  部署完成                                              │' -ForegroundColor Green
Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Green
Write-Host ''
Write-Host "  管理后台    http://127.0.0.1:$Port" -ForegroundColor White
Write-Host "  健康检查    http://127.0.0.1:$Port/health" -ForegroundColor White
Write-Host "  用户名      admin" -ForegroundColor White
if ($script:LogFile) {
    Write-Host "  部署日志    $($script:LogFile)" -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  常用命令：' -ForegroundColor DarkGray
Write-Host '    .\deploy\status.ps1    查看状态' -ForegroundColor DarkGray
Write-Host '    .\deploy\stop.ps1      停止服务' -ForegroundColor DarkGray
Write-Host '    .\deploy\start.ps1     启动服务' -ForegroundColor DarkGray
Write-Host '    .\deploy\verify.ps1    运行完整验证' -ForegroundColor DarkGray
Write-Host ''
Write-Log "总耗时 $([math]::Round($total.Elapsed.TotalSeconds,1)) 秒" -Level OK