{{ if .IsPullRequest }}

# Ydisks 闲鱼助手 · Windows 一键部署工具链
把 Go + React 的闲鱼多账号自动发货系统，在干净的 Windows 机器上从零跑起来 —— 双击一次，10–20 分钟后可用。

**核心特性**
- 一键部署：便携 Go 工具链（校验官方 SHA256）+ 上游源码 + 前端构建 + Chromium + 管理员初始化 + 健康检查
- 双击可用：六个 `.bat` 入口（中文名 + ASCII 名成对），自动挑 PowerShell 7 或回退系统自带 5.1
- 幂等可重复：每一步都能重复执行，已完成的自动跳过
- 苛刻验证：`deploy/verify.ps1` 30 项 / 八层，含真实 Chromium 无头渲染与 20 个业务接口
- 自带测试：20 项脚本静态检查（含编码门禁 + 真实 5.1 解析器）+ 17 项公共层单元自测
- 不用 Docker、不用预装 Go、不用装 MySQL/PostgreSQL，默认 SQLite，只监听 127.0.0.1

**兼容矩阵**：Windows 10/11 x64 · Windows PowerShell 5.1（系统自带）✅ · PowerShell 7+ ✅ · CI 双版本矩阵

```powershell
git clone https://github.com/Yunique-hub/ydisks-win-deploy.git
cd ydisks-win-deploy
.\一键部署.bat      # 或 .\deploy.bat
```

文档：[快速开始](README.md#快速开始) · [部署手册](docs/02-部署手册.md) · [验证报告](docs/04-验证报告.md) · [变更日志](CHANGELOG.md)

> 本仓库只做部署与运维层，不包含上游业务源码；业务问题请提到
> [上游仓库](https://github.com/Christ9038/Ydisks-Xianyu-Helper)。

{{ end -}}