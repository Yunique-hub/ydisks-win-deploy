# 变更日志

记录本仓库（部署工具链）的变更。
上游项目自身的变更日志见 <https://github.com/Christ9038/Ydisks-Xianyu-Helper>。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.2] - 2026-10-25

对照上游契约做全量功能验证，并把验证过程中发现的问题一起修掉。

### 新增

- **`docs/05-功能验证报告.md`** —— 对照上游唯一契约源 `api/openapi.yaml` 逐条核对：
  - **契约层**：158 个操作（117 条路径）逐个打真实请求 → **158/158 存在，0 缺失**
    （判据：版本化路由返回 401 表示已注册并受保护，返回 404 才是真缺失；
    因此**不需要管理员密码**也能验证接口完整性）
  - **页面层**：前端注册的 12 个业务路由（`/app/*`）逐个访问 → 12/12 返回 SPA 挂载点
  - **上游自测层**：`go test ./internal/server`（离线）→ 555 通过 / 1 失败，
    失败项为上**游自身的跨平台缺陷**，报告里定位到具体代码行与影响面
- **`docs/06-使用与配置手册.md`** —— 1157 行完整使用与配置手册：
  首次配置流程、功能地图（11 个菜单页 + 真实接口）、核心数据流、
  自动化规则、消息回复（关键词/默认/AI 三者关系）、卡密与发货模板、
  通知渠道、全部配置项、日常运维、风控红线、常见问题、环境变量完整清单
- **静态检查 21 → 22 项**，新增两条门禁：
  - `没有「读了但从未赋值」的变量（StrictMode 下会抛错）`
  - `使用手册覆盖全部运行期环境变量` —— 从 `app\` 源码实读
    `os.Getenv`/`os.LookupEnv`（22 个运行期变量），逐条比对手册，防文档漂移
    （只豁免 7 个纯测试/CI 专用变量）

### 修复

- **`build.ps1 -SkipFrontend -SkipGo` 直接抛错**：
  ```text
  The variable '$restartAfterBuild' cannot be retrieved because it has not been set.
  ```
  根因：该变量只在 `if (-not $SkipGo) {...}` 里赋值，而 `common.ps1` 打开了
  `Set-StrictMode -Version Latest`，两个开关都跳过时末尾读它即抛错。
  修复：在最外层预赋 `$false`；并在 `CONTRIBUTING.md` 写明这条编码约定
  （静态检查只能确定地拦「全文从未赋值」，作用域类问题靠约定）。

### 变更

- 文档索引与 CI 一致性检查同步纳入 `docs/05`、`docs/06`
- README 徽章与目录树更新（静态检查 22 项、新增两份文档）

### 验证（真实执行）

```text
契约操作          158 / 158 存在        0 缺失
前端页面           12 / 12  可达
部署完整性        30 / 30  通过
静态检查          22 / 22  通过（PS 7.6.8 与 5.1 各一遍）
公共层单元自测    17 / 17  通过
上游 server 包   555 / 556 通过（1 项为上游 Windows 路径归一化缺陷，已定位）
```

## [1.1.1] - 2026-10-25

发布后 CI 与可用性收尾。

### 修复

- **CI 首次推送被 GitHub 判为非法 workflow**：
  `Invalid workflow file: Unrecognized named-value: 'matrix'`。
  原因是 GitHub Actions 的 step 级 `shell:` 字段**不支持 matrix 上下文**
  （只有 `run` / `name` / `if` 等支持）。改为 `shell: pwsh` 固定，
  由「5.1 那一档」在 pwsh 里显式调用 `powershell.exe` 运行测试脚本，
  并用 `$LASTEXITCODE` 判定；两档各自打印解释器版本与输出编码作为证据。
- `status.ps1` / `verify.ps1` 结尾提示的日志路径由 `server.stdout.log`
  改为 `server.log` —— 1.1.0 起服务不再用重定向启动，结构化日志在后者。

### 验证

```text
GitHub Actions（windows-latest）
  PowerShell 脚本检查（5.1）: success
  PowerShell 脚本检查（7）  : success

本地
  tests\test_scripts.ps1         通过 20 / 失败 0 / 共 20
  tests\test_common_selftest.ps1 通过 17 / 失败 0 / 共 17
  deploy\verify.ps1              通过 30 / 跳过 0 / 失败 0 / 共 30
```

## [1.1.0] - 2026-10-25

「双击就报错」的彻底修复版。这一版把 5.1 兼容性从「声称支持」变成**有门禁、有证据**。

### 修复

- **★ 致命：全部 11 个 `.ps1` 是无 BOM 的 UTF-8，PowerShell 5.1 按 GBK 解码 → 语法崩**
  - 表象：简体中文 Windows 上双击 `.bat` 直接刷一屏红字，报
    `Missing closing '}' in statement block or type definition`（`start.ps1:40`）、
    `Unexpected token ')' in expression or statement`（`start.ps1:126–128`），
    并且回显的中文全是乱码 —— **报错信息完全指向错误方向**。
  - 根因：PowerShell 5.1 对有 BOM 的文件才认 UTF-8，**无 BOM 一律按系统 ANSI
    代码页解码**（简体中文机器是 936/GBK）。中文串被撕裂后，字符串字面量吞掉
    了引号与花括号，于是解析器报的是结构错误而不是编码错误。
  - 实测复现：`deploy\start.ps1` 按 936 解码后由 5.1 解析，得到与截图**逐字一致**
    的 4 条错误；加上 BOM 后同一文件 `PARSE-OK`。
  - 修复：全部脚本落 UTF-8 BOM；并把「含非 ASCII 的 `.ps1` 必须带 BOM」做成
    静态检查项 + CI 门禁，另加一条「用**真实的 PowerShell 5.1 解析器**再解析一遍」
    （只用 PS7 的 Parser 永远发现不了这类问题 —— PS7 能读无 BOM 的 UTF-8）。
  - 修复前：11 个脚本在 5.1 下**全部无法解析**。
    修复后：11 个全部通过，`start` / `stop` / `status` / `verify` 在 5.1 下实机跑通。
- **`verify.ps1` / `build.ps1` / `reset-admin.ps1`：给自动变量 `$args` 赋值**
  - `build.ps1` 在函数内赋值 `$args` 会直接抛
    `Cannot overwrite variable args because it is read-only or constant`；
    脚本级赋值则会静默破坏 `$args` 语义。统一改名为
    `$buildArgs` / `$serverArgs` / `$requestArgs`，并加静态检查项。
- **`status.ps1`：5.1 不支持内联 `if` 表达式**
  - `Write-Row '健康检查' (if (...) {...} else {...}) 'Red'` 在 5.1 下报
    `The term 'if' is not recognized as the name of a cmdlet...`。改为先落变量再传参。
- **`start.ps1`：重定向启动长驻进程导致调用方永远等不到 EOF**
  - `-RedirectStandardOutput/-RedirectStandardError` 会让服务进程继承调用者的
    stdout/stderr 句柄；服务长驻不释放 → 任何把脚本输出接进管道的调用方
    （`& .\deploy\start.ps1 2>&1 | Out-String`、CI 包装器、IDE 任务）**挂满 120 秒以上**，
    而服务其实已经起来了。
  - 修复：启动服务不再用重定向，实测 2.5 秒返回；可观测性不受影响（服务自身写
    `logs\server.log`，`verify.ps1` 的 G 段就是读它）。
  - 附：曾尝试用「一次性计划任务」做真分离（`schtasks /create` + `/run` + `/delete`），
    在非交互会话下以 `0x80004015` 失败，不可靠，已放弃并在注释中留档。
- **`stop.ps1` 的停止标记其实不被上游消费**
  - 实测「写停止标记 → 等 15 秒 → 关闭窗口 → 强杀」，服务不响应标记，
    每次停止要多等约 15–20 秒。文档中已如实记录，不再暗示是「优雅退出」。
- **`.bat` 入口的健壮性**
  - `.bat` 内容改为**纯 ASCII**（cmd 对非 ASCII 批处理的解析依赖代码页，不可靠），
    全部强制 CRLF；中文说明与输出交给 `.ps1`。
  - 启动时若失败会 `pause`，窗口不再一闪而过（此前的 `启动.bat` 无 `pause`，
    报错后直接关窗，用户看不到任何信息）。

### 新增

- **统一启动器 `deploy/run.ps1`**
  - 自动挑解释器：优先 `pwsh`（PS7），没有就回退系统自带 `powershell.exe`（5.1）
  - 固定控制台输出为 UTF-8（5.1 默认按 ANSI 输出，中文会变 `?`）
  - 透传目标脚本退出码；`-Elevate` 走 UAC 提权（装/卸载 Windows 服务用）
  - `-Pause` 供双击场景使用；无参数时打印可用脚本清单
- **ASCII 名等价入口**：`deploy.bat` / `start.bat` / `stop.bat` / `status.bat` /
  `verify.bat` / `install-service.bat`（与中文名入口行为完全一致，CI 检查成对存在）
- **`安装服务.bat`**：注册 Windows 服务的一键入口，自动请求管理员权限
- **静态检查从 14 项扩到 20 项**，其中新增的门禁直接对应上面踩过的坑：
  - `.ps1 含非 ASCII 时带 UTF-8 BOM`
  - `.ps1 换行为 LF（与 .gitattributes 一致）`
  - `全部脚本可被 Windows PowerShell 5.1 解析（.bat 实际用的解释器）`
  - `没有给自动变量赋值（$args / $input / $host ...）`
  - `没有内联 if 表达式当参数（PS7 专属，5.1 会报错）`
  - `敏感文件/生成物未被 git 跟踪`（有 `.git` 时用 `git ls-files` 实证）
  - `.bat 必须 CRLF 且纯 ASCII`
- **检查器自身 5 项「假通过」修复**：4 条规则引用了未定义的 `$lines`，
  循环一次都不执行即静默通过（`Start-Process -Wait`、字符串拼接、硬编码密码、
  PS7 专属语法）。改为逐脚本取真实代码行后逐条扫描 —— 这也是为什么这次能一次性
  把 `$args`、内联 `if` 全扫出来。
- **CI 改为 PowerShell 5.1 + 7 双版本矩阵**，并新增：批处理健康检查、
  文档与脚本一致性（README 里提到的脚本必须真的存在）、
  「敏感文件不得入库」（`data.key` / 凭据 / 数据库 / 日志 / 构建产物）。
- **仓库级文档与元数据**：`SECURITY.md`、`CONTRIBUTING.md`、
  `CODE_OF_CONDUCT.md`、Issue 模板（Bug / 功能请求）、PR 模板、
  `.github/assets/banner.svg`、全新 README（快速开始 / 坑清单 / 架构 / 兼容矩阵 /
  命令速查 / 验证证据 / 排错表）。

### 变更

- 仓库更名为 **`ydisks-win-deploy`**，定位写成一句话：
  「把 Go + React 的闲鱼多账号自动发货系统，在干净的 Windows 机器上从零跑起来」。
- README 重写：从「工具链说明」升级为「产品级门面」，坑清单加上**根因**列，
  并给出可复现的验证证据；命令速查里的硬编码工作目录改为可移植写法。

### 验证（本次全部真实执行）

```text
tests\test_scripts.ps1         通过 20 / 失败 0 / 共 20      （PS 7.6.8 与 5.1 各一遍）
tests\test_common_selftest.ps1 通过 17 / 失败 0 / 共 17      （PS 7.6.8 与 5.1 各一遍）
deploy\verify.ps1              通过 30 / 跳过 0 / 失败 0 / 共 30   （5.1 下的真实部署）
deploy\start.ps1               服务拉起 → /health 200 {"status":"ok","database":"ok"}
deploy\run.ps1 -Script start   2.5 秒返回（修复前：120 秒不返回）
```

## [1.0.0] - 2026-10-24

首次发布。把上游 `Ydisks-Xianyu-Helper v1.0.14`（commit `39e7660`）
在 Windows 上完整部署并验证通过。

### 新增

- **一键部署** `deploy/bootstrap.ps1`（九阶段）
  - 自动下载便携 Go 工具链（1.26.10）并校验官方 SHA256，装在 `runtime\go`
  - 克隆上游源码到 `app\`（已存在则增量更新）
  - 构建前端（Vite，产物写入 `internal/webui/static` 供 `//go:embed` 使用）
  - 编译三个 Go 可执行文件（server / tray / browser-install）
  - 安装 Playwright driver 与 Chromium（约 700 MB）
  - 初始化 SQLite 数据库与管理员账号
  - 启动服务并做健康检查
- **构建脚本** `deploy/build.ps1`
  - 版本号/提交号/BuildTime 注入（`xianyu-go/internal/version` 包）
  - 版本号优先取 git tag
  - 检测运行中的服务并自动停/起（Windows 不允许覆盖运行中的 exe）
  - 清理历史遗留的 `.exe~` 临时产物
- **服务管理**：`start.ps1` / `stop.ps1` / `status.ps1` / `reset-admin.ps1`
  - 停止采用三级退让：停止标记 → 关闭窗口 → 强杀
  - 状态包含进程、端口、健康检查、版本、数据库、Chromium 就绪情况
- **Windows 服务安装** `deploy/install-service.ps1`
  - 注册 `YdisksXianyuHelper` 服务，开机自启
  - 配置崩溃自动重启（10s → 30s → 60s，24 小时后重置计数）
  - 卸载不删业务数据
- **部署完整验证** `deploy/verify.ps1`（30 项，八层）
  - 产物层 / 进程层 / HTTP 层 / 鉴权层 / 业务层 / 数据层 / 浏览器层 / 收尾
  - 静态资源校验「返回的不是 index.html」（防 SPA 回退造成的假通过）
  - 浏览器层用真实 Chromium 无头渲染，断言 React 实际挂载
  - 支持 `-SkipBrowser` / `-SkipRestart` / `-Json`
- **公共层** `deploy/common.ps1`
  - 外部命令封装，带超时与进程树终止
  - Windows 参数引号处理（`ConvertTo-ArgumentString`）
  - `npm.ps1` → `npm.cmd` 路径解析（`Resolve-ExternalPath` / `Get-ToolPath`）
  - 系统代理探测、端口探测、HTTP 健康轮询、前置条件检查
- **快捷入口**：`一键部署.bat` / `启动.bat` / `停止.bat` / `状态.bat` /
  `打开后台.bat` / `验证部署.bat`
- **文档**：项目分析、部署手册、使用说明、验证报告
- **CI** `.github/workflows/ci.yml`：PowerShell 语法检查 + 脚本静态检查 + 公共层自测

### 修复（相对直接用上游脚本会踩到的坑）

| 问题 | 表现 | 处理 |
|---|---|---|
| `npm` 在 Windows 上是 `.ps1` | `Start-Process` 报「不是有效的 Win32 应用程序」 | 解析到同名 `.cmd` |
| 参数不加引号 | `-ldflags "-s -w"` 被拆开，`go build` 报 `flag provided but not defined: -w` | 按 Windows 命令行规则转义引号与末尾反斜杠 |
| 覆盖运行中的 exe | 构建「成功」但产物是旧的 + 留下 `.exe~` | 构建前停服务、清理临时产物、构建后自动重启 |
| 版本变量包路径写错 | `-X main.commit` 静默无效，版本永远 `dev` | 用 `xianyu-go/internal/version.Version/Commit/BuildTime` |
| `Start-Process -Wait` 等整棵进程树 | Chromium 留后台子进程 → 卡住 10 分钟不返回 | 加 `-TimeoutSeconds`，超时用 `taskkill /T /F` 杀进程树 |
| `Write-Log ''` 报错 | `[Parameter(Mandatory)]` 拒绝空字符串 | 加 `[AllowEmptyString()]` |
| 字符串拼接被当字面量 | `Write-Host '  ' + ('─' * 60)` 把 `+` 一起打出来 | 用括号包住整个表达式 |
| 上游冒烟工具找不到 Chromium | 服务退出 → 冒烟 90 秒超时 | 设 `PLAYWRIGHT_DRIVER_PATH` / `PLAYWRIGHT_BROWSERS_PATH` 环境变量（上游 `isolatedEnv` 会保留它们） |
| `chrome.exe --dump-dom` 不退出 | headless 下 26 秒仍未结束 | 改用 `chrome-headless-shell.exe`（0.3 秒返回） |
| Chromium 目录 junction | Chrome 报「并行配置不正确」（SxS 清单解析被破坏） | 不用 junction；需要 ASCII 路径就整个复制 |

### 己方验证脚本的修正记录

第一版 `verify.ps1` 报出的「失败」中有 5 项实际是**检查写错了**，
一并记录，因为它们也是使用这套系统时容易误判的地方：

1. 静态资源路径漏 `/static` 前缀 → 落进 SPA 回退返回 index.html，状态码仍是 200 被误判通过
2. 用 `$null -ne $obj` 判断空数组 → PowerShell 比较语义下误判为空
3. 端点名靠猜（`/api/v1/rules`、`/api/v1/dashboard` 实际不存在）→ 改从 `api/openapi.yaml` 取真实契约
4. `/api/v1/chat/sessions` 只有 DELETE 方法，被当 GET 用
5. `/api/v1/session` 响应是扁平的，被当成 `{data:{...}}` 解析

[1.1.0]: https://github.com/Yunique-hub/ydisks-win-deploy/releases/tag/v1.1.0
[1.0.0]: https://github.com/Yunique-hub/ydisks-win-deploy/releases/tag/v1.0.0