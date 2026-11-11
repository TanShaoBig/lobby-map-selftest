# 联机大厅地图自测工具 · LobbyMapSelfTest

面向 Minecraft 网易版（MC Studio）**联机大厅地图**的 Windows 打包、上传自测与状态查询工具。关键词：联机大厅地图自测、地图打包、自测上传、Cookie 配置、打包剔除规则。

它可以：

- 把地图工程打包为联机大厅可上传的 ZIP（默认 `map/` 顶级目录）；
- 按清单自动替换每个 `manifest.json` 的包头与模块 UUID，并同步内部依赖和 `world_*_packs.json`；
- 自定义**打包剔除规则**（`*`、`**`、`?`、`!` 反选），不再写死 `.pyc` / `__pycache__` / `.gitignore`；
- 在本地配置中保存**联机大厅组件 ID**（开发者平台项目 `item_id`）与 **Cookie**；
- Cookie 使用 Windows DPAPI 以当前用户加密，明文不落盘、不进日志；
- 一键完成“打包 → 上传 → 更新资源 → 申请自测 → 等待就绪”；
- 查询状态、取消旧自测、断点式核对上次未决任务（不自动重放写入请求）。

> 这是社区工具，不是网易官方工具，与网易、MC Studio、QuMod 官方无隶属关系。使用前请先在测试项目验证，并自行承担账号与平台操作风险。

[English overview](README.en.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D4.svg)](#系统要求)

---

## 特性

| 能力 | 说明 |
| --- | --- |
| 通用打包 | 源目录、输出目录、ZIP 归档根目录、包含目录、包含文件全部可配置 |
| 剔除规则 | 逐条顺序匹配，支持 `!` 反选；默认排除 `.pyc`、`__pycache__`、`.gitignore` |
| UUID 刷新 | 每次打包生成全新 v4 UUID，版本号保持源文件原值 |
| 完整性校验 | 打包前后比对源文件集合与 SHA-256，仅允许 UUID 字段按映射变化 |
| 联机大厅自测 | 上传、更新项目资源、申请自测、等待 `self_test` 就绪 |
| 安全配置 | Cookie 用当前 Windows 用户的 DPAPI 加密；配置/状态文件默认不提交 |
| 可恢复 | 写入结果不明时保留任务记录，下次先查询核对，不盲目重放 |
| 离线测试 | 自带 500+ 条离线断言，不访问真实账号与网络 |

## 系统要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带；脚本按 5.1 兼容编写）
- .NET Framework 4.6+（系统自带）
- 能访问 `mc-launcher.webapp.163.com` 与文件上传域名

无需安装 Node.js、Python 或第三方 PowerShell 模块。

---

## 快速开始

### 1. 获取代码

```powershell
git clone https://github.com/TanShaoBig/lobby-map-selftest.git
cd lobby-map-selftest
```

也可以直接下载 ZIP 解压。**不要**把整个工具放进地图源目录。

### 2. 配置

双击 **`配置上传自测.cmd`**，填写：

1. **联机大厅组件 ID**：开发者平台项目 ID（详情接口里的 `item_id`）；
2. **Cookie**：登录开发者平台后按 F12 → Network → 点击项目 → 找到 `me` 开头的请求 → 复制请求头中的 `Cookie` 值；
3. **地图源目录**：包含 `level.dat`、`behavior_packs/`、`resource_packs/`、`db/` 等的地图工程目录；
4. **ZIP 输出目录**：留空则使用工具目录下的 `packages/`；
5. **剔除规则**：每行一条，默认三条可保留或修改。

保存后生成 `lobby-test.local.json`（已加入 `.gitignore`）。Cookie 只会以 DPAPI 密文写入。

### 3. 只打包

双击 **`Pack-LobbyMap.cmd`**，或：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pack-LobbyMap.ps1
```

### 4. 打包并上传自测

双击 **`打包并上传自测.cmd`**。流程：

```text
核对登录与项目 → 全量打包（新 UUID）→ 校验源摘要 → 上传 ZIP
→ 更新项目资源 → 申请自测 → 等待本次资源就绪
```

看到“本次自测版本已就绪”后，进入联机大厅验收游戏功能。

### 5. 查询状态 / 取消旧自测

```powershell
# 只查询，不上传、不取消
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\查询自测状态.cmd

# 取消旧版自测，再打包上传新版
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Upload-LobbySelfTest.ps1 -CancelPreviousSelfTest

# 只取消，不打包、不上传
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Upload-LobbySelfTest.ps1 -CancelOnly
```

---

## 配置说明

配置文件默认是工具目录下的 `lobby-test.local.json`，也可以用 `-ConfigPath` 指定。示例见 [`config.example.json`](config.example.json)。

| 字段 | 说明 |
| --- | --- |
| `schemaVersion` | 当前为 `2`；仍兼容读取 `1` 的旧配置 |
| `modId` | 联机大厅组件 ID（平台项目 `item_id`） |
| `cookieProtected` | DPAPI 密文。**不要手动填写**，用配置窗口保存 |
| `sourcePath` | 地图源目录，支持 `%USERPROFILE%` 等环境变量 |
| `outputDirectory` | ZIP 输出目录；空则用工具目录下 `packages/` |
| `archiveRoot` | ZIP 顶级目录名，默认 `map` |
| `includeDirectories` | 需要打包的源目录，默认 `behavior_packs`、`db`、`resource_packs` |
| `includeFiles` | 需要打包的源根文件，默认 `level.dat` 等 6 个 |
| `excludePatterns` | 剔除规则数组，见下一节 |

所有配置都可以被命令行参数覆盖：

```powershell
# 直接打包，不读写配置文件里的源/输出
.\Pack-LobbyMap.ps1 -SourcePath 'D:\maps\my_map' -OutputDirectory 'D:\packages' -PassThru

# 使用自定义剔除规则与归档根目录
.\Pack-LobbyMap.ps1 -SourcePath 'D:\maps\my_map' `
  -ExcludePattern '**/*.pyc','**/__pycache__/**','**/.gitignore','**/*.log' `
  -ArchiveRoot 'map'

# 自定义包含目录/文件
.\Pack-LobbyMap.ps1 -SourcePath 'D:\maps\my_map' `
  -IncludeDirectory 'behavior_packs','resource_packs','db','custom_data' `
  -IncludeFile 'level.dat','levelname.txt','world_behavior_packs.json','world_resource_packs.json'
```

> 联机大厅平台要求 ZIP 中存在 `level.dat`、`levelname.txt`、`world_behavior_packs.json`、`world_resource_packs.json`，以及 `behavior_packs/`、`resource_packs/`、`db/`。自定义包含项时请保留这些必需项。

---

## 剔除规则

规则匹配的是**相对于地图源目录的路径**，统一使用 `/` 分隔，不区分大小写。

| 写法 | 含义 |
| --- | --- |
| `*` | 匹配任意字符，不跨目录 |
| `**` | 匹配任意字符，可跨目录 |
| `**/` | 匹配零层或多层目录 |
| `?` | 匹配单个字符 |
| `!` 开头 | 反选：重新包含此前被排除的路径 |
| `**/__pycache__/**` | 排除任意层级的缓存目录及其中所有文件 |
| `**/*.log` | 排除任意层级的 `.log` 文件 |
| `!**/keep.log` | 重新包含名为 `keep.log` 的文件 |

规则按顺序执行，后匹配的规则覆盖先匹配的规则。默认规则：

```text
**/*.pyc
**/__pycache__/**
**/.gitignore
```

常见扩展：

```text
**/.git/**
**/.svn/**
**/node_modules/**
**/*.log
**/*.bak
**/*.tmp
!behavior_packs/my_pack/keep.pyc
```

被排除的**空目录也会保留**（例如空的行为包目录），只是其中被排除的文件不进入 ZIP。需要绝对排除某个目录时，同时写 `**/dir/**` 即可。

---

## 命令行参考

### Pack-LobbyMap.ps1

```powershell
.\Pack-LobbyMap.ps1 [-SourcePath <目录>] [-OutputDirectory <目录>] [-ArchiveRoot <名称>]
                 [-IncludeDirectory <目录...>] [-IncludeFile <文件...>]
                 [-ExcludePattern <规则...>] [-ConfigPath <文件>]
                 [-PackageDate <日期>] [-PassThru]
```

`-PassThru` 返回：

```text
Path, Sha256, Length, FileCount, SourceDigest, SourceDigestAlgorithm,
RandomizedUuidCount, ArchiveRoot, ExcludePatterns
```

`SourceDigestAlgorithm = sha256-path-nul-sha256-lf-v1`：按相对路径 ordinal 排序，逐条拼接 UTF-8 的“路径 + NUL + 文件 SHA-256 大写十六进制 + LF”，再算 SHA-256。

### Upload-LobbySelfTest.ps1

```powershell
.\Upload-LobbySelfTest.ps1 [-SourcePath <目录>] [-OutputDirectory <目录>] [-PackagePath <参考 ZIP>]
                       [-ConfigPath <文件>] [-ResourceIndex <下标>]
                       [-WaitTimeoutSeconds 900] [-PollIntervalSeconds 3]
                       [-ConfigureOnly] [-StatusOnly] [-CancelOnly] [-CancelPreviousSelfTest]
                       [-ExpectedModId <ID>] [-ExpectedProjectName <显示名>]
                       [-NonInteractive] [-StartNew] [-PassThru]
```

常用示例：

```powershell
# 配置窗口
.\Upload-LobbySelfTest.ps1 -ConfigureOnly

# 自动化：缺少配置时直接失败，不弹窗
.\Upload-LobbySelfTest.ps1 -NonInteractive -PassThru

# 只查询当前平台状态
.\Upload-LobbySelfTest.ps1 -StatusOnly -NonInteractive -PassThru

# 换包前取消旧自测
.\Upload-LobbySelfTest.ps1 -CancelPreviousSelfTest -NonInteractive -PassThru
```

平台项目有多个资源时必须用 `-ResourceIndex` 明确选择（从 0 开始）。

---

## 工作流程与安全边界

1. **先核对身份**：配置中的组件 ID 必须与平台返回的 `item_id` 完全一致；显示名变化只提示，不拦截同一 ID。
2. **每次全量打包**：`-PackagePath` 只作为内容校验参考，不会以历史 ZIP 为底包，也不会改写它。
3. **UUID 全量刷新**：所有 manifest 的 header/module 都生成新 v4 UUID；内部依赖与两个 `world_*_packs.json` 同步替换；外部依赖和所有版本号保持原值。
4. **源完整性**：打包前记录源文件集合与 SHA-256；打包后及上传前核对。源在过程中变化会停止。
5. **写入不重放**：上传、更新资源、申请自测、取消自测的写入请求失败或超时后不会自动重发。记录会标记 `needs_check`，下次先查询平台状态再决定。
6. **Cookie 边界**：Cookie 只发往 `mc-launcher.webapp.163.com`；上传文件只发送到临时上传地址，且不携带 Cookie。禁用自动重定向。
7. **本地文件**：`lobby-test.local.json`、`lobby-test.last.json`、`lobby-test.lock`、`*.selftest.json`、`packages/` 均不会被提交。

如果写入结果不明，请先运行“查询自测状态”，确认平台状态后再决定是否 `-StartNew`。不要用 `-StartNew` 绕过未决记录。

---

## 常见问题

**Q：双击窗口一闪而过？**
用 `cmd.exe` 打开工具目录后运行对应 `.cmd`，或直接运行 PowerShell 命令查看错误。

**Q：提示 Cookie 无法解密？**
DPAPI 密文绑定当前 Windows 用户。更换用户、重装系统或迁移电脑后需要重新配置。

**Q：提示 ZIP 缺少地图文件/目录？**
检查 `includeFiles` / `includeDirectories`，以及剔除规则是否误伤了必需项。

**Q：平台返回 `init`？**
表示本次自测未通过。请到开发者平台查看具体原因；工具不会把 `init` 当成成功。

**Q：只返回 `online`？**
工具只接受与本次唯一资源名匹配的 `self_test`；`online` 可能是旧版本，需在平台手动确认。

**Q：可以提交多个地图工程吗？**
可以。每个工程单独配置 `sourcePath`，或每次用 `-SourcePath` / `-OutputDirectory` 指定。

---

## 开发与离线测试

测试全部离线运行，使用模拟平台响应与内存 HTTP handler，不读取真实 Cookie、不发送真实网络请求。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-PackRules.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LobbySelfTestConfig.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LobbySelfTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-LobbySelfTestCancel.ps1
```

当前结果：打包规则 46 项、配置 49 项、上传/恢复 284 项、取消 154 项，共 **533** 项通过（Windows PowerShell 5.1）。

提交 PR 前请：

- 保持 Windows PowerShell 5.1 兼容（不要使用 PowerShell 7 专有语法）；
- `.ps1` 文件保存为 **UTF-8 with BOM**（PS 5.1 读取中文必需）；
- 不提交任何真实 Cookie、项目 ID、个人路径或平台任务记录；
- 新增行为时补充离线测试。

---

## 致谢

本项目的上传与联机大厅自测协议参考了 **QUMOD / QuModLibs** 生态：

- [QuMod 线上测试文档](https://qumod.cc/QuModLibs/Modules/MultiplayerLobby/QuickLobbyManager.html#线上测试)
- [QuMod 官方 Tools/NeLobby](https://github.com/GitHub-Zero123/QuModLibs/tree/master/Tools/NeLobby)
- [NeLobbyAutoKit 源码](https://gitee.com/bili_zero123/ne-lobby-auto-kit)（BSD-3-Clause，作者 Zero123）

感谢 QUMOD 社区对网易版联机大厅开发与测试流程的整理。上游许可证全文见 [`THIRD-PARTY-NeLobbyAutoKit-LICENSE.txt`](THIRD-PARTY-NeLobbyAutoKit-LICENSE.txt)。本项目不下载、不打包、不执行 NeLobbyAutoKit 的可执行文件，仅参考其公开协议实现。

---

## License

[MIT](LICENSE) © 2026 TanShaoBig and contributors

本项目与网易、MC Studio、QuMod 官方无隶属关系。Minecraft 是 Mojang Studios 的商标；相关名称仅用于说明兼容性。
