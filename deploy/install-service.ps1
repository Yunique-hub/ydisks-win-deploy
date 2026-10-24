<#
.SYNOPSIS
    把 Ydisks闲鱼助手注册成 Windows 服务（可选，需要管理员权限）。

.DESCRIPTION
    register 后服务会随系统启动自动运行，无需登录桌面、不用开着窗口。
    数据与日志仍放在本仓库的 data\ 与 logs\ 下，不发生搬迁。

    服务进程用 xianyu-server.exe -service 模式运行，由 Windows SCM 管理生命周期。

    卸载用 -Mode uninstall。卸载不会删除 data\（业务数据要留着）。

.PARAMETER Mode
    install  / uninstall / start / stop / status
.PARAMETER Port
    监听端口，默认 59188。
.PARAMETER BindAddress
    监听地址，默认 127.0.0.1。

.EXAMPLE
    # 以管理员身份运行 PowerShell
    .\deploy\install-service.ps1 -Mode install
    .\deploy\install-service.ps1 -Mode status
    .\deploy\install-service.ps1 -Mode uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'uninstall', 'start', 'stop', 'status', 'restart')]
    [string]$Mode = 'status',
    [int]$Port = 59188,
    [string]$BindAddress = '127.0.0.1'
)

. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-DeployLog -Name "service-$Mode"

$serviceName = $script:WindowsService
$serverExe = Get-ServerExe

function Test-Admin {
    <#
    .SYNOPSIS
        当前会话是否具备管理员权限。
    #>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
switch ($Mode) {
    'status' {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host ''
            Write-Host "  服务名称   $serviceName"
            Write-Host "  显示名称   $($svc.DisplayName)"
            Write-Host "  状态       $($svc.Status)"
            Write-Host "  启动类型   $($svc.StartType)"
            try {
                $wmi = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
                if ($wmi) { Write-Host "  可执行     $($wmi.PathName)" }
            } catch { }
            Write-Host ''
        } else {
            Write-Log "服务 $serviceName 未安装" -Level INFO
            Write-Log "安装：管理员 PowerShell 里运行 .\deploy\install-service.ps1 -Mode install" -Level INFO
        }
        break
    }

    'install' {
        if (-not (Test-Admin)) {
            Write-Log '安装服务需要管理员权限。请用「以管理员身份运行」打开 PowerShell 后重试。' -Level ERROR
            exit 1
        }
        if (-not $serverExe) {
            Write-Log '未构建服务，请先运行 deploy\build.ps1' -Level ERROR
            exit 1
        }
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            Write-Log "服务 $serviceName 已存在，先卸载再装" -Level WARN
            & (Join-Path $PSScriptRoot 'install-service.ps1') -Mode uninstall
        }

        # 桌面模式不要和 Windows 服务同时占着同一个端口
        if (Get-Process -Name 'xianyu-server' -ErrorAction SilentlyContinue) {
            Write-Log '检测到手工启动的服务进程，先停止以释放端口' -Level WARN
            & (Join-Path $PSScriptRoot 'stop.ps1') -Port $Port
        }

        $dbFile = Join-Path $script:Paths.Data $script:DefaultDbFile
        # binPath 里的每个参数都要带引号，含空格或中文的路径才能被 SCM 正确传递
        $binPath = '"{0}" -service -addr "{1}:{2}" -db "{3}" -workdir "{4}" -playwright-driver-dir "{5}" -playwright-browser-dir "{6}" -data-key-file "{7}"' -f `
            $serverExe, $BindAddress, $Port, $dbFile, $script:RepoRoot, `
            $script:Paths.PwDriver, $script:Paths.PwBrowsers, (Join-Path $script:Paths.Data 'data.key')

        Write-Log "创建服务 $serviceName"
        Write-Log "  使用端口   ${BindAddress}:$Port"
        Write-Log "  数据目录   $($script:Paths.Data)"

        $existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($existing) { & sc.exe delete $serviceName | Out-Null }

        & sc.exe create $serviceName binPath= $binPath start= auto `
            DisplayName= "Ydisks闲鱼助手" | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log 'sc create 失败' -Level ERROR; exit 1 }

        & sc.exe description $serviceName "Ydisks闲鱼助手 —— 闲鱼多账号自动发货与消息回复服务" | Out-Null
        # 崩溃后自动重启：第 1 次 10 秒后，之后每 30 秒
        & sc.exe failure $serviceName reset= 86400 actions= restart/10000/restart/30000/restart/60000 | Out-Null

        Write-Log '服务已创建，正在启动...' -Level INFO
        & sc.exe start $serviceName | Out-Null
        Start-Sleep -Seconds 3

        $health = Wait-HttpOk -Url "http://127.0.0.1:$Port/health" -TimeoutSeconds 90
        if ($health) {
            Write-Log "服务已启动，健康检查通过" -Level OK
            Write-Log "管理后台 http://127.0.0.1:$Port" -Level OK
        } else {
            Write-Log '服务已创建但健康检查未通过，查看 logs\server.log' -Level WARN
            Write-Log "用 .\deploy\install-service.ps1 -Mode status 查看服务状态" -Level WARN
        }
        break
    }

    'uninstall' {
        if (-not (Test-Admin)) {
            Write-Log '卸载服务需要管理员权限' -Level ERROR
            exit 1
        }
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $svc) { Write-Log "服务 $serviceName 本来就没安装" -Level INFO; exit 0 }

        if ($svc.Status -ne 'Stopped') {
            Write-Log '停止服务...' -Level INFO
            & sc.exe stop $serviceName | Out-Null
            $deadline = (Get-Date).AddSeconds(40)
            while ((Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 1
            }
        }
        & sc.exe delete $serviceName | Out-Null
        Write-Log "服务 $serviceName 已删除" -Level OK
        Write-Log "业务数据仍保留在 $($script:Paths.Data)（未删除）" -Level INFO
        break
    }

    'start' {
        if (-not (Test-Admin)) { Write-Log '需要管理员权限' -Level ERROR; exit 1 }
        & sc.exe start $serviceName | Out-Null
        Start-Sleep -Seconds 2
        if (Wait-HttpOk -Url "http://127.0.0.1:$Port/health" -TimeoutSeconds 90) {
            Write-Log '已启动，健康检查通过' -Level OK
        } else {
            Write-Log '启动后健康检查未通过' -Level WARN; exit 1
        }
        break
    }

    'stop' {
        if (-not (Test-Admin)) { Write-Log '需要管理员权限' -Level ERROR; exit 1 }
        & sc.exe stop $serviceName | Out-Null
        Write-Log '停止指令已发出' -Level OK
        break
    }

    'restart' {
        if (-not (Test-Admin)) { Write-Log '需要管理员权限' -Level ERROR; exit 1 }
        & sc.exe stop $serviceName | Out-Null
        Start-Sleep -Seconds 5
        & sc.exe start $serviceName | Out-Null
        if (Wait-HttpOk -Url "http://127.0.0.1:$Port/health" -TimeoutSeconds 90) {
            Write-Log '已重启，健康检查通过' -Level OK
        } else {
            Write-Log '重启后健康检查未通过' -Level WARN; exit 1
        }
        break
    }
}