# AI 额度离线验收｜2026-10-27

本次验收范围为模拟数据、计算口径、界面及离线状态行为。真实服务连通性不在本轮范围；没有查询账户、读取认证文件或增加常驻辅助程序。Release 界面默认未连接，只提供主动演示和离线说明；实验性 CLI 连接入口仅在 Debug 中保留。

## 功能与口径

- 保留工资、钱包、秒/分/时薪、两个目标卡和底部控件，在目标卡下追加 Codex / Gemini / GLM 5.3 三卡。
- Codex 采用返回的真实窗口时长与已用百分比，保留多个 limit bucket；可选 backend accountId 仅在内存检测变化。调用方 sourceID 不等于认证账户。
- Gemini / AGY 的 remaining_fraction 转已用，remaining_amount 保留原单位，不换算百分比；不同额度组不混合。CLI 纯文本适配仅接受所选确切组。
- GLM percentage 为已用，nextResetTime 毫秒转绝对秒；套餐共享而非模型独享。未知单位、缺失及越界字段不填零；非法 JSON、缺失必要容器及失败信封拒绝。
- 界面整数百分比按最近整数、半值远离零舍入；只影响显示，底层小数不变。到达重置时刻保留旧值并标记待刷新，不虚构清零；界面每 30 秒更新时效文案，不查询网络。
- 缓存达到 15 分钟或查询失败时标记过期。结构错误不覆盖有效快照；切换来源清空旧快照并拒绝旧请求晚到结果。
- 默认无 reader/定时查询；实验连接显式同意且仅本次运行。隐藏、锁屏、睡眠、隐私、演示、暂停时取消查询；失败保守退避。
- CLI 仅固定 argv 和只读 RPC，无 shell、监听端口、login/thread/turn 方法。TERM 后必要时仅清理本次 PID；退出与 stdout EOF 协调；清理无法确认则封禁本次来源。

## 可复跑测试

`bash scripts/check-ai-quota.sh` 运行下列七组；只使用虚构数据和自编假 CLI：

| 测试组 | 数量口径 | 结果 |
|---|---|---|
| SalaryAIQuotaChecks | 38 次断言执行，32 个断言位置 | 通过；三家解析、窗口、错误信封、RPC allowlist、空窗口 |
| SalaryAIQuotaStoreChecks | 26 个断言 | 通过；去重、最小间隔、过期、退避、取消、晚到结果、来源/平台检查、切号、未来时间拒绝 |
| SalaryCodexQuotaClientChecks | 3 个场景 | 通过；握手数据、异常输出、取消 |
| SalaryQuotaProcessChecks | 9 个场景 | 通过；每个自建 PID 返回前均确认 ESRCH |
| SalaryAGYUsageChecks | 18 次断言执行，8 个断言位置 | 通过；精确组、剩余换算、非法/重复报表、ANSI、时区与 DST |
| SalaryQuotaConnectionChecks | 18 个断言 | 通过；默认 OFF、选择不启动、假 CLI 接线、暂停、生命周期、来源/组变化 |
| SalaryQuotaAcceptanceChecks | 82 次断言执行，动态计数 | 通过；0/100、负数/越界/缺失/非有限值、舍入、秒/毫秒、跨日/到期、缓存边界、空窗口、溢出、输入上限、极大有限时间戳与时区上界 |

9 个进程场景为 immediate-exit、success-ignore-term、timeout、timeout-ignore-term、large-out、large-err、malformed、cancel-ignore-term、agy。没有杀其他用户进程。模拟 auth/rate-limit 是状态层 fixture；不声称真实 Codex JSON-RPC 能自动区分 HTTP 401/429。

原薪酬测试命令见 [README](../README-SalaryIsland.md#构建与检查)，本轮重新运行：SalaryCore 67、SalaryStore 74、SalaryWallet 85，共 226 项通过。存储测试使用独立临时目录，不读取用户薪资配置。

## 构建与原生检查

Xcode Debug 和 Release 构建成功，部署目标 macOS 14；实际运行环境 macOS 26.5.1 / Apple Silicon。保留原 App Sandbox entitlements，ad-hoc 签名后严格校验通过。

原生验证：640pt 主面板三卡与两目标卡无溢出；默认三家未连接；主动演示有标题和 accessibility 的虚构标识；详情显示虚构来源；刷新演示仅更新时间；退出演示恢复未连接；隐私关闭详情并从 AX 树隐藏百分比和重置；安静模式时工资继续更新；查看全部仍含完整目标清单。Release 的演示可用，说明中明确无真实连接，不出现连接操作。所有运行测试均使用隔离候选身份；测试结束已退出。

本地证据（不入 Git）：`work/ai-offline-acceptance.log`、`work/*-offline-regression.log`、`work/verified-build-offline*.log`、`work/ai-offline-final.png`、`work/ai-offline-privacy.png`、`work/ai-offline-release-info.png`。

## 未验证与发布边界

- 未验证真实账户、服务输出/错误、CLI 认证可达性、持续网络刷新；GLM 未公开监控接口没有实现网络接入。
- 主 app 的外部假 CLI 执行检查未通过；现有沙盒不扩大。Apple DTS 说明 Open Panel 动态扩展不授予执行权限，见 [文件权限](https://developer.apple.com/forums/thread/678819)。这个限制不影响本轮离线验收，但禁止宣称实时接入完成。
- 未在 macOS 14 真机、多个物理显示器/摄像头 safe area、真实锁屏睡眠或系统减少动态偏好下完整验收。状态层相关行为有 fixture，不能替代真机验证。
- Debug 候选主 app 使用 `local.salaryisland.ai-review.20261027`；Release 恢复正式 `local.salaryisland.preview`。原 XPC ID 未改、未用于额度。正式身份只做静态构建检查，不启动来测试用户薪资配置。
- Developer ID 签名和 Apple 公证尚未配置验证；当前只有 ad-hoc，不宣称已公证，不关闭 Gatekeeper。

## 来源与贡献

参考 codenotch 固定版本 `6522e9f3ee0fe35d46e428b441e6e80b586eacbb` 的额度模型与公开 AGY 报表思路，未移植其认证路径或窗口引擎。GPL 与 MIT 声明见 [第三方说明](../THIRD-PARTY-NOTICES.md)。

GLM 5.3 经既有 Claude Code headless 返回非空纯解析器草稿，modelUsage canonicalModel=glm-5.3、is_error=false；审查修复 reset 可空、数值边界和错误信封优先处理，本轮再补 1 MiB 输入上限。未操作其他模型客户端。现有钱包美术足够，未新增或伪造平台商标。

## 发布准备（尚未推送或发布）

只读核对的远端为公开仓库 `wekobear/salary-island`，main 为 `bad9f9b6634dda06a071b30bedf38b1752f9389d`（0.1.8/build 13）；最新已发布版本 v0.1.6/build 9，安装资产是 `SalaryDaily-v0.1.6-macOS.zip`，另有源码 ZIP 和 SHA256SUMS。现有 Release 工作流仍包含上游项目名称和 appcast 地址，不直接触发它发布薪动日常。

已准备 **v0.1.9/build 14** 元数据和可复跑打包脚本 `scripts/package-salary-release.py`；实际构建结果、源码 commit 和资产哈希以脚本输出的 `BUILD-MANIFEST.json` 为准。发布流程如下：

1. 最终审核通过后再次 fetch/核对 main。若远端新增提交，先合并或重放本功能并重新验证差异；只正常 fast-forward 推送，不强推、不丢已有提交。
2. 正式构建前把 Release 的主 app 标识恢复为既有 `local.salaryisland.preview`，XPC 仍为 `local.salaryisland.preview.BoringNotchXPCHelper`，递增版本/build。Debug 候选保持隔离身份。不得启动正式身份的产物测试用户配置，也不自动安装或替换现有应用。
3. 使用最终审核提交做 Release 构建；保持离线说明和默认未连接，不打入任何真实账户配置。构建源路径映射至通用 `/src/salary-island`，关闭 Swift 调试选项序列化，主二进制和 XPC 用 `strip -S` 去除调试符号后再签名。该路径清理流程已在隔离 Release 候选验证，包内扫描测试用户路径为零；单独使用编译 prefix map 不足以清理对象文件符号路径。
4. 检查 CFBundleIdentifier/版本、架构、原沙盒 entitlements、严格签名、资源清单和路径/凭据/财务文件扫描。若没有经核实可用的 Developer ID 与公证流程，仅明确标注 ad-hoc/未公证；不声称已通过 Gatekeeper，不改变系统安全设置。
5. 从最终提交 `git archive` 生成源码 ZIP；只打包 app 生成新的 `SalaryDaily-v0.1.9-macOS.zip`，附源码 ZIP 和 SHA256SUMS。当前测试候选标识的包不得上传。tag 必须指向审核提交；确认 tag/Release/同名资产不存在，不使用 clobber，不覆盖旧版本。
6. 正常推送 main 后创建绑定该提交的新 Release；发布说明强调 AI 模块仅演示与离线验证、未连接真实服务。核对资产下载哈希。发布过程不自动安装应用。

正式版本号和 Release 标识已设置；Debug 保持隔离。脚本从干净提交构建并保存相应 commit，生成源码 ZIP 后再次检查 HEAD/工作区，避免产物与源码漂移。所有已运行的原生检查都使用候选容器；正式身份只做静态产物检查。推送 main、tag 和上传 Release 仍待最终审核。

时间戳加固：所有解析路径和显示入口只接受 `(0, 253402214400]` Unix 秒（上界为 9999-12-31 UTC，预留时区余量）。毫秒先验证对应范围再换算；相对时间先验证基准和剩余可加范围再相加；ISO 输入限四位年份。极大 finite、NaN/Infinity、越界 ISO、上下界和 UTC±14 已纳入离线断言；非法值显示未知，不传入日历/日期格式化。
