# 部署脚本静态检查
#
# 检查的是「脚本写法上的隐患」，不是运行时行为 —— 这些坑在真实部署里都踩过，
# 用静态规则拦住，比每次靠人工回忆可靠。
#
# 用法：.\tests\test_scripts.ps1
# 退出码：0 全部通过；1 有失败项

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$results = New-Object System.Collections.Generic.List[object]

function Add-Check {
    <#
    .SYNOPSIS
        记录一项检查结果。
    .PARAMETER Name
        检查项名称。
    .PARAMETER Ok
        是否通过。
    .PARAMETER Detail
        证据或失败原因。
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = ''
    )
    $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}" -f $mark, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGray }
}

function Get-CodeLines {
    <#
    .SYNOPSIS
        读取脚本文件，返回「去掉注释与帮助块后的代码行」。
    .DESCRIPTION
        必须同时处理两种注释：
          * 单行注释   以 # 开头
          * 注释块     以 <# 开始、以 # 加 > 结束（注释式帮助文档就在这个块里，
            里面的示例代码会被朴素的行匹配误判成真实代码）

        注意：本说明里刻意不写出完整的注释块起止符号 —— 在注释块内部再写一次
        「结束符号」会**提前闭合当前注释块**，导致后面的代码被当作文本。
        这个坑在写这段代码时真实踩了一次。

        返回的是 [pscustomobject] 数组（含 LineNumber 与 Text）。
        调用方必须先把它取到局部变量再用，直接写 `$lines` 是另一个 bug ——
        变量不存在时 `for ($i=0; $i -lt $lines.Count; ...)` 一次都不循环，
        于是整条规则静默「通过」。本文件历史上就踩过这个坑（4 条规则假通过）。
    .PARAMETER Path
        脚本文件路径。
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = @()
    $inBlock = $false
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($inBlock) {
            if ($line -match '#>') { $inBlock = $false }
            continue
        }
        if ($line -match '<#') {
            if ($line -notmatch '#>') { $inBlock = $true }
            continue
        }
        if ($line -match '^\s*#') { continue }
        $result += [pscustomobject]@{ LineNumber = $i + 1; Text = $line }
    }
    return $result
}

function Test-HasBom {
    <#
    .SYNOPSIS
        文件是否以 UTF-8 BOM 开头。
    .PARAMETER Path
        文件路径。
    #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-IsPureAscii {
    <#
    .SYNOPSIS
        文件是否只含 ASCII 字节（纯 ASCII 不需要 BOM）。
    .PARAMETER Path
        文件路径。
    #>
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return -not ($bytes | Where-Object { $_ -gt 127 })
}

function Invoke-Ps51ParserCheck {
    <#
    .SYNOPSIS
        用 Windows PowerShell 5.1 的真实解析器检查一批脚本，返回错误行数组。
    .DESCRIPTION
        PowerShell 7 的 Parser 能把无 BOM 的 UTF-8 正常读进来，所以它**发现不了**
        「5.1 把无 BOM 的 UTF-8 当 ANSI 读」这个事故 —— 必须让真正的解释器来解析。

        这里用 -EncodedCommand（UTF-16LE + Base64）把代码递进去，绕开所有引号迷宫。
        非 Windows 上没有 powershell.exe，直接返回空数组（检查被跳过，由调用方注明）。
    .PARAMETER Paths
        脚本路径数组。
    .OUTPUTS
        字符串数组，每项形如 "name | ErrorId line N"；解析全通过时为空数组。
    #>
    param([string[]]$Paths)

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $exe)) { return @() }

    # 把路径列表内联成 PS 数组字面量（单引号转义成两个单引号）
    $quoted = ($Paths | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $payload = @"
`$bad = @()
foreach (`$f in @($quoted)) {
    `$e = `$null; `$t = `$null
    [void][System.Management.Automation.Language.Parser]::ParseFile(`$f, [ref]`$t, [ref]`$e)
    if (`$e.Count -gt 0) {
        `$bad += ((Split-Path -Leaf `$f) + ' | ' + `$e[0].ErrorId + ' line ' + `$e[0].Extent.StartLineNumber)
    }
}
`$bad -join "`n"
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    # 2>$null：5.1 的 CLIXML 进度流不应该污染判定
    $out = & $exe -NoProfile -NonInteractive -EncodedCommand $encoded 2>$null
    $bad = @($out | Where-Object { $_ -and ([string]$_).Trim() -ne '' })
    return $bad
}

Write-Host ''
Write-Host '  Ydisks闲鱼助手 · 部署脚本静态检查' -ForegroundColor White
Write-Host ('  ' + ('─' * 62)) -ForegroundColor DarkGray

# 排除 schema 自身：检查器里写的规则字符串（正则、示例）会被自己的规则命中，
# 这是典型的「自检误报」。只检查被检查对象。
$scripts = Get-ChildItem -Path 'deploy', 'tests' -Recurse -Filter '*.ps1' |
    Where-Object { $_.Name -notlike '_*' -and $_.Name -ne 'test_scripts.ps1' }
Add-Check -Name '找到部署脚本' -Ok ($scripts.Count -ge 9) -Detail "$($scripts.Count) 个"

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  1. 语法与编码（★ 本次事故的根因）' -ForegroundColor Cyan

# 1.1 UTF-8 BOM：Windows PowerShell 5.1 对**无 BOM 的 .ps1** 会按系统 ANSI
#     代码页（简体中文机器是 936/GBK）解码。中文串被撕裂后连语法都会崩，
#     报出来的是 "Missing closing '}'" / "Unexpected token ')'" 这种看不懂的错。
#     纯 ASCII 脚本不需要 BOM；含非 ASCII 的必须带，否则 5.1 起不来。
$noBom = @()
$asciiOnly = @()
foreach ($s in $scripts) {
    if (Test-HasBom -Path $s.FullName) { continue }
    if (Test-IsPureAscii -Path $s.FullName) { $asciiOnly += $s.Name; continue }
    $noBom += $s.Name
}
Add-Check -Name '.ps1 含非 ASCII 时带 UTF-8 BOM（5.1 才认）' -Ok ($noBom.Count -eq 0) `
    -Detail $(if ($noBom) {
        "缺少 BOM：$($noBom -join ', ')（否则 PowerShell 5.1 按 ANSI 解码 → 语法崩）"
    } else {
        "$($scripts.Count) 个脚本全部符合（纯 ASCII $($asciiOnly.Count) 个不要求）"
    })

# 1.2 换行统一 LF：仓库级 .gitattributes 声明了 * text=auto eol=lf，
#     文件里混用 CRLF 会让每次 diff 都整文件重写（历史上混用过）。
$crlf = @()
foreach ($s in $scripts) {
    $text = [System.IO.File]::ReadAllText($s.FullName)
    # 有 CRLF 但 LONE LF 一个都没有 → 整文件是 CRLF，与 .gitattributes 冲突
    $crlfCount = ([regex]::Matches($text, "\r\n")).Count
    $lfCount = ([regex]::Matches($text, "(?<!\r)\n")).Count
    if ($crlfCount -gt 0 -and $lfCount -eq 0) { $crlf += $s.Name }
}
Add-Check -Name '.ps1 换行为 LF（与 .gitattributes 一致）' -Ok ($crlf.Count -eq 0) `
    -Detail $(if ($crlf) { "整文件 CRLF：$($crlf -join ', ')" } else { '全部 LF' })

# 1.3 PowerShell 7 的 Parser 检查（语法本身）
$syntaxBad = @()
foreach ($s in $scripts) {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors -and $errors.Count -gt 0) {
        $syntaxBad += "$($s.Name): $($errors[0].Message) (行 $($errors[0].Extent.StartLineNumber))"
    }
}
Add-Check -Name '全部脚本可被 PowerShell 解析' -Ok ($syntaxBad.Count -eq 0) -Detail $(
    if ($syntaxBad.Count -eq 0) { "$($scripts.Count) 个脚本" } else { $syntaxBad -join '; ' }
)

# 1.4 用真实的 Windows PowerShell 5.1 再解析一遍 —— 这是 .bat 入口实际使用的解释器。
#     只跑 7 的 Parser 会漏掉整个编码类问题（7 能读无 BOM 的 UTF-8）。
$ps51Bad = Invoke-Ps51ParserCheck -Paths ($scripts | ForEach-Object { $_.FullName })
if ($PSVersionTable.PSEdition -eq 'Core' -and (Test-Path (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))) {
    Add-Check -Name '全部脚本可被 Windows PowerShell 5.1 解析（.bat 实际用的解释器）' `
        -Ok ($ps51Bad.Count -eq 0) -Detail $(if ($ps51Bad.Count -eq 0) { '真实 5.1 解析器：全部通过' } else { $ps51Bad -join '; ' })
} else {
    Add-Check -Name '全部脚本可被 Windows PowerShell 5.1 解析' -Ok $true -Detail '当前会话不是 PS7 或无 5.1，已跳过'
}

# 1.5 StrictMode 下的「读了但从未赋值」。
#     common.ps1 打开 Set-StrictMode -Version Latest，读一个不存在的变量会**抛错**
#     而不是返回 $null。真实踩过：build.ps1 把 $restartAfterBuild 只在
#     `if (-not $SkipGo) {...}` 里赋值，用 -SkipFrontend -SkipGo 跑时末尾读它 →
#     "The variable '$restartAfterBuild' cannot be retrieved because it has not been set"。
#
#     注：那条具体缺陷的完整检测需要作用域分析（该变量在别处确实有赋值），
#     静态文本层面无法可靠判定，故这里只做**能确定**的一类：
#     被读取但整个文件里从未出现过赋值的变量名（排除自动变量、参数、
#     StrictMode 预置变量与常见环境变量）。
#     其余同类风险请靠「顶格预赋默认值」的编码约定，见 CONTRIBUTING.md。
$builtinVars = @(
    'args', 'input', 'error', 'host', 'home', 'pid', 'pwd', 'matches', 'lastexitcode',
    'psitem', 'psscriptroot', 'pscommandpath', 'myinvocation', 'executioncontext',
    'profile', 'stacktrace', 'shellid', 'true', 'false', 'null', 'this', '_',
    'env', 'script', 'global', 'local', 'private', 'using', 'psversiontable',
    'psedition', 'pshome', 'psculture', 'psuiculture', 'psdefaultparametervalues',
    'iswindows', 'islINUX', 'ismacos', 'isMacOS', 'isasCore', 'verbose', 'debug',
    'informationpreference', 'progresspreference', 'warningpreference',
    'erroractionpreference', 'verbosepreference', 'debugpreference',
    'whatifpreference', 'confirmpreference', 'outputencoding', 'maximumhistorycount',
    'nestedpromptlevel', 'formatenumerationlimit', 'psmodulepath', 'consoleencoding'
)
$neverAssigned = @()
foreach ($s in $scripts) {
    $text = [System.IO.File]::ReadAllText($s.FullName)
    # 参数声明（param 块里 $Name = 形式已经是赋值；这里再忽略 [type]$Name 形式）
    $declared = @{}
    foreach ($m in [regex]::Matches($text, '(?m)\$([A-Za-z_][A-Za-z0-9_]*)\s*(?:=[^=]|\))')) {
        $declared[$m.Groups[1].Value] = $true
    }
    foreach ($m in [regex]::Matches($text, '(?m)\[.*?\]\$([A-Za-z_][A-Za-z0-9_]*)')) {
        $declared[$m.Groups[1].Value] = $true
    }
    # foreach / ForEach-Object -Begin 等循环变量也是赋值
    foreach ($m in [regex]::Matches($text, '(?i)foreach\s*\(\s*\$([A-Za-z_][A-Za-z0-9_]*)')) {
        $declared[$m.Groups[1].Value] = $true
    }
    foreach ($m in [regex]::Matches($text, '(?i)\b(?:for|trap)\b')) { }
    foreach ($v in @([regex]::Matches($text, '(?m)\$([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object { $_.Groups[1].Value })) {
        if ($declared.ContainsKey($v) -or $builtinVars -contains $v.ToLowerInvariant()) { continue }
        $neverAssigned += "$($s.Name):\$$v"
    }
}
$neverAssigned = @($neverAssigned | Select-Object -Unique)
Add-Check -Name '没有「读了但从未赋值」的变量（StrictMode 下会抛错）' `
    -Ok ($neverAssigned.Count -eq 0) `
    -Detail $(if ($neverAssigned) { return "疑似未赋值：$($neverAssigned -join ', ')" } else { '未发现' })

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  2. 已知陷阱（这些坑都真实踩过）' -ForegroundColor Cyan

$fileViolations = @{}
$addViolation = {
    param([string]$Rule, [string]$Where)
    if (-not $fileViolations.ContainsKey($Rule)) { $fileViolations[$Rule] = New-Object System.Collections.Generic.List[string] }
    $fileViolations[$Rule].Add($Where)
}

foreach ($s in $scripts) {
    # 每个脚本先取出「真实代码行」，逐条规则扫一遍。
    # ★ 必须在这里就地取 $codeLines：以前写成未定义的 $lines 导致 4 条规则全部假通过。
    $codeLines = Get-CodeLines -Path $s.FullName
    foreach ($l in $codeLines) {
        # (a) 不允许把 GitHub 表达式误写进 PowerShell（会当字面量）
        if ($l.Text -match '\$\{\{') { & $addViolation 'ghExpr' "$($s.Name):$($l.LineNumber)" }

        # (b) 不允许直接用 (Get-Command xxx).Source 拼 Start-Process ——
        #     Windows 上 npm 会解析成 npm.ps1，Start-Process 无法执行
        if ($s.Name -ne 'common.ps1' -and $l.Text -match '\(Get-Command\s+\w+\)\.Source') {
            & $addViolation 'directSource' "$($s.Name):$($l.LineNumber)"
        }

        # (c) Start-Process -Wait 不允许用于可能派生子孙进程的程序 —— 会永远等下去
        if ($l.Text -match 'Start-Process[^\n]*-Wait') { & $addViolation 'bareWait' "$($s.Name):$($l.LineNumber)" }

        # (d) Write-Host 里的 '  ' + (...) 必须加括号，否则 '+' 会被当字面量打出来
        if ($l.Text -match "Write-Host\s+'[^']*'\s*\+\s*\(") { & $addViolation 'bareConcat' "$($s.Name):$($l.LineNumber)" }

        # (e) 不允许硬编码密码（赋值给 *assword 变量且是长字面量）
        if ($l.Text -match '(?i)\$[a-z0-9_]*assword\s*=\s*''[^'']{8,}''') {
            & $addViolation 'hardPwd' "$($s.Name):$($l.LineNumber)"
        }

        # (f) 不允许给 PowerShell 自动变量赋值：$args / $input / $error / $host / $home ...
        #     真踩过：build.ps1 用 $args 装 go build 参数 → 抛 "Cannot overwrite variable args"。
        #     PowerShell 变量名不区分大小写，所以这里也做大小写归一。
        if ($l.Text -match '(?i)^\s*\$(args|input|error|host|home|pid|psitem|matches|lastexitcode|psscriptroot|myinvocation|executioncontext|pwd|shellid|profile|stacktrace)\s*=[^=]') {
            & $addViolation 'autoVar' "$($s.Name):$($l.LineNumber)"
        }

        # (g) 不允许内联 if 表达式当命令参数 —— (if (...) {..} else {..}) 是 PS7 专属，
        #     5.1 会把它当命令名调用，报 "The term 'if' is not recognized"。
        #     合法写法是存到变量里，或写成 $(if ...) 子表达式（$ 开头，正则不匹配）。
        if ($l.Text -match '(^\s*|\s|[=(,])\(if\s*\(') { & $addViolation 'inlineIf' "$($s.Name):$($l.LineNumber)" }

        # (h) 不允许使用 PS7 专属语法
        if ($l.Text -match 'ForEach-Object\s+-Parallel') { & $addViolation 'ps7Only' "$($s.Name):$($l.LineNumber)(-Parallel)" }
        if ($l.Text -match '\?\?=') { & $addViolation 'ps7Only' "$($s.Name):$($l.LineNumber)(??=)" }
        if ($l.Text -match '\?\.') { & $addViolation 'ps7Only' "$($s.Name):$($l.LineNumber)(?.)" }
        if ($l.Text -match '&&|\|\|') { & $addViolation 'ps7Only' "$($s.Name):$($l.LineNumber)(&& / ||)" }
    }
}

function Get-RuleDetail {
    param([string]$Rule, [string]$OkText = '无')
    if ($fileViolations.ContainsKey($Rule)) { return ($fileViolations[$Rule] -join ', ') }
    return $OkText
}

Add-Check -Name '没有误写 GitHub 表达式 ${{ }}' -Ok (-not $fileViolations.ContainsKey('ghExpr')) `
    -Detail (Get-RuleDetail 'ghExpr')
Add-Check -Name '没有直接使用 (Get-Command x).Source（应走 Get-ToolPath）' `
    -Ok (-not $fileViolations.ContainsKey('directSource')) -Detail (Get-RuleDetail 'directSource')
Add-Check -Name '没有裸用 Start-Process -Wait（应带超时）' `
    -Ok (-not $fileViolations.ContainsKey('bareWait')) -Detail (Get-RuleDetail 'bareWait')
Add-Check -Name "Write-Host 字符串拼接已加括号" `
    -Ok (-not $fileViolations.ContainsKey('bareConcat')) -Detail (Get-RuleDetail 'bareConcat')
Add-Check -Name '没有硬编码密码' `
    -Ok (-not $fileViolations.ContainsKey('hardPwd')) -Detail (Get-RuleDetail 'hardPwd')
Add-Check -Name '没有给自动变量赋值（$args / $input / $host ...）' `
    -Ok (-not $fileViolations.ContainsKey('autoVar')) -Detail (Get-RuleDetail 'autoVar')
Add-Check -Name '没有内联 if 表达式当参数（PS7 专属，5.1 会报错）' `
    -Ok (-not $fileViolations.ContainsKey('inlineIf')) -Detail (Get-RuleDetail 'inlineIf')

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  3. 结构约定' -ForegroundColor Cyan

# 每个脚本都必须 dot-source common.ps1（除 common 自身）
$noCommon = @()
foreach ($s in $scripts) {
    if ($s.Name -eq 'common.ps1') { continue }
    $txt = Get-Content -LiteralPath $s.FullName -Raw -Encoding UTF8
    if ($txt -notmatch 'common\.ps1') { $noCommon += $s.Name }
}
Add-Check -Name '除 common.ps1 外都引用了公共层' -Ok ($noCommon.Count -eq 0) `
    -Detail $(if ($noCommon) { $noCommon -join ', ' } else { '全部引用' })

# 每个脚本都要有 .SYNOPSIS（便于 Get-Help）
$noSynopsis = @()
foreach ($s in $scripts) {
    $txt = Get-Content -LiteralPath $s.FullName -Raw -Encoding UTF8
    if ($txt -notmatch '\.SYNOPSIS') { $noSynopsis += $s.Name }
}
Add-Check -Name '全部脚本带 .SYNOPSIS 注释块' -Ok ($noSynopsis.Count -eq 0) `
    -Detail $(if ($noSynopsis) { $noSynopsis -join ', ' } else { '全部具备' })

Add-Check -Name '未使用 PowerShell 7 专属语法' -Ok (-not $fileViolations.ContainsKey('ps7Only')) `
    -Detail (Get-RuleDetail 'ps7Only' '兼容 5.1')

# 危险目录操作必须限定在本仓库内
$dangerous = @()
foreach ($s in $scripts) {
    foreach ($l in (Get-CodeLines -Path $s.FullName)) {
        # 形如 Remove-Item C:\ -Recurse 之类的绝对路径删除
        if ($l.Text -match 'Remove-Item\s+["'']?[A-Za-z]:\\\\?["'']?\s' -or
            $l.Text -match 'Remove-Item\s+["'']?[/\\]["'']?\s') {
            $dangerous += "$($s.Name):$($l.LineNumber)"
        }
    }
}
Add-Check -Name '没有危险的根目录删除操作' -Ok ($dangerous.Count -eq 0) `
    -Detail $(if ($dangerous) { $dangerous -join ', ' } else { '无' })

# 3.5 文档漂移防护：凡是用 ``os.Getenv("X")`` 读的环境变量，使用手册必须提到 X。
#     真实踩过：手册第 9 章自称「全部可配置项」，但与源码实际读取的 28 个变量对不上，
#     漏了 XIANYU_LOG_DIR / BROWSER_HEADLESS 这类真实会用的项。
#     规则：允许清单（纯测试/CI 专用等）可以豁免，其余必须出现在手册里。
$manualPath = 'docs\06-使用与配置手册.md'
if (Test-Path $manualPath) {
    $envAllowlist = @(
        # 纯测试/CI 专用，故意不写进使用者手册
        'RUN_BROWSER_INTEGRATION', 'TEST_MYSQL_URL', 'TEST_POSTGRES_URL',
        'TEST_XIANYU_DB_URL', 'TEST_XIANYU_ACCOUNT_ID', 'TEST_XIANYU_LIVE',
        'PROGRAMDATA'
    )
    $srcEnv = @()
    Get-ChildItem -Path 'app\internal', 'app\cmd' -Recurse -Include '*.go' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '_test\.go$' } | ForEach-Object {
            $goText = [System.IO.File]::ReadAllText($_.FullName)
            foreach ($m in [regex]::Matches($goText, 'os\.(?:Getenv|LookupEnv)\("([A-Z0-9_]+)"\)')) {
                $srcEnv += $m.Groups[1].Value
            }
        }
    $srcEnv = @($srcEnv | Sort-Object -Unique)
    if ($srcEnv.Count -eq 0) {
        Add-Check -Name '环境变量文档一致性' -Ok $true -Detail '未找到 app\ 源码（可能未部署上游），已跳过'
    } else {
        $manualText = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($manualPath))
        $undocumented = @($srcEnv | Where-Object { $envAllowlist -notcontains $_ -and $manualText -notmatch [regex]::Escape($_) })
        Add-Check -Name "使用手册覆盖全部运行期环境变量（源码实读 $($srcEnv.Count) 个）" `
            -Ok ($undocumented.Count -eq 0) `
            -Detail $(if ($undocumented) {
                "手册未提及：$($undocumented -join ', ')"
            } else {
                "已覆盖（豁免纯测试变量 $($envAllowlist.Count) 个）"
            })
    }
} else {
    Add-Check -Name '环境变量文档一致性' -Ok $true -Detail '缺少 docs\06-使用与配置手册.md，已跳过'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '  4. 仓库卫生' -ForegroundColor Cyan

$gitignore = Get-Content -LiteralPath '.gitignore' -Raw -Encoding UTF8
$needIgnore = @('app/', 'runtime/', 'data/', 'logs/')
$missing = @($needIgnore | Where-Object { $gitignore -notmatch [regex]::Escape($_) })
Add-Check -Name '.gitignore 覆盖生成物目录' -Ok ($missing.Count -eq 0) `
    -Detail $(if ($missing) { "缺少：$($missing -join ', ')" } else { 'app/ runtime/ data/ logs/ 均已忽略' })

# data.key 与凭据文件必须被忽略
$secretIgnored = ($gitignore -match 'data\.key') -and ($gitignore -match '初始管理员凭据')
Add-Check -Name '.gitignore 覆盖敏感文件' -Ok $secretIgnored `
    -Detail $(if ($secretIgnored) { 'data.key 与凭据文件均已忽略' } else { '缺少 data.key 或凭据文件的忽略规则' })

# 敏感文件真的没被跟踪（有 .git 才检查）—— 光有 .gitignore 规则不够，
# 一旦被 add 过就再也不生效了。
if (Test-Path '.git') {
    $tracked = @(& git ls-files 2>$null)
    $leaked = @($tracked | Where-Object { $_ -match 'data\.key|初始管理员凭据|\.db$|\.exe$|app/|runtime/|logs/' })
    Add-Check -Name '敏感文件/生成物未被 git 跟踪' -Ok ($leaked.Count -eq 0) `
        -Detail $(if ($leaked) { $leaked -join ', ' } else { "已跟踪 $($tracked.Count) 个文件，无敏感项" })
} else {
    Add-Check -Name '敏感文件/生成物未被 git 跟踪' -Ok $true -Detail '未初始化 git，跳过'
}

# .bat 必须是 CRLF（cmd.exe 对 LF-only 的批处理解析不可靠）+ 纯 ASCII（防代码页错乱）
$batBad = @()
$batFiles = Get-ChildItem -Filter '*.bat'
foreach ($b in $batFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($b.FullName)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $bareLf = ([regex]::Matches($text, "(?<!`r)`n")).Count
    if ($bareLf -gt 0) { $batBad += "$($b.Name)($bareLf 个裸 LF)" }
    if ($bytes | Where-Object { $_ -gt 127 }) { $batBad += "$($b.Name)(含非 ASCII)" }
}
Add-Check -Name '批处理均为 CRLF 且纯 ASCII' -Ok ($batBad.Count -eq 0) `
    -Detail $(if ($batBad) { $batBad -join ', ' } else { "全部 $($batFiles.Count) 个" })

# ---------------------------------------------------------------------------
$passed = @($results | Where-Object { $_.Ok }).Count
$failed = @($results | Where-Object { -not $_.Ok }).Count

Write-Host ''
Write-Host ('  ' + ('═' * 62)) -ForegroundColor DarkGray
$color = if ($failed -eq 0) { 'Green' } else { 'Red' }
Write-Host "  检查结论：通过 $passed / 失败 $failed / 共 $($results.Count)" -ForegroundColor $color
Write-Host ('  ' + ('═' * 62)) -ForegroundColor DarkGray

if ($failed -gt 0) {
    Write-Host ''
    $results | Where-Object { -not $_.Ok } | ForEach-Object {
        Write-Host "  ✗ $($_.Name)" -ForegroundColor Red
        Write-Host "    $($_.Detail)" -ForegroundColor DarkGray
    }
    exit 1
}
Write-Host ''
exit 0