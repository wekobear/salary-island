import AppKit
import SwiftUI

@MainActor
struct SalaryAIQuotaSection: View {
    let privacy: Bool
    @StateObject private var connections = AIQuotaConnections.shared
    @State private var showConnectionInfo = false
    @State private var detail: AIQuotaProvider?
    @State private var demo = false
    @State private var demoDate = Date()
    @State private var visible = false
    @State private var locked = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            panel(at: context.date)
        }
    }

    private func panel(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(demo ? "AI 额度 · 演示数据" : "AI 额度").font(.system(size: 11, weight: .medium))
                Spacer()
                Button(demo ? "退出演示" : "演示") { demo.toggle(); demoDate = Date(); detail = nil }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(SalaryPalette.mint)
                Button(connectionTitle) { showConnectionInfo = true }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(SalaryPalette.mint)
                    .popover(isPresented: $showConnectionInfo) {
                        #if DEBUG
                        AIQuotaConnectionPanel(connections: connections)
                        #else
                        VStack(alignment: .leading, spacing: 10) {
                            Text("AI 额度 · 离线预览").font(.headline)
                            Text("本版本未连接真实账户。点击“演示”可查看虚构额度；退出演示后恢复未连接。")
                            Text("Codex 显示账户窗口；Gemini 指 Antigravity 额度组；GLM 5.3 指 Coding Plan 套餐共享额度。")
                            Text("演示不会读取凭据、查询服务或影响工资计算。")
                        }.font(.system(size: 12)).padding(16).frame(width: 320)
                            .background(Color.black.opacity(0.96)).preferredColorScheme(.dark)
                        #endif
                    }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(AIQuotaProvider.allCases) { provider in card(provider, now: now).frame(minWidth: 165) }
                }
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) { card(.codex, now: now); card(.gemini, now: now) }
                    card(.glm, now: now)
                }
            }
        }
        .onAppear { visible = true; connections.setPrivateOrDemo(privacy || demo); connections.setVisible(true) }
        .onDisappear { visible = false; connections.setVisible(false); detail = nil; showConnectionInfo = false }
        .onChange(of: privacy) { _, hidden in
            connections.setPrivateOrDemo(hidden || demo)
            if hidden { detail = nil; showConnectionInfo = false }
        }
        .onChange(of: demo) { _, value in connections.setPrivateOrDemo(privacy || value) }
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsLocked"))) { _ in
            locked = true; connections.setLocked(true); detail = nil; showConnectionInfo = false
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("com.apple.screenIsUnlocked"))) { _ in
            locked = false; connections.setLocked(false)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            connections.setSleeping(true); detail = nil; showConnectionInfo = false
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            connections.setSleeping(false)
        }
    }

    private var connectionTitle: String {
        #if DEBUG
        return connections.paused ? "连接 · 已暂停" : "连接"
        #else
        return "说明"
        #endif
    }
    private var hidden: Bool { privacy || locked }
    private func state(_ provider: AIQuotaProvider) -> AIQuotaCardState {
        if demo {
            let now = demoDate
            let windows: [AIQuotaWindow]
            switch provider {
            case .codex:
                windows = [AIQuotaWindow(bucketID: "codex", bucketName: "账户", position: "primary", usedPercent: 40, durationMinutes: 300, resetsAt: now.addingTimeInterval(7200)),
                           AIQuotaWindow(bucketID: "codex", bucketName: "账户", position: "secondary", usedPercent: 25, durationMinutes: 10080, resetsAt: now.addingTimeInterval(172800))]
            case .gemini:
                windows = [AIQuotaWindow(bucketID: "example-group", bucketName: "示例额度组", position: "group", usedPercent: 25, durationMinutes: nil, resetsAt: nil)]
            case .glm:
                windows = [AIQuotaWindow(bucketID: "example-plan", bucketName: "套餐共享", position: "plan", usedPercent: 65, durationMinutes: nil, resetsAt: nil)]
            }
            return AIQuotaCardState(snapshot: AIQuotaSnapshot(provider: provider.title, accountID: "虚构示例账号", updatedAt: now, windows: windows))
        }
        return connections.store.state(for: provider)
    }

    private func card(_ provider: AIQuotaProvider, now: Date) -> some View {
        let value = state(provider)
        let windows = Array((value.snapshot?.windows ?? []).prefix(2))
        return Button { if !hidden { detail = provider } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(provider.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    if value.isRefreshing && !hidden { Text("刷新中").font(.system(size: 9)) }
                }
                Text(hidden ? "已隐藏" : provider.scope)
                    .font(.system(size: 9)).foregroundStyle(SalaryPalette.dim).lineLimit(1)
                if !hidden && !windows.isEmpty {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        VStack(spacing: 3) {
                            HStack {
                                Text(windowName(window)).lineLimit(1)
                                Spacer(minLength: 2)
                                Text(AIQuotaPresentation.percent(window.usedPercent)).monospacedDigit()
                            }.font(.system(size: 10))
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.09))
                                    if let percent = window.usedPercent {
                                        Capsule().fill(percent >= 85 ? SalaryPalette.gold : SalaryPalette.mint)
                                            .frame(width: geometry.size.width * min(1, max(0, percent / 100)))
                                    }
                                }
                            }.frame(height: 3).accessibilityHidden(true)
                            Text(AIQuotaPresentation.reset(window.resetsAt, now: now)).font(.system(size: 8)).foregroundStyle(SalaryPalette.dim)
                                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        }
                    }
                } else {
                    Text(hidden ? "•••" : "—").font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    Capsule().fill(.white.opacity(0.09)).frame(height: 3).accessibilityHidden(true)
                    Text(hidden ? "额度与重置时间已隐藏" : status(value)).font(.system(size: 9)).foregroundStyle(SalaryPalette.dim)
                }
                if !hidden, value.isStale(at: now) {
                    Text("数据已过期 · 查看更新时间").font(.system(size: 9)).foregroundStyle(SalaryPalette.gold)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(9)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hidden ? "\(provider.title)，额度已隐藏" : accessibility(provider, value, now: now))
        .popover(isPresented: Binding(get: { detail == provider && !hidden }, set: { if !$0 { detail = nil } })) {
            if !hidden {
                ScrollView { VStack(alignment: .leading, spacing: 9) {
                    Text("\(provider.title) · \(demo ? "虚构演示" : provider.scope)").font(.headline)
                    if let snapshot = value.snapshot {
                        Text(demo ? "来源：本地虚构演示，未查询任何账户" : (snapshot.backendAccountID == nil ? "来源：CLI 当前登录状态（身份未核验）" : "来源：CLI 当前登录状态（可检测身份变化）"))
                        if snapshot.windows.isEmpty { Text("当前来源未提供窗口额度") }
                        if value.accountChanged { Text("登录身份已变化，旧额度已清除。") }
                        if value.error != nil { Text(status(value)) }
                        ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                            Text("\(window.bucketName ?? window.bucketID) · \(windowName(window)) · \(AIQuotaPresentation.percent(window.usedPercent))")
                            Text(AIQuotaPresentation.reset(window.resetsAt, now: now))
                        }
                        Text("更新：\(snapshot.updatedAt.formatted(date: .abbreviated, time: .standard))")
                        Text("时间采用本机时区：\(TimeZone.current.identifier)")
                        if value.isStale(at: now) { Text("数据已过期，保留上次结果。") }
                    } else { Text(status(value)) }
                    if demo {
                        Button("刷新演示数据") { demoDate = Date() }
                    }
                    if !demo && value.isConnected {
                        Button("刷新") { Task { await connections.refresh(provider) } }
                        Button("断开") { connections.disconnect(provider); detail = nil }
                    }
                }.font(.system(size: 12)).padding(16) }
                .frame(width: 320).frame(maxHeight: 420)
                .background(Color.black.opacity(0.96)).preferredColorScheme(.dark)
            }
        }
    }
    private func windowName(_ window: AIQuotaWindow) -> String {
        switch window.durationMinutes {
        case 300: return "5 小时"
        case 10080: return "每周"
        case let minutes?: return "\(minutes) 分钟窗口"
        case nil: return window.bucketName ?? "窗口未知"
        }
    }
    private func status(_ value: AIQuotaCardState) -> String {
        switch value.error {
        case .unauthorized: return "授权失效 · 请重新连接"
        case .rateLimited: return "请求受限 · 等待重试"
        case .offline: return "网络离线 · 暂无数据"
        case .malformed: return "数据格式无法识别"
        case .unavailable: return "服务暂不可用"
        case .timedOut: return "查询超时 · 稍后重试"
        case .outputTooLarge: return "CLI 输出异常 · 已停止查询"
        case .cleanupFailed: return "子进程清理失败 · 已断开"
        case .sourceChanged: return "CLI 来源已改变 · 请重新连接"
        case .rpcRejected: return "无法查询 · 请检查登录或 CLI 版本"
        case nil:
            if let snapshot = value.snapshot, snapshot.windows.isEmpty { return "当前来源未提供窗口额度" }
            return value.isConnected ? "等待额度数据 · 重置未知" : "未连接 · 重置未知"
        }
    }
    private func accessibility(_ provider: AIQuotaProvider, _ value: AIQuotaCardState, now: Date) -> String {
        let windows = value.snapshot?.windows.map { "\(windowName($0))，\(AIQuotaPresentation.percent($0.usedPercent))，\(AIQuotaPresentation.reset($0.resetsAt, now: now))" }.joined(separator: "；")
        let summary = windows.flatMap { $0.isEmpty ? nil : $0 } ?? status(value)
        return "\(provider.title)，\(demo ? "虚构演示数据，" : "")\(summary)\(value.isStale(at: now) ? "，数据已过期" : "")"
    }
}

@MainActor
private struct AIQuotaConnectionPanel: View {
    @ObservedObject var connections: AIQuotaConnections
    @State private var periodicCodex = false
    @State private var periodicAGY = false
    @State private var message: String?
    @State private var connecting: AIQuotaProvider?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AI 额度连接").font(.headline)
                    Spacer()
                    Button(connections.paused ? "恢复" : "暂停全部") { connections.setPaused(!connections.paused) }
                }
                Text("当前候选仅完成离线验收，真实 CLI 接入未验证。默认关闭。本次运行有效，退出应用后全部断开。不保存凭据或连接授权。隐私模式、AI 演示、锁屏、休眠、收起面板时暂停查询。")
                connection(.codex, periodic: $periodicCodex)
                Divider()
                connection(.gemini, periodic: $periodicAGY)
                Picker("Gemini 额度组", selection: Binding(get: { connections.geminiGroup }, set: { connections.setGeminiGroup($0) })) {
                    Text("Gemini Models").tag("Gemini Models")
                    Text("Argon Models（独立组，需 CLI 支持）").tag("Argon Models")
                }
                Text("仅显示上方名称完全匹配的额度组。Gemini Models、Argon、Claude/GPT 不合并；此处不是 Google 消费者订阅额度。")
                Divider()
                Text("GLM 5.3 · 未连接").fontWeight(.semibold)
                Text("已具备套餐共享额度解析，但监控接口未公开，独立应用接入方式仍待确认。此版本不请求 GLM key。")
                Text("登录身份未必随额度返回。切换 CLI 登录账户后请先断开再连接；仅在 Codex 返回 accountId 时检测身份变化，不显示原始 ID。")
                Text("若系统沙盒阻止 CLI 读取它自己的登录状态，将显示查询失败；不会关闭沙盒、读取 token 或自动申请更大目录权限。")
                if let message { Text(message).foregroundStyle(SalaryPalette.gold) }
            }.font(.system(size: 12)).padding(16)
        }.frame(width: 430, height: 520)
            .background(Color.black.opacity(0.96))
            .preferredColorScheme(.dark)
            .onAppear {
                periodicCodex = connections.automatic.contains(.codex)
                periodicAGY = connections.automatic.contains(.gemini)
            }
    }
    private func connection(_ provider: AIQuotaProvider, periodic: Binding<Bool>) -> some View {
        let state = connections.store.state(for: provider)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(provider.title).fontWeight(.semibold)
                Spacer()
                Text(state.isConnected ? (state.snapshot == nil ? "已允许查询 · 暂无数据" : "已取得额度") : "未连接").foregroundStyle(.secondary)
            }
            if let selection = connections.selections[provider] {
                Text(selection.url.path).font(.system(size: 10)).textSelection(.enabled).lineLimit(2)
            }
            Button("选择可信的 \(provider == .codex ? "codex" : "agy") CLI…") { select(provider) }
            if let selectionError = connections.selectionErrors[provider] {
                Text(selectionError).foregroundStyle(SalaryPalette.gold)
            }
            Text(provider == .codex
                 ? "同意后，仅运行 codex app-server 的只读限额方法，由 CLI 使用现有登录向 OpenAI 查询。"
                 : "同意后，仅运行 agy --print /usage，由 CLI 使用现有登录向 Google 查询。不会提交模型推理任务。")
            Toggle("面板展开时每 5 分钟刷新", isOn: periodic)
                .disabled(state.isConnected)
            HStack {
                Button(connecting == provider ? "连接中…" : "同意并连接（本次运行）") {
                    connecting = provider; message = nil
                    Task {
                        do { try await connections.connect(provider, group: connections.geminiGroup, periodically: periodic.wrappedValue) }
                        catch { message = "无法使用所选 CLI；请检查路径和访问权限。" }
                        connecting = nil
                    }
                }
                .disabled(connections.selections[provider] == nil || connecting != nil || state.isConnected)
                Button("断开") { connections.disconnect(provider) }.disabled(!state.isConnected && connections.selections[provider] == nil)
            }
        }
    }
    private func select(_ provider: AIQuotaProvider) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = "选择"
        panel.message = "选择你已安装且信任的 \(provider == .codex ? "codex" : "agy") 可执行文件。选择本身不会查询账户。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try connections.select(provider, url: url); message = nil }
                catch { message = "只接受名称匹配、可执行的本地 CLI 文件。未建立连接。" }
            }
        }
    }
}
