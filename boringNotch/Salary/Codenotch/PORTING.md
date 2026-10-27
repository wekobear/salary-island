# Codenotch 源码移植记录 · 2026-10-27

来源：[vinzdg/codenotch 固定提交](https://github.com/vinzdg/codenotch/tree/6522e9f3ee0fe35d46e428b441e6e80b586eacbb)。Copyright (c) 2026 Vinz，MIT；完整许可保留在 [codenotch-MIT.txt](../../../docs/licenses/codenotch-MIT.txt)。薪动日常继续遵循 GPL-3.0。以下文件包含从该提交复制并修改的函数/类型，不仅是概念参考。

| 上游文件 | 本地文件 | 移植范围与修改 |
| --- | --- | --- |
| CodexCredentials.swift | 同名 | Auth JSON、JWT 到期解析；改为传入 Data，移除默认磁盘扫描和账户资料读取；加入容量、header 和日期边界 |
| CodexUsage.swift | 同名 | 主/次窗口、额外窗口和 credit 百分比；非法值保留未知，实际窗口长度，缺失容器报错，禁止极端 Date/Int 转换 |
| CodexLocalProvider.swift | 同名 | 原固定 wham usage 请求、认证头、401/403/429 与刷新前重读；注入许可/文件/HTTP；排除 profile、SQLite、sessions、rollouts 和写操作 |
| GLMCredentials.swift | 同名 | 仅 claudeCode 分支及 Z.ai/智谱域名选择；删除 Z Code/OpenCode/环境扫描/解密；严格 HTTPS、host 和 header 校验 |
| GLMUsage.swift | 同名 | Coding Plan TOKEN/CREDIT/MCP 窗口；先判错误信封、严格成功判定、缺失百分比未知、毫秒日期边界 |
| GLMProvider.swift | 同名 | 原 monitor GET 与 raw Authorization、递增限流退避；不截短有效 Retry-After；无持久缓存/凭据保存 |
| AntigravityCredentials.swift | 同名 | 原始 OAuth JSON 与 go-keyring-base64 纯解码；不操作钥匙串、不读取 refresh token/client secret、不刷新或写回 |
| AntigravityQuotaParser.swift | 同名 | groups/buckets/legacy 响应；保持分组和每模型窗口，不聚合最小值、不按重置距离臆测周窗口；无请求计数替代 |
| AntigravityBridge.swift | 同名 | 发现与监听端口的纯解析、固定 loopback RPC；进程表由测试注入，不运行 ps/lsof、不启动 language server；不采用 LocalhostTrust |
| AntigravityProvider.swift | 同名 | local-first 与独立授权 OAuth fallback、固定 Google quota 路径；去除客户端伪装、账户跨来源合并、会话统计 fallback；401/403 停止 |
| UsageStore.swift | UsagePolicy.swift / SalaryAIQuotaStore.swift | 复用 reset crossing、shouldRefresh 与 event spacing；应用保留 5 分钟最低刷新、暂停/取消/去重、限流期限 |
| UsageModel.swift / UsageProvider.swift | CodenotchTypes.swift | 轻量 Window、错误到应用快照的桥接；避免引入另一套窗口引擎 |

`QuotaHTTPTransport.swift`、`CredentialAccess.swift` 是本项目的最小适配：临时内存许可、明确选择的有界只读文件访问、固定目标请求、ephemeral URLSession、禁止重定向、系统 TLS 校验、20 秒请求超时和 1 MiB 响应上限。没有常驻 companion/helper、启动项、监听端口、认证刷新或配置写入。

## 适配边界

- macOS 14 底座保持，未引入上游 macOS 15 UI/API；主 App Sandbox 和既有 XPC 均不改。
- Debug 连接面板显式选择文件和同意，每次运行有效，默认关闭。Release 仍保留 v0.1.9 的离线预览入口，未启用 live UI。
- 当前连接管理器只接线三家文件来源。Antigravity 本地发现仅纯函数与注入接口，未接线真实进程枚举或钥匙串；本地服务若使用不被系统信任的证书会正常失败，不绕过。
- Codex wham、GLM monitor、Google Cloud Code 为参考项目使用的服务路径，不声明为稳定公开 API。使用自身 `SalaryIsland/AIQuota` User-Agent，不能承诺 Google 接受该调用身份。
- 实际账户切换：Codex 使用原文件 account_id 作为内存 backend identity，同时用 account_id + token 摘要校验来源连续性；GLM/AGY 请求前后核对同一来源的 token/region/project，变化则清空旧连接。没有推断三个标签是三个独立账号。
- 默认路径构造函数不执行文件系统访问。自动默认路径读取和非沙盒候选方案待独立确认；本轮只运行 owned fixture。

## 上游文件 SHA-256

校验输入为上述固定提交工作树的原始文件，不包括本机账户内容。

| 原文件 | SHA-256 |
| --- | --- |
| `Sources/Providers/CodexCredentials.swift` | `453d920c3fb425f88523319cd4d852ca478ef11ad6e3316e0c7904d9cdaf79fb` |
| `Sources/Providers/CodexUsage.swift` | `6b7e094855127813022875a82d8a648dcb146e530044d606cee8ca287c60556b` |
| `Sources/Providers/CodexLocalProvider.swift` | `8e90f1f053f87d4c061d55417d45d3eaf85bf4cf609f87997a2e368953b5e672` |
| `Sources/Providers/GLMCredentials.swift` | `4c3d7575c5f6b1be1184437928f13f54f2cf63cb3272c2c0568d663ff87da099` |
| `Sources/Providers/GLMUsage.swift` | `832b0d78d8a1e01b35e3f5f487f52482e5ed094f30067089696c72c0fe193915` |
| `Sources/Providers/GLMProvider.swift` | `cc1f42e304ed9c64a4578fe43d7019a1fa52f48ff837de767c65b02a5465c597` |
| `Sources/Providers/AntigravityCredentials.swift` | `8ebb651a5edcb45e5c006a30912690cca54eefdc7cc9efb377e8c6b24b719c77` |
| `Sources/Providers/AntigravityQuotaParser.swift` | `f66edcc0001667548f492330c5c2f8490c6ddabec66b9ea78693ef39c6b955be` |
| `Sources/Providers/AntigravityProvider.swift` | `a4accf23b2b0bce5d9fcf697c2fe7f258ee5359ff8f3e581ac005b4a548b2ae1` |
| `Sources/Providers/AntigravityBridge.swift` | `63a0eec898d1465fd3049c81d04c5c56d3e595a59f45162bcd2ac9108786cbea` |
| `Sources/Model/UsageStore.swift` | `835a8e4b60cd4d01a156f6a976d1d9b017dcdb50ed8bb7ba53f19d7bab0f6713` |
| `Sources/Model/UsageModel.swift` | `7eb3a8ef7a3c01324d513bf5e67fabddc94e2fb8644d4d96bdc9e816fd94256c` |
| `Sources/Providers/UsageProvider.swift` | `1cbc09c3799bf7ae6f4531dae54cb62bc8b40d68f60f85d3ce96517ac6115151` |
| `LICENSE` | `2868a2239cb49e84eae28db7a9069c6c04f8f9d4623aa360fd69feefa96edc63` |

## 审查修正

AGY 窗口身份由 group/bucket/model/name/window 元信息稳定生成；GLM 保留 meter type，不把相同周期的 TOKEN/CREDIT 合为一个 ID。快照适配器拒绝重复规范 ID，保留原缓存并报告错误。Codex 另将 token 纳入内存来源摘要，防止相同 account_id 下登录 token 更换后接受旧结果。
