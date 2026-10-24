---
name: Bug 报告
about: 部署脚本报错、行为不符合预期
title: '[Bug] '
labels: ['bug']
assignees: ''
---

> **请附上脱敏后的真实输出。** 没有真实输出的 issue 基本无法排查 ——
> 本仓库的坑大多是「报错信息指向错误方向」（例如无 BOM 的 UTF-8 会报成 `Missing closing '}'`）。

## 环境

请在 PowerShell 里执行下面两段，把输出贴进来：

```powershell
$PSVersionTable | Format-List
[System.Environment]::OSVersion.Version.ToString()
```

| 项 | 值 |
|---|---|
| Windows 版本 |  |
| PowerShell 版本 / 版次 |  |
| 用的是哪个入口 | 中文名 `.bat` / ASCII 名 `.bat` / 直接调 `.ps1` |
| 本仓库 commit | `git rev-parse --short HEAD` |
| 上游 commit（如相关） | `git -C app rev-parse --short HEAD` |

## 复现步骤

1.
2.
3.

## 期望结果

## 实际结果

```text
（粘贴完整报错。脱敏：去掉用户名、个人路径、数据库内容、任何凭据）
```

## 你已经试过的

- [ ] `.\tests\test_scripts.ps1`
- [ ] `.\tests\test_common_selftest.ps1`
- [ ] `.\deploy\status.ps1 -Json`
- [ ] `.\deploy\start.ps1 -Foreground`（如果问题出在启动阶段）
- [ ] `logs\server.log` 尾部的相关片段（已脱敏）

## 其它信息

<!-- 是否改过监听地址/端口、是否放宽过 MTOP 节流、是否有代理、是否装过 Windows 服务 -->