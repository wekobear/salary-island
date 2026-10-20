# 薪动岛 · v0.1.0 本地体验版

把上班的每一秒，换算成生活里的一点甜。

基于 [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch) 改造，基线 `23e7705a4ffcb5d97a54fb1d4135e180084a566d`。保留上游窗口、悬停交互、设置及音乐/文件架入口，新增薪酬默认页。本仓库保留原作者声明与 GPL-3.0 许可证，本地版本不是上游官方发行版。

## 体验

- 打开 `SalaryIsland.app`，显示名称为“薪动岛”。首次显示设置窗口，不预填真实月薪。
- 点击“播放奶茶演示”，用明确标记的虚构数据看到奶茶门槛反馈；演示不会写入正式成就。
- 输入固定月薪、工作日、上班/下班与午休，预览时薪后保存。将鼠标移到屏幕顶部灵动岛展开。
- 主面板显示下班倒计时、今日估算收入和秒/分/小时速率；设置支持最多5个每日消费门槛。
- 眼睛按钮隐藏金额与消费目标；铃铛按钮“安静到下班”。声音默认关闭，语气可选温柔/抽象/嘴替。
- 原 Boring Notch 设置可选显示器、原模块及开机启动；薪酬功能不要求相机、日历或辅助功能权限。音乐模块在主动打开时才初始化。

本地体验面向 Apple Silicon、macOS 14+（实际测试环境见测试报告）。不包含富豪对比、统计平均工资库、跨日存钱目标、发薪日功能。当前不自动读取系统专注状态，使用手动安静按钮。

## 构建与检查

需要 Xcode 26 系列与其命令行工具，SwiftPM 按 `Package.resolved` 的固定版本下载依赖。Swift 源码继续使用上游 Swift 5 语言模式。

```bash
swiftc boringNotch/Salary/SalaryCore.swift boringNotch/Salary/SalaryFeedback.swift tests/SalaryCoreChecks.swift -o /tmp/salary-core-checks
/tmp/salary-core-checks
bash scripts/build-salary-local.sh
```

构建脚本生成 `work/build/Build/Products/Debug/SalaryIsland.app`，做本地 ad-hoc 签名并保留 App Sandbox。它不是 Developer ID 公证发行流程；不会发布、上传或替用户安装到 Applications。

本轮网络导致完整 Git 镜像下载中断，开发机使用固定 SHA 的浅克隆作本机 SwiftPM mirror；机器路径不提交、不打入源码交付包。其他机器按原 URL 与锁文件构建即可。

## 文件与数据

新增 `boringNotch/Salary/`：纯计算、提示调度、持久化、灵动岛视图、设置视图分别维护。测试不依赖网络或系统时间，覆盖 PRD 数学及调度边界。

独立 bundle ID 为 `local.salaryisland.preview`。带 App Sandbox 的签名构建将薪酬数据写在容器内 `Library/Application Support/SalaryIsland/salary-v1.json`，仅当前用户可读写（0600）；目录0700。不在普通日志写入工资。原文件架的数据目录也与上游隔离。未设置更新源，原自动更新入口停用。

文档：`docs/PRD-v0.3.md` 为已审 PRD 快照，Notion 链接为需求当前稿。当前体验版的验证范围、限制及发布前事项见 `docs/TEST-SECURITY-v0.1.md`；推广思路见 `docs/OPERATIONS-DRAFT.md`。
