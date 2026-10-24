<#
.SYNOPSIS
    Ydisks闲鱼助手 —— 部署完整验证。

.DESCRIPTION
    逐层验证本地部署是否真的可用，而不是"进程起来了就算成功"：

        A. 产物层    三个可执行文件存在、版本号已注入、Chromium 运行时完整
        B. 进程层    服务在跑、端口在听、PID 文件一致
        C. HTTP 层   /health 声明数据库可用；SPA 首页与静态资源可访问
        D. 鉴权层    未登录访问受保护接口返回 401；错误密码被拒
        E. 业务层    管理员登录成功；核心列表接口全部返回 200 JSON
        F. 数据层    SQLite 文件存在、表已迁移、数据密钥文件已生成
        G. 浏览器层  用真实 Chromium 无头渲染 SPA，确认前端能挂载
        H. 收尾      优雅停止 → 端口释放 → 重新启动

    每一项都有真实证据（HTTP 状态码、响应片段、文件大小），失败即回报 FAIL
    并给出排查方向。

.PARAMETER Port
    服务端口，默认 59188。
.PARAMETER Password
    管理员密码，用于登录与业务接口验证。留空则跳过 E 段（其余照跑）。
.PARAMETER SkipBrowser
    跳过 G 段（浏览器渲染验证）。
.PARAMETER SkipRestart
    跳过 H 段的停止/重启（不想中断正在使用的服务时用）。
.PARAMETER Json
    以 JSON 输出结果。

.EXAMPLE
    .\deploy\verify.ps1 -Password 'Ydisks@2026#Local'
    .\deploy\verify.ps1 -Password 'xxx' -SkipRestart
#>
[CmdletBinding()]
param(
    [int]$Port = 59188,
    [string]$Password = '',
    [switch]$SkipBrowser,
    [switch]$SkipRestart,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name 'verify'

$base = "http://127.0.0.1:$Port"
$results = New-Object System.Collections.Generic.List[object]
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

function Add-Result {
    <#
    .SYNOPSIS
        记录一项验证结果并打印。
    .PARAMETER Name
        检查项名称。
    .PARAMETER Ok
        是否通过。
    .PARAMETER Detail
        证据或失败原因。
    .PARAMETER Skipped
        是否按配置跳过（不计入失败）。
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = '',
        [switch]$Skipped
    )
    $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Skipped = [bool]$Skipped })
    $mark = if ($Skipped) { 'SKIP' } elseif ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Skipped) { 'Yellow' } elseif ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $mark, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("         $Detail") -ForegroundColor DarkGray }
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value "[$mark] $Name — $Detail" -Encoding UTF8 }
}

function Get-Json {
    <#
    .SYNOPSIS
        发 GET 请求并尝试解析 JSON，返回 (状态码, 对象, 原始文本)。
    #>
    param([string]$Url, [Microsoft.PowerShell.Commands.WebRequestSession]$Session)
    try {
        # 变量名用 $requestArgs 而不是 $args —— $args 是自动变量，
        # 在函数内赋值会抛 "Cannot overwrite variable args because it is read-only".
        $requestArgs = @{ Uri = $Url; TimeoutSec = 20; UseBasicParsing = $true }
        if ($Session) { $requestArgs['WebSession'] = $Session }
        $r = Invoke-WebRequest @requestArgs
        $obj = $null
        try { $obj = $r.Content | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ Code = $r.StatusCode; Json = $obj; Text = $r.Content }
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return [pscustomobject]@{ Code = $code; Json = $null; Text = "$($_.Exception.Message)" }
    }
}

function Invoke-Json {
    <#
    .SYNOPSIS
        发 POST 请求（JSON body），返回 (状态码, 对象, 原始文本)。
    #>
    param(
        [string]$Url, [string]$Body,
        [Microsoft.PowerShell.Commands.WebRequestSession]$Session
    )
    try {
        $requestArgs = @{
            Uri = $Url; Method = 'POST'; Body = $Body; TimeoutSec = 25
            UseBasicParsing = $true; ContentType = 'application/json'
        }
        if ($Session) { $requestArgs['WebSession'] = $Session }
        $r = Invoke-WebRequest @requestArgs
        $obj = $null
        try { $obj = $r.Content | ConvertFrom-Json } catch { }
        return [pscustomobject]@{ Code = $r.StatusCode; Json = $obj; Text = $r.Content }
    } catch {
        $code = 0
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        return [pscustomobject]@{ Code = $code; Json = $null; Text = "$($_.Exception.Message)" }
    }
}

Write-Host ''
Write-Host '  Ydisks闲鱼助手 · 部署完整验证' -ForegroundColor White
Write-Host "  目标 $base" -ForegroundColor DarkGray

# ===========================================================================
Write-Host ''
Write-Host '  A. 产物层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

foreach ($exe in @('xianyu-server.exe', 'xianyu-tray.exe', 'browser-install.exe')) {
    $path = Join-Path $script:Paths.Bin $exe
    if (Test-Path $path) {
        $mb = [math]::Round((Get-Item $path).Length / 1MB, 1)
        Add-Result -Name "可执行文件 $exe" -Ok $true -Detail "$mb MB"
    } else {
        Add-Result -Name "可执行文件 $exe" -Ok $false -Detail '缺失，运行 deploy\build.ps1'
    }
}

$serverExe = Get-ServerExe
if ($serverExe) {
    $vout = (& $serverExe -version 2>&1 | Select-Object -First 1)
    $hasVersion = $vout -notmatch 'unknown|dev \('
    Add-Result -Name '版本与提交号已注入二进制' -Ok $hasVersion -Detail $vout
}

$browserFiles = Get-ChildItem $script:Paths.PwBrowsers -Recurse -File -ErrorAction SilentlyContinue
$browserOk = [bool]($browserFiles -and $browserFiles.Count -gt 50)
Add-Result -Name 'Chromium 运行时完整' -Ok $browserOk -Detail $(
    if ($browserOk) {
        $mb = [math]::Round(($browserFiles | Measure-Object Length -Sum).Sum / 1MB, 1)
        "$($browserFiles.Count) 个文件 / $mb MB"
    } else { '未安装，浏览器相关能力不可用（bootstrap 里加 -SkipBrowser 会得到这个结果）' }
)

$driverNode = Join-Path $script:Paths.PwDriver 'node.exe'
Add-Result -Name 'Playwright driver' -Ok (Test-Path $driverNode) -Detail $(
    if (Test-Path $driverNode) { $driverNode } else { '缺少 playwright-driver\node.exe' }
)

# ===========================================================================
Write-Host ''
Write-Host '  B. 进程层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

$proc = Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Result -Name '服务进程在运行' -Ok ([bool]$proc) -Detail $(
    if ($proc) { "PID $($proc.Id)" } else { '未运行，先执行 deploy\start.ps1' }
)

$listening = Test-PortListening -Port $Port
Add-Result -Name "端口 $Port 已监听" -Ok $listening -Detail $(if ($listening) { 'LISTEN' } else { '无监听' })

$pidFile = Join-Path $script:Paths.Runtime 'server.pid'
if ((Test-Path $pidFile) -and $proc) {
    $filePid = (Get-Content -LiteralPath $pidFile | Select-Object -First 1).Trim()
    Add-Result -Name 'PID 文件与实际进程一致' -Ok ($filePid -eq "$($proc.Id)") -Detail "文件 $filePid / 实际 $($proc.Id)"
} else {
    Add-Result -Name 'PID 文件与实际进程一致' -Ok $false -Detail 'PID 文件缺失'
}

# ===========================================================================
Write-Host ''
Write-Host '  C. HTTP 层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

$health = Get-Json -Url "$base/health"
$healthOk = ($health.Code -eq 200) -and ($health.Text -match '"status"\s*:\s*"ok"') -and ($health.Text -match '"database"\s*:\s*"ok"')
Add-Result -Name '/health 声明服务与数据库均正常' -Ok $healthOk -Detail "HTTP $($health.Code) $($health.Text)"

$spa = Get-Json -Url "$base/"
$spaOk = ($spa.Code -eq 200) -and ($spa.Text -match '<div id="root"') -and ($spa.Text -match '/static/assets/')
Add-Result -Name 'SPA 首页已内嵌并返回' -Ok $spaOk -Detail "HTTP $($spa.Code)，$($spa.Text.Length) 字节"

if ($spaOk) {
    # 静态资源挂在 /static/ 前缀下（不是 /assets/）。
    # 这里直接按 index.html 里真实引用的路径逐个请求，避免自己拼错路径 ——
    # 之前拼成 /assets/xxx 时请求会落进 SPA 回退，拿回 index.html 还误判成"通过"。
    $refs = [regex]::Matches($spa.Text, '(?:src|href)="(/static/[^"]+)"') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    Add-Result -Name '首页引用的静态资源可枚举' -Ok ($refs.Count -ge 2) -Detail "共 $($refs.Count) 个引用"

    $badAssets = @()
    $checkedJs = 0
    foreach ($ref in $refs) {
        $a = Get-Json -Url "$base$ref"
        # 关键：必须确认返回的不是 index.html（SPA 回退会返回 HTML 并附 200）
        $isHtmlFallback = $a.Text -match '<div id="root"'
        if ($a.Code -ne 200 -or $isHtmlFallback) {
            $badAssets += "$ref → HTTP $($a.Code)$(if($isHtmlFallback){'（返回的是 index.html，说明被 SPA 回退吞了）'})"
        }
        if ($ref -like '*.js') { $checkedJs++ }
    }
    Add-Result -Name '静态资源全部真实命中（未被 SPA 回退吞掉）' -Ok ($badAssets.Count -eq 0) -Detail $(
        if ($badAssets.Count -eq 0) { "逐个请求 $($refs.Count) 个资源，含 $checkedJs 个 JS，全部 200 且非 HTML" }
        else { $badAssets -join '; ' }
    )
}

# SPA 深链回退：直接访问前端路由应返回 index.html 而不是 404
$deep = Get-Json -Url "$base/accounts"
Add-Result -Name 'SPA 深链回退正常' -Ok ($deep.Code -eq 200 -and $deep.Text -match '<div id="root"') `
    -Detail "GET /accounts → HTTP $($deep.Code)"

# ===========================================================================
Write-Host ''
Write-Host '  D. 鉴权层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

$anon = Get-Json -Url "$base/api/v1/cards" -Session $session
Add-Result -Name '未登录访问受保护接口被拒（401）' -Ok ($anon.Code -eq 401) -Detail "GET /api/v1/cards → HTTP $($anon.Code)"

$sessionInfo = Get-Json -Url "$base/api/v1/session" -Session $session
$initialized = $false
$sessionDetail = "HTTP $($sessionInfo.Code) $($sessionInfo.Text)"
# /api/v1/session 的响应是**扁平**的：{"authenticated":..,"initialized":..,"is_admin":..}
# 不在 data 下面。StrictMode 下访问不存在的属性会直接抛错，所以先判断属性存在。
if ($sessionInfo.Json -and $sessionInfo.Json.PSObject.Properties['initialized']) {
    $initialized = [bool]$sessionInfo.Json.initialized
}
Add-Result -Name '数据库已完成管理员初始化' -Ok $initialized -Detail $sessionDetail

if ($Password) {
    $bad = Invoke-Json -Url "$base/api/v1/session/login" `
        -Body (@{ username = 'admin'; password = '__definitely_wrong__' } | ConvertTo-Json -Compress) `
        -Session $session
    Add-Result -Name '错误密码被拒绝' -Ok ($bad.Code -eq 401 -or $bad.Code -eq 400 -or $bad.Text -match 'invalid|错误|失败') `
        -Detail "HTTP $($bad.Code)"
} else {
    Add-Result -Name '错误密码被拒绝' -Ok $false -Skipped -Detail '未提供 -Password，跳过'
}

# ===========================================================================
Write-Host ''
Write-Host '  E. 业务层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

if (-not $Password) {
    Add-Result -Name '管理员登录' -Ok $false -Skipped -Detail '未提供 -Password，跳过业务层验证'
} else {
    $login = Invoke-Json -Url "$base/api/v1/session/login" `
        -Body (@{ username = 'admin'; password = $Password } | ConvertTo-Json -Compress) `
        -Session $session
    $loginOk = ($login.Code -eq 200)
    Add-Result -Name '管理员登录成功' -Ok $loginOk -Detail "HTTP $($login.Code) $(if(-not $loginOk){$login.Text})"

    if ($loginOk) {
        # 端点取自上游权威契约 api/openapi.yaml（不要自己猜路径 ——
        # 之前猜的 /api/v1/rules、/api/v1/dashboard 其实都不存在，真实路径是
        # /api/v1/automation-rules 和 /api/v1/analytics/dashboard）。
        # 这里只挑代表性的只读列表接口，覆盖各业务域。
        $endpoints = @(
            @{ Path = '/api/v1/accounts';               Name = '账号管理' },
            @{ Path = '/api/v1/accounts/runtime-status'; Name = '账号运行状态' },
            @{ Path = '/api/v1/items';                  Name = '商品管理' },
            @{ Path = '/api/v1/items/publish-batches';  Name = '铺货批次' },
            @{ Path = '/api/v1/orders';                 Name = '订单管理' },
            @{ Path = '/api/v1/cards';                  Name = '卡密库存' },
            @{ Path = '/api/v1/automation-rules';       Name = '自动化规则' },
            @{ Path = '/api/v1/automation-issues';      Name = '待人工处理' },
            @{ Path = '/api/v1/delivery-templates';     Name = '发货模板' },
            @{ Path = '/api/v1/default-replies';        Name = '默认回复' },
            @{ Path = '/api/v1/reply-rules/items';      Name = '关键词回复' },
            @{ Path = '/api/v1/notifications/channels'; Name = '通知渠道' },
            @{ Path = '/api/v1/notifications/messages'; Name = '通知记录' },
            @{ Path = '/api/v1/analytics/dashboard';    Name = '数据看板' },
            @{ Path = '/api/v1/analytics/sales';        Name = '销售统计' },
            @{ Path = '/api/v1/settings/system';        Name = '系统设置' },
            @{ Path = '/api/v1/settings/ai-reply';      Name = 'AI 回复设置' },
            @{ Path = '/api/v1/admin/users';            Name = '用户管理' },
            @{ Path = '/api/v1/admin/stats';            Name = '管理统计' },
            @{ Path = '/api/v1/logs/runtime';           Name = '运行日志' }
        )
        $epFail = @()
        foreach ($ep in $endpoints) {
            $r = Get-Json -Url "$base$($ep.Path)" -Session $session
            # 判据：HTTP 200 且响应体是合法 JSON。
            # 注意不能用 `$null -ne $r.Json` 判断 —— 空数组 [] 与 $null 在
            # PowerShell 的比较语义下会误判成"空"，导致正常的空列表被报成失败。
            $trimmed = $r.Text.Trim()
            $isJson = $trimmed.StartsWith('{') -or $trimmed.StartsWith('[')
            $ok = ($r.Code -eq 200) -and $isJson
            if (-not $ok) {
                $snippet = if ($r.Text.Length -gt 70) { $r.Text.Substring(0, 70) } else { $r.Text }
                $epFail += "$($ep.Path) → HTTP $($r.Code) $snippet"
            }
        }
        Add-Result -Name "核心业务接口全部可用（$($endpoints.Count) 个）" `
            -Ok ($epFail.Count -eq 0) `
            -Detail $(if ($epFail.Count -eq 0) {
                ($endpoints | ForEach-Object { $_.Name }) -join '、'
            } else { $epFail -join ' | ' })

        # 登出
        $logout = Invoke-Json -Url "$base/api/v1/session/logout" -Body '{}' -Session $session
        Add-Result -Name '登出接口可用' -Ok ($logout.Code -eq 200 -or $logout.Code -eq 204) -Detail "HTTP $($logout.Code)"
    }
}

# ===========================================================================
Write-Host ''
Write-Host '  F. 数据层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

$dbFile = Join-Path $script:Paths.Data $script:DefaultDbFile
if (Test-Path $dbFile) {
    $mb = [math]::Round((Get-Item $dbFile).Length / 1MB, 2)
    Add-Result -Name 'SQLite 数据库存在' -Ok $true -Detail "$dbFile（$mb MB）"

    # 读文件头判断是不是真的 SQLite（"SQLite format 3\0"）。
    # 不能用 File.ReadAllBytes —— 文件正被服务进程独占，会报
    # "The process cannot access the file because it is being used by another process"。
    # 用 FileShare.ReadWrite 打开，只读前 16 字节。
    try {
        $fs = [System.IO.File]::Open($dbFile, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $buf = New-Object byte[] 16
            [void]$fs.Read($buf, 0, 16)
            $header = [System.Text.Encoding]::ASCII.GetString($buf)
        } finally {
            $fs.Close()
        }
        Add-Result -Name '数据库文件格式正确' -Ok ($header -match '^SQLite format 3') `
            -Detail "文件头：$($header.Substring(0, 15))"
    } catch {
        Add-Result -Name '数据库文件格式正确' -Ok $false -Detail "读取文件头失败：$($_.Exception.Message)"
    }
} else {
    Add-Result -Name 'SQLite 数据库存在' -Ok $false -Detail '缺失，运行 bootstrap 初始化'
}

$keyFile = Join-Path $script:Paths.Data 'data.key'
if (Test-Path $keyFile) {
    $keyLen = (Get-Item $keyFile).Length
    Add-Result -Name '数据加密密钥已生成' -Ok ($keyLen -ge 16) -Detail "$keyFile（$keyLen 字节）"
} else {
    Add-Result -Name '数据加密密钥已生成' -Ok $false -Detail '缺失：敏感字段将无法解密'
}

$uploads = Join-Path $script:Paths.Data 'uploads'
Add-Result -Name '上传目录存在' -Ok (Test-Path $uploads) -Detail $uploads

# ===========================================================================
Write-Host ''
Write-Host '  G. 浏览器层' -ForegroundColor Cyan
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

# G1：服务自身的 Chromium 是否就绪 —— 这条最重要。
# 服务用 playwright-go 自己拉起 Chromium，成功时会在日志里打
# "已读取 Playwright Chromium 浏览器指纹" 和 "playwright chromium 就绪"。
# 这是"浏览器功能真的可用"的直接证据，比任何外部探测都可靠。
$serverLog = Join-Path $script:Paths.Logs 'server.log'
if (Test-Path $serverLog) {
    $logText = Get-Content -LiteralPath $serverLog -Raw -Encoding UTF8
    $ready = $logText -match 'playwright chromium 就绪'
    $fpMatch = [regex]::Match($logText, '"browser_version":"([^"]+)"')
    $browserVer = if ($fpMatch.Success) { $fpMatch.Groups[1].Value } else { '未知' }
    Add-Result -Name '服务内 Playwright Chromium 已就绪' -Ok $ready -Detail $(
        if ($ready) { "日志确认；浏览器版本 $browserVer" }
        else { '日志里没有 "playwright chromium 就绪"，浏览器功能可能不可用（检查 -no-browser 是否被启用）' }
    )
} else {
    Add-Result -Name '服务内 Playwright Chromium 已就绪' -Ok $false -Detail "找不到 $serverLog"
}

# G2：外部无头渲染 —— 用 chrome-headless-shell 验证前端在真实浏览器里能挂载。
if ($SkipBrowser) {
    Add-Result -Name 'Chromium 无头渲染 SPA' -Ok $false -Skipped -Detail '按参数跳过'
} else {
    # 必须用 chrome-headless-shell，不要用 chrome.exe。三个实测原因：
    #   1) chrome.exe --dump-dom 在 headless 下**不会自己退出**，
    #      实测 26 秒仍未结束，只能强杀；
    #   2) chrome.exe 会尝试起完整浏览器（加载 chrome://newtab、GCM 注册），
    #      在无桌面会话里可能直接失败；
    #   3) chrome-headless-shell 是 Playwright 专门为无头场景准备的，
    #      实测 0.3 秒返回、退出码 0。
    $shell = Get-ChildItem (Join-Path $script:Paths.PwBrowsers 'chromium_headless_shell-*') -Recurse `
        -Filter 'chrome-headless-shell.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $shell) {
        Add-Result -Name 'Chromium 无头渲染 SPA' -Ok $false `
            -Detail '找不到 chrome-headless-shell.exe（bootstrap 会安装 chromium_headless_shell-*）'
    } else {
        # profile 目录放在 ASCII 路径下（TEMP），并必须先创建出来
        $profDir = Join-Path $env:TEMP "ydisks_verify_profile_$(Get-Random)"
        New-Item -ItemType Directory -Force -Path $profDir | Out-Null
        try {
            $shellArgs = @(
                '--disable-gpu',
                '--no-sandbox',
                '--no-first-run',
                '--disable-dev-shm-usage',
                "--user-data-dir=$profDir",
                '--virtual-time-budget=6000',
                '--dump-dom',
                $base
            )
            $r = Invoke-External -FilePath $shell.FullName -Arguments $shellArgs `
                -FailOnError $false -TimeoutSeconds 60
            $dom = $r.Output -join "`n"

            if ($r.TimedOut) {
                Add-Result -Name 'Chromium 无头渲染 SPA' -Ok $false `
                    -Detail '超过 60 秒未退出，已强制结束进程树'
            } elseif ($dom.Length -lt 300) {
                Add-Result -Name 'Chromium 无头渲染 SPA' -Ok $false `
                    -Detail "DOM 输出过短（$($dom.Length) 字节）；退出码 $($r.ExitCode)"
                ($r.Output | Select-Object -Last 5) | ForEach-Object { Add-Result -Name '  Chromium 输出' -Ok $false -Detail $_ }
            } else {
                # 判据：React 挂载点里真的出现了内容（不是空的 <div id="root"></div>），
                # 且 DOM 里带界面中文文案与静态资源引用。
                $rootEmpty = $dom -match '<div id="root">\s*</div>'
                $hasAppText = $dom -match '登录|账号|管理|设置|闲鱼'
                $assetCount = ([regex]::Matches($dom, '/static/[A-Za-z0-9._/-]+')).Count
                $hasTitle = $dom -match '<title>[^<]+</title>'
                $title = ''
                if ($hasTitle) { $title = [regex]::Match($dom, '<title>([^<]+)</title>').Groups[1].Value }
                $ok = (-not $rootEmpty) -and $hasAppText -and ($assetCount -ge 3)
                Add-Result -Name 'Chromium 无头渲染 SPA' -Ok $ok -Detail (
                    "DOM $($dom.Length) 字节；root 已挂载=$(-not $rootEmpty)；" +
                    "界面文案=$hasAppText；静态资源 $assetCount 个；标题=$title；退出码 $($r.ExitCode)"
                )
                $domFile = Join-Path $script:Paths.Logs 'rendered-dom.html'
                $dom | Set-Content -LiteralPath $domFile -Encoding UTF8
                Add-Result -Name '渲染结果已留档' -Ok (Test-Path $domFile) -Detail "$domFile（可用浏览器打开查看）"
            }
        } finally {
            Remove-Item $profDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===========================================================================
if (-not $SkipRestart) {
    Write-Host ''
    Write-Host '  H. 停止与重启' -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

    $stopOut = & (Join-Path $PSScriptRoot 'stop.ps1') -Port $Port 2>&1
    $stopped = -not (Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue)
    Add-Result -Name '优雅停止成功' -Ok $stopped -Detail $(
        if ($stopped) { '进程已退出' } else { '进程仍在：' + ($stopOut | Select-Object -Last 3 | Out-String).Trim() }
    )
    Add-Result -Name '停止后端口已释放' -Ok (-not (Test-PortListening -Port $Port)) -Detail "端口 $Port"

    $startOut = & (Join-Path $PSScriptRoot 'start.ps1') -Port $Port 2>&1
    $restarted = Wait-HttpOk -Url "$base/health" -TimeoutSeconds 60
    Add-Result -Name '重新启动成功' -Ok $restarted -Detail $(
        if ($restarted) { '健康检查通过' } else { ($startOut | Select-Object -Last 5 | Out-String).Trim() }
    )
} else {
    Write-Host ''
    Write-Host '  H. 停止与重启' -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray
    Add-Result -Name '停止与重启' -Ok $false -Skipped -Detail '按 -SkipRestart 跳过'
}

# ===========================================================================
$passed = @($results | Where-Object { $_.Ok -and -not $_.Skipped }).Count
$failed = @($results | Where-Object { -not $_.Ok -and -not $_.Skipped }).Count
$skipped = @($results | Where-Object { $_.Skipped }).Count

Write-Host ''
Write-Host ('  ' + ('═' * 62)) -ForegroundColor DarkGray
$conclusion = if ($failed -eq 0) { '全部通过' } else { "存在 $failed 个失败项" }
$conclusionColor = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  结论：$conclusion    通过 $passed / 跳过 $skipped / 失败 $failed / 共 $($results.Count)" -ForegroundColor $conclusionColor
Write-Host ('  ' + ('═' * 62)) -ForegroundColor DarkGray

if ($Json) {
    [pscustomobject]@{
        conclusion = $conclusion
        passed     = $passed
        failed     = $failed
        skipped    = $skipped
        total      = $results.Count
        items      = $results
    } | ConvertTo-Json -Depth 5
} else {
    # 失败项单独列出来，方便直接照着修
    if ($failed -gt 0) {
        Write-Host ''
        Write-Host '  失败项：' -ForegroundColor Red
        $results | Where-Object { -not $_.Ok -and -not $_.Skipped } | ForEach-Object {
            Write-Host "    ✗ $($_.Name)" -ForegroundColor Red
            Write-Host "      $($_.Detail)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''
    Write-Host "  管理后台  $base" -ForegroundColor Cyan
    Write-Host "  服务日志  $($script:Paths.Logs)\server.stdout.log" -ForegroundColor DarkGray
    if ($script:LogFile) { Write-Host "  验证日志  $script:LogFile" -ForegroundColor DarkGray }
    Write-Host ''
}

if ($failed -eq 0) { exit 0 } else { exit 1 }