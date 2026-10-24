# 贡献指南

欢迎提交 issue 与 PR。本仓库只做**部署与运维层**，上游业务代码的问题请提到
[上游仓库](https://github.com/Christ9038/Ydisks-Xianyu-Helper)。

## 提交 PR 前必须做的三件事

```powershell
# 1) 脚本静态检查（20 项，含编码门禁与真实 5.1 解析器）
.\tests\test_scripts.ps1

# 2) 公共层单元自测（17 项）
.\tests\test_common_selftest.ps1

# 3) 如果你改动了启动/停止/构建逻辑，跑一次完整验证（需要已部署）
.\deploy\verify.ps1 -Password '<你的管理员密码>'
```

三条都通过再提 PR。CI 会在 **Windows PowerShell 5.1 与 PowerShell 7 两个版本**上
各跑一遍前两项 —— 请确保你的改动在两个版本下都成立。

## 硬性约定（踩过坑才写进来的）

1. **`.ps1` 含非 ASCII 就必须带 UTF-8 BOM。**
   无 BOM 的 UTF-8 在简体中文 Windows 上会被 PowerShell 5.1 按 GBK 解码，
   中文串撕裂后报出的语法错误完全指向错误方向（`Missing closing '}'`）。
   静态检查会拦下，但请在编辑器里就设成「UTF-8 with BOM」。
2. **保持 PowerShell 5.1 语法兼容。**
   不许用 PS7 专属语法：`(if ...)` 内联表达式、`??=`、`?.`、`&&` / `||`、
   `ForEach-Object -Parallel`。`.bat` 入口实际用的就是 5.1。
3. **不要给自动变量赋值**（`$args`、`$input`、`$host`、`$error`、`$home` …）。
4. **外部命令统一走 `Invoke-External`**，需要引号时用 `ConvertTo-ArgumentString`；
   需要命令路径时用 `Get-ToolPath`（它会避开 `npm.ps1` 这种不可执行的形式）。
5. **长驻进程不要用重定向启动。**
   `-RedirectStandardOutput/-RedirectStandardError` 会把输出句柄继承给子进程，
   任何把脚本输出接进管道的调用方都会永远等不到 EOF（表现为「服务起来了但像卡死」）。
6. **`.bat` 必须 CRLF + 纯 ASCII。** cmd 对非 ASCII 批处理的解析依赖代码页，不可靠。
   中文说明放在 `.ps1` 里输出。
7. **不创建 git commit / 不 push**，除非维护者明确要求。
8. **敏感物永不入库**：任何密钥、凭据、数据库、日志、构建产物。
   新增生成目录时同步更新 `.gitignore` 与 `tests\test_scripts.ps1` 的卫生检查。
9. **`Set-StrictMode -Version Latest` 下的变量必须先赋值再读。**
   `common.ps1` 打开了 strict mode，读一个「只在某个条件分支里赋值过」的变量会
   **抛错**而不是返回 `$null`。真实踩过：`build.ps1` 的 `$restartAfterBuild`
   只在 `if (-not $SkipGo) {...}` 里赋值，用 `-SkipFrontend -SkipGo` 跑时末尾读它 →
   `The variable '$restartAfterBuild' cannot be retrieved because it has not been set`。
   **约定：凡是会在多个分支之间共享的变量，在最外层先赋默认值。**
   （静态检查只能确定地拦「读了但全文从未赋值」，作用域类问题靠这条约定。）

## 代码风格

- 缩进 4 空格；`.ps1` / `.bat` 用 LF，`.bat` 例外（要 CRLF，见上）
- 函数必须带 `.SYNOPSIS` 注释块，方便 `Get-Help`
- 每一步都要能把「为什么这么写」写进注释 —— 注释解释**坑**，不解释语法
- 用户可见的输出用中文；日志级别用 `INFO / OK / WARN / ERROR / STEP`
- 改完记得同步文档：`README.md`、`docs/`、`CHANGELOG.md`

## CHANGELOG 约定

每次带用户可见行为的改动都往 [CHANGELOG.md](CHANGELOG.md) 加一节，写清：

- 改了什么（新增 / 修复 / 变更）
- **根因**是什么（尤其是那些报错信息会误导人的问题）
- 怎么验证的（命令 + 真实输出摘要）

## Issue 模板

提交 issue 请带上：`$PSVersionTable.PSVersion`、Windows 版本、
执行的命令、**脱敏后的**完整报错。中文名入口与 ASCII 名入口（如
`一键部署.bat` / `deploy.bat`）行为一致，哪个方便用哪个。