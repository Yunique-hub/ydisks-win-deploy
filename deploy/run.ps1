<#
.SYNOPSIS
    统一启动器：让根目录的 .bat 入口在所有 Windows 上都跑得起来（含中文不乱的保证）。

.DESCRIPTION
    六个 .bat 入口全部转调本脚本，由本脚本负责三件事：

      1. **挑解释器** —— 优先 PowerShell 7（pwsh，启动快、原生 UTF-8），
         没有就回退 Windows PowerShell 5.1（系统自带，无需安装）。
         上游脚本全部保持 5.1 兼容，两条路径都必须能跑。

      2. **修输出编码** —— 5.1 的管道输出默认走系统 ANSI 代码页（简体中文机器
         是 936/GBK），中文会被打成 '?'。dot-source common.ps1 里的
         Set-Utf8Console 把控制台与 $OutputEncoding 都固定成 UTF-8。

      3. **透传退出码** —— 目标脚本的退出码原样返回给 .bat / 调用方，
         CI 与人工排查都能拿到真实结果。

    脚本自身也刻意保持「ASCII 安全」：即使它被以无 BOM 的方式读入，
    语法结构里也不含非 ASCII 字符，不会崩。

.PARAMETER Script
    目标脚本名（deploy 目录下），如 start / status / verify。
    省略时只打印可用清单。

.PARAMETER Arguments
    透传给目标脚本的参数，例如 -Arguments '-Port','8080'。

.PARAMETER Pause
    目标脚本结束后等待回车。给双击场景用：窗口不会一闪而过，
    失败信息能被看到。

.PARAMETER Elevate
    以管理员权限重新拉起（UAC 提权）。注册 Windows 服务需要。

.EXAMPLE
    .\deploy\run.ps1 -Script status -Pause
    .\deploy\run.ps1 -Script start -Arguments '-Port','8080'
    .\deploy\run.ps1 -Script install-service -Arguments '-Mode','install' -Elevate -Pause
#>
[CmdletBinding()]
param(
    [string]$Script = '',
    [string[]]$Arguments = @(),
    [switch]$Pause,
    [switch]$Elevate
)

$ErrorActionPreference = 'Stop'

$deployDir = $PSScriptRoot
. (Join-Path $deployDir 'common.ps1')
Set-Utf8Console

# ---------------------------------------------------------------------------
# 定位出真正的 .ps1（带 -Script start.ps1 也能用）
$targetPath = $null
if ($Script) {
    $name = if ([System.IO.Path]::GetExtension($Script)) { $Script } else { "$Script.ps1" }
    $candidate = Join-Path $deployDir $name
    if (-not (Test-Path -LiteralPath $candidate)) {
        Write-Host ''
        Write-Host "  [x] 找不到脚本：$name" -ForegroundColor Red
        Write-Host "      可用：$((Get-ChildItem -LiteralPath $deployDir -Filter '*.ps1' |
            Where-Object { $_.Name -ne 'common.ps1' -and $_.Name -ne 'run.ps1' } |
            ForEach-Object { $_.BaseName }) -join ', ')" -ForegroundColor DarkGray
        Write-Host ''
        exit 2
    }
    $targetPath = (Resolve-Path -LiteralPath $candidate).Path
}

# ---------------------------------------------------------------------------
# 提权分支：用 UAC 重新拉起自己，参数原样带过去
#   * 不用 $args（自动变量，赋值会失败），显式拼参数数组
#   * 目标机器可能是 5.1，所以提权时统一走 powershell.exe
#   * -EncodedCommand 避免路径与参数里的引号被层层吃掉
if ($Elevate -and $targetPath) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host ''
        Write-Host '  需要管理员权限，正在请求 UAC 提权（会弹一个确认框）...' -ForegroundColor Yellow
        $inner = @(
            '$ErrorActionPreference = ''Stop''',
            ". '$($MyInvocation.MyCommand.Path)' -Script '$([System.IO.Path]::GetFileName($targetPath))'"
        )
        if ($Arguments.Count -gt 0) {
            $quoted = $Arguments | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }
            $inner[-1] += ' -Arguments ' + ($quoted -join ',')
        }
        if ($Pause) { $inner[-1] += ' -Pause' }
        $inner += 'if ($LASTEXITCODE -ne $null) { exit $LASTEXITCODE }'
        $code = $inner -join '; '
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $p = Start-Process -FilePath $exe -Verb RunAs -PassThru `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        $p.WaitForExit()
        exit $p.ExitCode
    }
}

# ---------------------------------------------------------------------------
# 无目标：打印可用清单
if (-not $targetPath) {
    Write-Host ''
    Write-Host '  Ydisks闲鱼助手 · 部署脚本启动器' -ForegroundColor White
    Write-Host ('  ' + ('-' * 58)) -ForegroundColor DarkGray
    Get-ChildItem -LiteralPath $deployDir -Filter '*.ps1' |
        Where-Object { $_.Name -notin @('common.ps1', 'run.ps1') } |
        Sort-Object Name | ForEach-Object {
            $synopsis = (Select-String -LiteralPath $_.FullName -Pattern '^\.SYNOPSIS' -Context 0, 1 |
                Select-Object -First 1).Context.PostContext
            $text = if ($synopsis) { ([string]$synopsis).Trim() } else { '' }
            Write-Host ("  {0,-20} {1}" -f $_.BaseName, $text)
        }
    Write-Host ''
    Write-Host '  用法：.\deploy\run.ps1 -Script status -Pause' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------
# 解释器自述：排查"到底用哪个 PowerShell 跑的"这类问题时，这一行就是证据
$edition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
Write-Host ("  PowerShell {0}（{1}）" -f $PSVersionTable.PSVersion.ToString(), $edition) `
    -ForegroundColor DarkGray

$global:LASTEXITCODE = 0
& $targetPath @Arguments
$rc = $LASTEXITCODE
if ($null -eq $rc) { $rc = 0 }

if ($Pause) {
    Write-Host ''
    Write-Host '  按回车关闭窗口...' -ForegroundColor DarkGray
    [void](Read-Host)
}
exit $rc