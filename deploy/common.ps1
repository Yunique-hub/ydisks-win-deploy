<#
.SYNOPSIS
    Ydisks闲鱼助手 Windows 本地部署 —— 公共函数与环境定义。

.DESCRIPTION
    所有部署脚本都 dot-source 本文件，集中定义目录布局、Go 环境、日志与
    通用辅助函数，避免各处重复且不一致。

    目录布局（相对仓库根）：
        app/        上游源码（git 工作副本，只用于构建）
        runtime/    工具链与产物（可整体删除后由 bootstrap 重建）
        data/       SQLite 数据库、上传文件、数据加密密钥
        logs/       服务日志
        downloads/  下载缓存

.NOTES
    兼容 Windows PowerShell 5.1（Windows 自带），不依赖 PowerShell 7。
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 编码：中文路径与输出在 5.1 下必须显式设置，否则日志全是乱码
# ---------------------------------------------------------------------------
function Set-Utf8Console {
    <#
    .SYNOPSIS
        把控制台输出编码固定为 UTF-8（无乱码、无替换字符）。

    .DESCRIPTION
        Windows PowerShell 5.1 默认用系统 ANSI 代码页（简体中文机器上是 936/GBK）
        编码**管道输出**。脚本写中文时，若 stdout 被重定向或以 `& { } 2>&1` 捕获，
        非 ASCII 字符会被替换成 '?'（实测：`$x = & script.ps1 2>&1` 后中文全变问号）。

        PowerShell 7 默认已是 UTF-8，这里重复设置是无副作用的幂等操作。

        注意：这个函数只能修「输出」编码。脚本**源码**的编码问题由文件自身的
        UTF-8 BOM 解决 —— 5.1 会把无 BOM 的 UTF-8 文件当 ANSI 读，中文串被撕裂后
        连语法都会崩（Missing closing '}'）。两者缺一不可。
    #>
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $script:OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $global:OutputEncoding = $script:OutputEncoding
    } catch {
        # 某些宿主（如 ISE、部分受限会话）不允许改控制台编码，忽略即可
    }
}

Set-Utf8Console

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------
# $PSScriptRoot 是 deploy\，仓库根是它的上一级
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$script:Paths = [ordered]@{
    Root       = $script:RepoRoot
    Deploy     = Join-Path $script:RepoRoot 'deploy'
    App        = Join-Path $script:RepoRoot 'app'
    Runtime    = Join-Path $script:RepoRoot 'runtime'
    GoRoot     = Join-Path $script:RepoRoot 'runtime\go'
    GoPath     = Join-Path $script:RepoRoot 'runtime\gopath'
    GoCache    = Join-Path $script:RepoRoot 'runtime\gocache'
    GoTmp      = Join-Path $script:RepoRoot 'runtime\gotmp'
    Bin        = Join-Path $script:RepoRoot 'runtime\bin'
    Playwright = Join-Path $script:RepoRoot 'runtime\playwright'
    PwDriver   = Join-Path $script:RepoRoot 'runtime\playwright\playwright-driver'
    PwBrowsers = Join-Path $script:RepoRoot 'runtime\playwright\playwright-browsers'
    Data       = Join-Path $script:RepoRoot 'data'
    Logs       = Join-Path $script:RepoRoot 'logs'
    Downloads  = Join-Path $script:RepoRoot 'downloads'
    Docs       = Join-Path $script:RepoRoot 'docs'
}

# ---------------------------------------------------------------------------
# 版本与常量
# ---------------------------------------------------------------------------
# 工具链版本：与上游 go.mod 的 `go 1.26.4` 保持同一 minor 线
$script:GoVersion      = '1.26.10'
$script:GoZipName      = "go$($script:GoVersion).windows-amd64.zip"
$script:GoDownloadUrl  = "https://go.dev/dl/$($script:GoZipName)"
# 国内直连 proxy.golang.org 极慢且易断，走镜像；多个镜像依次兜底
$script:GoProxy        = 'https://goproxy.cn,https://goproxy.io,direct'
$script:GoSumDb        = 'sum.golang.google.cn'

# 服务默认监听端口（上游默认值）
$script:DefaultPort    = 59188
$script:DefaultDbFile  = 'xianyu_data.db'
$script:WindowsService = 'YdisksXianyuHelper'

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
$script:LogFile = $null

function Initialize-DeployLog {
    <#
    .SYNOPSIS
        开始一次带文件留存的部署日志。
    .PARAMETER Name
        日志文件名（不含路径），如 'bootstrap'。
    #>
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Test-Path $script:Paths.Logs)) {
        New-Item -ItemType Directory -Force -Path $script:Paths.Logs | Out-Null
    }
    $script:LogFile = Join-Path $script:Paths.Logs "$Name.$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

function Write-Log {
    <#
    .SYNOPSIS
        写一行带时间戳的日志（同时输出到控制台与日志文件）。
    .PARAMETER Message
        日志正文。
    .PARAMETER Level
        级别：INFO / OK / WARN / ERROR / STEP。
    #>
    param(
        # AllowEmptyString：脚本里常用 Write-Log '' 输出一个空行，
        # 而 [Parameter(Mandatory)] 默认会拒绝空字符串并报
        # "Cannot bind argument to parameter 'Message' because it is an empty string"
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )

    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$stamp] $($Level.PadRight(5)) $Message"
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
}

function Write-Step {
    <#
    .SYNOPSIS
        打印一个阶段标题，便于在长流程里定位进度。
    .PARAMETER Text
        标题文本。
    #>
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Log "▶ $Text" -Level STEP
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 外部命令
# ---------------------------------------------------------------------------
function Resolve-ExternalPath {
    <#
    .SYNOPSIS
        把命令名或路径解析成 Start-Process 真正能执行的文件。

    .DESCRIPTION
        Windows 上 npm / npx 这类工具在 PATH 里同时有 npm.cmd、npm.ps1、npm
        （无扩展名的 bash 脚本）。`(Get-Command npm).Source` 在 PowerShell 里
        往往返回 **npm.ps1** —— 而 Start-Process 无法执行 .ps1，会报
        "不是有效的 Win32 应用程序"。

        所以统一按 exe > cmd > bat 的优先级挑同名的可执行兄弟文件；
        只能拿到 .ps1 时用 powershell.exe -File 包一层。

    .PARAMETER Name
        命令名（如 'npm'）或完整路径。
    .OUTPUTS
        可直接交给 Start-Process 的路径字符串。
    #>
    param([Parameter(Mandatory)][string]$Name)

    # 已经是路径
    if (Test-Path -LiteralPath $Name) {
        $full = (Resolve-Path -LiteralPath $Name).Path
    } else {
        $cmd = Get-Command $Name -ErrorAction SilentlyContinue
        if (-not $cmd) { throw "找不到命令：$Name" }
        $full = $cmd.Source
        if (-not $full) { $full = $cmd.Path }
    }

    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()

    # .exe / .com 直接可用
    if ($ext -in @('.exe', '.com')) { return $full }

    # .ps1 或没有扩展名：优先找同名的 .cmd / .exe
    if ($ext -in @('.ps1', '')) {
        $base = if ($ext -eq '.ps1') { $full.Substring(0, $full.Length - 4) } else { $full }
        foreach ($candidate in @("$base.exe", "$base.cmd", "$base.bat")) {
            if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        }
        # 真只有 .ps1：用 powershell 包一层
        if ($ext -eq '.ps1') {
            return $full
        }
    }

    return $full
}

function ConvertTo-ArgumentString {
    <#
    .SYNOPSIS
        把参数数组拼成 Start-Process 能正确传递的命令行字符串。
    .DESCRIPTION
        Start-Process 的 -ArgumentList 只是把数组元素**用空格连接**，不会加引号。
        于是 `-ldflags "-s -w -X main.commit=abc"` 会被拆成
        `-ldflags -s -w -X main.commit=abc`，Go 会把 `-s` / `-w` 当成自己的 flag
        并报 `flag provided but not defined: -w`。

        这里按 Windows 命令行规则给含空白或引号的参数加引号：
          * 反斜杠只在紧邻引号或位于参数末尾时才需要翻倍
          * 参数内部的 `"` 转义为 `\"`

    .PARAMETER Arguments
        参数数组。
    .OUTPUTS
        拼好的命令行字符串。
    #>
    param([string[]]$Arguments = @())

    $parts = foreach ($arg in $Arguments) {
        $a = [string]$arg
        if ($a -eq '') { '""'; continue }
        if ($a -notmatch '[\s"]') { $a; continue }

        # 末尾的连续反斜杠需要先翻倍（否则会被当成引号前的转义）
        $sb = $a -replace '(\\+)$', '$1$1'
        # 内部引号转义
        $sb = $sb -replace '(\\*)"', '$1$1\"'
        '"' + $sb + '"'
    }
    return ($parts -join ' ')
}

function Invoke-External {
    <#
    .SYNOPSIS
        运行外部命令并返回 (退出码, 输出行数组)。
    .DESCRIPTION
        直接 & 调用会让输出混进宿主输出流且难以同时拿到退出码。本函数统一
        捕获输出、记录日志，并在 $FailOnError 时抛错。

        对 .ps1 会自动用 powershell.exe -File 包装（见 Resolve-ExternalPath）。
    .PARAMETER FilePath
        可执行文件路径或命令名。
    .PARAMETER Arguments
        参数数组。
    .PARAMETER WorkingDirectory
        工作目录，默认仓库根。
    .PARAMETER FailOnError
        非零退出码时是否抛异常，默认 $true。
    .PARAMETER Echo
        是否把输出实时打到控制台，默认 $false。
    .PARAMETER TimeoutSeconds
        最长运行秒数。0 表示不限制（默认）。
        **必须给会派生子孙进程的程序设置超时**：Start-Process -Wait 等的是
        "进程及其子孙全部退出"，而 Chromium 这类程序会留着后台子进程，
        不设超时会永远卡住（实测踩过）。
    .OUTPUTS
        [pscustomobject]，含 ExitCode / Output / TimedOut 三个属性。
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $script:RepoRoot,
        [bool]$FailOnError = $true,
        [bool]$Echo = $false,
        [int]$TimeoutSeconds = 0
    )

    $resolved = Resolve-ExternalPath -Name $FilePath
    $realArgs = $Arguments
    if ([System.IO.Path]::GetExtension($resolved).ToLowerInvariant() -eq '.ps1') {
        $realArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $resolved) + $Arguments
        $resolved = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $stdout = Join-Path $env:TEMP "ydisks_out.$PID.$(Get-Random).txt"
    $stderr = Join-Path $env:TEMP "ydisks_err.$PID.$(Get-Random).txt"
    $argString = ConvertTo-ArgumentString -Arguments $realArgs
    $timedOut = $false
    try {
        $proc = Start-Process -FilePath $resolved -ArgumentList $argString `
            -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr

        if ($TimeoutSeconds -gt 0) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 300
            }
            if (-not $proc.HasExited) {
                $timedOut = $true
                # taskkill /T 杀整棵进程树，/F 强制。
                # 只 Stop-Process 父进程会把子进程留成孤儿继续占用文件与端口。
                & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
                Start-Sleep -Milliseconds 800
            }
        } else {
            $proc.WaitForExit()
        }
        if (-not $proc.HasExited) { $proc.WaitForExit(5000) | Out-Null }

        $out = @()
        if (Test-Path $stdout) { $out += Get-Content -LiteralPath $stdout -Encoding UTF8 }
        if (Test-Path $stderr) {
            $errLines = Get-Content -LiteralPath $stderr -Encoding UTF8
            if ($errLines) { $out += $errLines }
        }
        if ($Echo) { $out | ForEach-Object { Write-Host "    $_" } }
        if ($script:LogFile -and $out -and -not $Echo) {
            Add-Content -LiteralPath $script:LogFile -Value $out -Encoding UTF8
        }

        $exitCode = if ($timedOut) { -1 } else { $proc.ExitCode }
        if ($FailOnError -and -not $timedOut -and $exitCode -ne 0) {
            throw "$FilePath 退出码 $exitCode：`n" + (($out | Select-Object -Last 15) -join "`n")
        }
        if ($FailOnError -and $timedOut) {
            throw "$FilePath 超过 $TimeoutSeconds 秒未退出，已强制结束进程树"
        }
        return [pscustomobject]@{ ExitCode = $exitCode; Output = $out; TimedOut = $timedOut }
    } finally {
        Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
    }
}

function Get-ToolPath {
    <#
    .SYNOPSIS
        取某个外部工具的**可执行**路径（供直接 & 调用或拼参数）。
    .DESCRIPTION
        解决 npm.ps1 的问题：返回 npm.cmd 而不是 npm.ps1。
    .PARAMETER Name
        命令名，如 'npm' / 'git' / 'node'。
    #>
    param([Parameter(Mandatory)][string]$Name)
    return (Resolve-ExternalPath -Name $Name)
}

function Get-GoExe {
    <#
    .SYNOPSIS
        返回便携 Go 的 go.exe 路径；未安装时返回 $null。
    #>
    $exe = Join-Path $script:Paths.GoRoot 'bin\go.exe'
    if (Test-Path $exe) { return $exe }
    return $null
}

function Initialize-GoEnvironment {
    <#
    .SYNOPSIS
        把 Go 工具链环境注入当前进程（GOROOT/GOPATH/GOCACHE/GOPROXY/PATH）。
    .DESCRIPTION
        全部指向仓库内的 runtime\ 目录，实现"自包含"：删掉 runtime\ 就能
        完全重置，不会污染用户级 Go 配置。
    .PARAMETER UseProxy
        是否让 Go 的网络请求走系统代理（默认关闭：模块镜像在国内直连更快）。
    #>
    param([bool]$UseProxy = $false)

    $goRoot = $script:Paths.GoRoot
    if (-not (Test-Path (Join-Path $goRoot 'bin\go.exe'))) {
        throw "Go 工具链未安装：$goRoot。请先运行 deploy\bootstrap.ps1"
    }

    foreach ($dir in @($script:Paths.GoPath, $script:Paths.GoCache, $script:Paths.GoTmp)) {
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    }

    $env:GOROOT      = $goRoot
    $env:GOPATH      = $script:Paths.GoPath
    $env:GOCACHE     = $script:Paths.GoCache
    $env:GOMODCACHE  = Join-Path $script:Paths.GoPath 'pkg\mod'
    $env:GOTMPDIR    = $script:Paths.GoTmp
    $env:GOPROXY     = $script:GoProxy
    $env:GOSUMDB     = $script:GoSumDb
    # local：禁止 Go 自动下载别的工具链版本，必须用我们装的这个
    $env:GOTOOLCHAIN = 'local'
    # CGO 关闭：Windows 上无需 C 工具链，产物是纯静态可执行文件
    $env:CGO_ENABLED = '0'
    if ($UseProxy) {
        $env:HTTP_PROXY  = Get-SystemProxy
        $env:HTTPS_PROXY = Get-SystemProxy
    }
    $env:PATH = "$goRoot\bin;$env:PATH"
}

function Get-SystemProxy {
    <#
    .SYNOPSIS
        读取 Windows「Internet 选项」里配置的系统代理，返回 http://host:port。
    .DESCRIPTION
        这台机器上 Direct 连 GitHub 会被重置，必须走系统代理。
        curl.exe 不读这个设置，Go 也不会自动读，所以要显式取出来用。
    .OUTPUTS
        代理 URL；未配置时返回空字符串。
    #>
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' `
            -ErrorAction SilentlyContinue
        if ($reg -and $reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $server = [string]$reg.ProxyServer
            if ($server -notmatch '://') { $server = "http://$server" }
            return $server
        }
    } catch {
        # 读注册表失败不影响部署，当作没有代理
    }
    return ''
}

function Test-PortListening {
    <#
    .SYNOPSIS
        判断本机某端口是否处于监听状态。
    .PARAMETER Port
        端口号。
    #>
    param([Parameter(Mandatory)][int]$Port)
    $conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    return [bool]$conn
}

function Wait-HttpOk {
    <#
    .SYNOPSIS
        轮询等待某个 URL 返回 2xx，超时则返回 $false。
    .PARAMETER Url
        目标 URL。
    .PARAMETER TimeoutSeconds
        最长等待秒数。
    .PARAMETER IntervalSeconds
        轮询间隔秒数。
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 60,
        [double]$IntervalSeconds = 1.5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -TimeoutSec 5 -UseBasicParsing
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return $true }
        } catch {
            # 服务还没起来，继续等
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Get-ServerExe {
    <#
    .SYNOPSIS
        返回已构建的 xianyu-server.exe 路径；未构建时返回 $null。
    #>
    $exe = Join-Path $script:Paths.Bin 'xianyu-server.exe'
    if (Test-Path $exe) { return $exe }
    return $null
}

function Get-StopFile {
    <#
    .SYNOPSIS
        服务"停止标记文件"的路径。
    .DESCRIPTION
        Windows 上给非服务模式进程发优雅停止信号没有通用做法，这里用一个
        约定文件：进程内实现了文件监视，看到该文件即优雅退出。
    #>
    return (Join-Path $script:Paths.Runtime 'server.stop')
}

# ---------------------------------------------------------------------------
# 能力检测
# ---------------------------------------------------------------------------
function Test-Prerequisites {
    <#
    .SYNOPSIS
        检查部署所需的外部前置条件，返回逐项结果。
    .OUTPUTS
        [pscustomobject] 数组，每项含 Name / Ok / Detail 三个属性。
    #>
    $results = @()

    # Git：克隆/更新上游源码用
    $git = Get-Command git -ErrorAction SilentlyContinue
    $results += [pscustomobject]@{
        Name   = 'Git'
        Ok     = [bool]$git
        Detail = if ($git) { (& git --version 2>&1 | Select-Object -First 1) } else { '未安装（https://git-scm.com/download/win）' }
    }

    # Node.js 24+：构建前端用
    $node = Get-Command node -ErrorAction SilentlyContinue
    $nodeVer = ''
    if ($node) { $nodeVer = (& node --version 2>&1 | Select-Object -First 1) }
    $nodeMajor = 0
    if ($nodeVer -match 'v(\d+)') { $nodeMajor = [int]$Matches[1] }
    $results += [pscustomobject]@{
        Name   = 'Node.js 24+'
        Ok     = ($nodeMajor -ge 24)
        Detail = if ($node) { $nodeVer } else { '未安装（https://nodejs.org/）' }
    }

    $npm = Get-Command npm -ErrorAction SilentlyContinue
    $results += [pscustomobject]@{
        Name   = 'npm'
        Ok     = [bool]$npm
        Detail = if ($npm) { "npm $(& npm --version 2>&1 | Select-Object -First 1)" } else { '未安装' }
    }

    # Go：可选，bootstrap 会自动下载便携版
    $go = Get-GoExe
    $results += [pscustomobject]@{
        Name   = 'Go 工具链'
        Ok     = [bool]$go
        Detail = if ($go) { (& $go version 2>&1 | Select-Object -First 1) } else { "未安装（bootstrap 会自动下载 $($script:GoVersion)）" }
    }

    # 磁盘空间：Go 模块缓存 + Chromium 约需 1.5 GB
    try {
        $drive = (Get-Item $script:RepoRoot).PSDrive
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        $results += [pscustomobject]@{
            Name   = '磁盘可用空间 ≥ 2 GB'
            Ok     = ($drive.Free -ge 2GB)
            Detail = "$($drive.Name): 可用 $freeGb GB"
        }
    } catch {
        $results += [pscustomobject]@{ Name = '磁盘可用空间'; Ok = $true; Detail = '无法读取（跳过）' }
    }

    return $results
}