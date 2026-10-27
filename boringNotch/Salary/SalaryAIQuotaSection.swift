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
            #if DEBUG
            if !connections.visibleProviders.isEmpty && !demo {
                panel(at: context.date)
            }
            #else
            EmptyView()
            #endif
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

    private func panel(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(demo ? "AI 额度 · 演示数据" : "AI 额度").font(.system(size: 11, weight: .medium))
                Spacer()
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
                    ForEach(connections.visibleProviders) { provider in card(provider, now: now).frame(minWidth: 165) }
                }
                VStack(spacing: 8) {
                    ForEach(connections.visibleProviders) { provider in card(provider, now: now) }
                }
            }
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
                if !hidden, let snapshot = value.snapshot {
                    Text("更新 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 8)).foregroundStyle(SalaryPalette.dim).lineLimit(1)
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
                        Text(demo ? "来源：本地虚构演示，未查询任何账户" : (provider == .gemini ? "来源：所选 AGY CLI /usage（身份未核验）" : (snapshot.backendAccountID == nil ? "来源：所选登录配置（身份未核验）" : "来源：所选登录配置（可检测身份变化）")))
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
                        Button("手动刷新") { Task { await connections.refresh(provider, manual: true) } }
                            .disabled(value.isRefreshing || (value.error != nil && value.nextRefreshAt.map { $0 > now } == true))
                        if value.error != nil, let retry = value.nextRefreshAt, retry > now {
                            Text("等待重试至 \(retry.formatted(date: .omitted, time: .standard))")
                        }
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
        case .sourceChanged: return "登录来源已改变 · 请重新连接"
        case .rpcRejected: return "无法查询 · 请检查登录或 CLI 版本"
        case .launchFailed: return "CLI 启动失败 · 请检查可执行文件"
        case .pipeFailed: return "CLI 通信中断 · 已停止查询"
        case .exitedNonzero(let code): return "CLI 异常退出（代码 \(code)）"
        case .terminatedBySignal(let signal): return "CLI 被信号终止（信号 \(signal)）"
        case .emptyOutput: return "CLI 未返回数据"
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
struct AIQuotaConnectionPanel: View {
    @ObservedObject var connections: AIQuotaConnections
    @State private var periodic: Set<AIQuotaProvider> = []
    @State private var accepted: Set<AIQuotaProvider> = []
    @State private var message: String?
    @State private var connecting: AIQuotaProvider?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("AI 额度连接 · 开发候选").font(.headline)
                    Spacer()
                    Button(connections.paused ? "恢复" : "暂停全部") { connections.setPaused(!connections.paused) }
                }
                Text("Codex 和 Gemini 通过现有 CLI 查询。默认关闭，选择来源不会查询；勾选并连接后才允许本次访问。")
                ForEach(AIQuotaConnections.availableProviders, id: \.self) { provider in
                    connection(provider)
                    Divider()
                }
                Text("Gemini 仅显示 Antigravity 返回的 Gemini Models 额度组，不代表 Google 消费者订阅。")
                Text("隐私模式、演示、锁屏、休眠、收起面板或暂停时停止查询；断开和退出撤销本次访问。切换登录来源后请断开再连接。")
                Text("CLI 的接口或报告格式可能变化。查询失败时保留明确错误；遵循系统 TLS 校验与访问限制。")
                if let message { Text(message).foregroundStyle(SalaryPalette.gold) }
            }.font(.system(size: 12)).padding(16)
        }.frame(width: 460, height: 590)
            .background(Color.black.opacity(0.96))
            .preferredColorScheme(.dark)
    }
    private func binding(_ values: Binding<Set<AIQuotaProvider>>, _ provider: AIQuotaProvider) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(provider) }, set: { enabled in
            if enabled { values.wrappedValue.insert(provider) } else { values.wrappedValue.remove(provider) }
        })
    }
    @ViewBuilder private func connection(_ provider: AIQuotaProvider) -> some View {
        let state = connections.store.state(for: provider)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(provider.title).fontWeight(.semibold)
                Spacer()
                Text(state.isConnected ? (state.snapshot == nil ? "已允许查询 · 暂无数据" : "已取得额度") : "未连接").foregroundStyle(.secondary)
            }
            Text(sourceDescription(provider))
            if let selection = connections.selections[provider] {
                Text("已选择：\(selection.url.lastPathComponent)").font(.system(size: 10))
            }
            if let file = connections.codenotchFiles[provider] {
                Text("已选择：\(file.lastPathComponent)").font(.system(size: 10))
            }
            if provider == .glm ? connections.codenotchFiles[provider] == nil : connections.selections[provider] == nil {
                Text("默认来源：\(defaultSourceLabel(provider))").font(.system(size: 10))
            }
            Button(provider == .glm ? "更改 Claude Code 配置文件…" : "更改 \(provider == .gemini ? "agy" : "codex") 可执行文件…") {
                if provider == .glm { selectGLM() } else { selectCLI(provider) }
            }.disabled(connecting != nil)
            Text(targetDescription(provider)).font(.system(size: 11))
            if provider == .gemini {
                Toggle("允许本次以现有 CLI 登录运行所选 agy 的 /usage 查询额度", isOn: binding($accepted, provider))
                    .disabled(state.isConnected)
            } else if provider == .codex {
                Toggle("允许本次以现有 Codex CLI 登录查询额度", isOn: binding($accepted, provider))
                    .disabled(state.isConnected)
            } else {
                Toggle("允许本次读取 Claude Code 智谱配置并向上述目标发送认证信息", isOn: binding($accepted, provider))
                    .disabled(state.isConnected)
            }
            Toggle("每 5 分钟刷新，到期补查一次（面板展开时）", isOn: binding($periodic, provider)).disabled(state.isConnected)
            HStack {
                Button(connecting == provider ? "连接中…" : "同意并连接（本次运行）") {
                    connecting = provider; message = nil
                    Task {
                        do {
                            try connections.prepareDefaultSourceIfNeeded(provider, home: FileManager.default.homeDirectoryForCurrentUser)
                            if provider == .glm {
                                try await connections.connectCodenotch(.glm, periodically: periodic.contains(provider))
                            } else {
                                try await connections.connect(provider, group: connections.geminiGroup, periodically: periodic.contains(provider))
                            }
                        }
                        catch DefaultQuotaSourceError.missing { message = "默认来源不存在，请使用“更改”选择正确文件。" }
                        catch { message = "无法使用所选来源，请检查文件类型与访问权限。" }
                        connecting = nil
                    }
                }.disabled(!accepted.contains(provider) || connecting != nil || state.isConnected)
                Button("断开") { connections.disconnect(provider); accepted.remove(provider); periodic.remove(provider) }
                    .disabled(!state.isConnected && (provider == .glm ? connections.codenotchFiles[provider] == nil : connections.selections[provider] == nil))
            }
        }
    }
    private func defaultSourceLabel(_ provider: AIQuotaProvider) -> String {
        switch provider {
        case .codex: return "~/.local/bin/codex"
        case .gemini: return "~/.local/bin/agy"
        case .glm: return "~/.claude/settings.json"
        }
    }
    private func sourceDescription(_ provider: AIQuotaProvider) -> String {
        switch provider {
        case .codex: return "Codex CLI 可执行文件；以现有登录读取账户额度。"
        case .gemini: return "Antigravity CLI（agy）可执行文件；以现有 CLI 登录运行 /usage 查询额度，不读取 OAuth 凭据文件、钥匙串或 IDE 信息。"
        case .glm: return "仅 Claude Code settings.json 的 GLM API 配置；不会读取或操作 Z Code。"
        }
    }
    private func targetDescription(_ provider: AIQuotaProvider) -> String {
        switch provider {
        case .codex: return "本地运行 Codex app-server，仅通过标准输入输出查询额度；认证由 CLI 处理。"
        case .gemini: return "本地运行所选 agy 的 /usage；认证与请求均由该 CLI 的现有登录完成，本应用不读取或发送凭据，不伪装官方客户端。"
        case .glm: return "按所选 GLM 配置，仅发送至 api.z.ai 或 open.bigmodel.cn 的 /api/monitor/usage/quota/limit；这是未公开的监控接口。"
        }
    }
    private func selectGLM() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = "选择"
        panel.message = "选择 Claude Code 智谱配置文件；选择本身不会读取或查询。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try connections.selectCodenotch(.glm, url: url); accepted.remove(.glm); message = nil }
                catch { message = "无法选择此来源。未建立连接。" }
            }
        }
    }
    private func selectCLI(_ provider: AIQuotaProvider) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.prompt = "选择"
        panel.message = "选择对应 CLI 可执行文件。选择本身不会查询账户。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try connections.select(provider, url: url); accepted.remove(provider); message = nil }
                catch { message = "无法选择此来源。未建立连接。" }
            }
        }
    }
}
