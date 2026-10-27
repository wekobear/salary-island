# 薪动日常 v0.1.9 · build 14

在现有工资与目标卡下方新增 **Codex / Gemini / GLM 5.3** 三张额度卡，保留钱包、倒计时、工资速率及隐私/安静控件。

**本版 AI 模块仅提供明确标识的演示数据与离线验证，不连接真实账户，不显示实时官方额度。** 默认三项未连接；用户主动打开演示后可查看虚构窗口、百分比和重置时间，退出演示恢复未连接。Gemini 的设计来源为 AGY 额度组，不代表 Google 消费者套餐；GLM 5.3 的设计口径是套餐共享额度，不是模型独享。

已验证百分比换算、舍入、未知/异常值、秒/毫秒重置、跨日、缓存过期、来源切换、取消与假进程清理；工资原有 226 项回归通过。详细场景与未验证范围见 [验收记录](AI-QUOTA-REVIEW-2026-10-27.md)。真实服务连通性不在本次验收范围。

## 安装包与签名

- 面向 Apple Silicon，部署目标 macOS 14+；实际测试系统 macOS 26.5.1，未完成 macOS 14 真机验收。
- app 包使用 **ad-hoc 签名，未获 Developer ID 签名或 Apple 公证**。严格本地签名校验不等于 Gatekeeper 认可。不会修改系统安全设置。
- 正式 app ID 沿用 `local.salaryisland.preview`，供用户自行升级；不自动安装或替换正在使用的应用。Debug 始终使用独立候选身份。原 XPC 标识和权限保持不变，未用于 AI 接入。
- Release 不开放实验性真实 CLI 连接操作；不内置 API key、账户配置或本机薪资数据。
- 下载资产名为 `SalaryDaily-v0.1.9-macOS.zip`、`SalaryDaily-v0.1.9-source.zip` 和 `SHA256SUMS.txt`。发布时校验和必须与该次最终审核构建一致。

## 复跑打包（开发者）

在 macOS / Xcode 26 的干净、已提交工作区执行：

```bash
bash scripts/check-ai-quota.sh
python3 scripts/package-salary-release.py
```

可用 `--package-cache <目录>` 指定已按锁文件解析的 SwiftPM 缓存，`--derived-data <目录>` 指定构建目录。脚本保持锁定依赖解析，所有输出位于仓库忽略的 `work/` 下；目标输出目录已存在时拒绝覆盖。无需访问账户或用户配置，不启动任何生成的 app。

脚本仅构建 Release、清理调试路径、签名和静态验证；构建后撤销 Xcode 对本次产物目录的 Launch Services 登记，不操作已安装应用。输出 app/source ZIP、校验和及构建清单。清单记录源码 commit、工具链、版本、架构、签名方式与资产哈希。不是位级可重复构建的保证；每次构建必须以本次 SHA-256 为准。main/tag 推送、创建 Release 与上传资产由审核后的独立步骤执行；脚本不会进行这些操作。
