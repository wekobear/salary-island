# 开源许可与声明

薪动日常基于 [TheBoredTeam/boring.notch（Boring Notch）](https://github.com/TheBoredTeam/boring.notch) 开发，基线提交为 `23e7705a4ffcb5d97a54fb1d4135e180084a566d`，遵循 [GNU GPL v3.0](LICENSE)。

原项目由 TheBoredTeam 及其贡献者开发。原作者版权、源文件署名、许可证及依赖许可继续保留；完整上游说明留在 [UPSTREAM-README](docs/UPSTREAM-README.md)。本项目名称和用户界面展示的调整不改变上述归属与许可。

薪动日常新增薪酬计算、下班倒计时、快乐目标、本地反馈及对应设置与界面。发布页同时提供体验包与对应源码。第三方依赖遵循各自附带的许可证。

## AI 额度研究与实现来源（2026-10-27）

参考 [Vinz/codenotch](https://github.com/vinzdg/codenotch/tree/6522e9f3ee0fe35d46e428b441e6e80b586eacbb)（MIT，Copyright (c) 2026 Vinz）的多窗口、账号分离与 provider 展示思路；本轮自行编写 Swift 数据/状态/界面层，未整体移植其窗口引擎或凭据读取路径，未复制其平台图标。上游许可见 [固定版本 LICENSE](https://github.com/vinzdg/codenotch/blob/6522e9f3ee0fe35d46e428b441e6e80b586eacbb/LICENSE)。本项目继续 GPL-3.0。

Codex 协议依据 [官方 app-server 文档](https://developers.openai.com/codex/app-server)；AGY quota 字段依据 [官方 statusline 文档](https://antigravity.google/docs/cli/statusline)。GLM 数据格式参考 [Z.ai 用量插件公开源码](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs)，仅实现解析，不声明其未公开监控接口是公开 API。

GLM 5.3 通过用户既有 Claude Code CLI headless 参与纯解析器草稿；Codex 修订重置时间可空、数值边界与错误信封优先处理，并编写验证。既有钱包艺术保留，本轮不新增生成图片或伪造平台商标。

第二阶段 AGY 纯文本适配器另参考同一固定 commit 的 `windows/codenotch/src/agy_cli.rs` 中公开 `/usage` 命令参数、报表标签及样例；Mac stdio 生命周期、Swift 严格解析与时区验证自行编写，未移植 Windows ConPTY 或认证代码。随附 [codenotch MIT 许可](docs/licenses/codenotch-MIT.txt)。官方命令说明：[headless](https://antigravity.google/docs/cli/headless)、[/usage](https://antigravity.google/docs/cli/commands/usage)。
