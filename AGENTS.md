# 薪动岛

产品依据为 `docs/PRD-v0.3.md` 及其中的 Notion 当前稿。基于 Boring Notch GPL-3.0 基线 23e7705a4ffcb5d97a54fb1d4135e180084a566d；保留版权与许可证。

当前分支 `feature/salary-island-v1`。不合并 main、不推送或公开发行，除非用户授权。新增模块在 `boringNotch/Salary/`，上游窗口继续是唯一灵动岛窗口实现。薪酬不要依赖每秒增量累加；门槛必须使用整数精确判断。新UI以macOS为验收设备。

主测试命令在 README-SalaryIsland.md。本地 ad-hoc 签名要包含原 App Sandbox entitlements，构建后检查签名；无上游更新源。敏感薪酬与CLI执行日志不提交。只把有非空真实产物的外部模型响应视为可审核，最终行为由Codex核验。
