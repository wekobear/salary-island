import SwiftUI
import AppKit

enum SalaryPalette {
    static let mint = Color(red: 0.68, green: 0.95, blue: 0.71)
    static let gold = Color(red: 1, green: 0.84, blue: 0.52)
    static let dim = Color.white.opacity(0.55)
}

struct SalaryCompactView: View {
    @ObservedObject private var store: SalaryStore
    let centerWidth: CGFloat
    let height: CGFloat
    init(centerWidth: CGFloat, height: CGFloat, store: SalaryStore? = nil) {
        self.centerWidth = centerWidth; self.height = height; self.store = store ?? .shared
    }
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: store.isFinished ? "checkmark" : "hourglass")
                    .font(.system(size: 10, weight: .semibold))
                Text(store.clockText).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(SalaryPalette.mint).frame(width: 111)
            Color.black.frame(width: max(0, centerWidth - 10))
            HStack(spacing: 3) {
                SalaryWalletView(state: store.walletState, compact: true)
                    .frame(width: 22, height: 22)
                Text(store.isDemo ? "演示 \(store.amountText)" : (store.configured ? store.amountText : "薪动日常"))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(SalaryPalette.gold)
            }.frame(width: 111)
        }.frame(height: height).accessibilityElement(children: .combine)
    }
}

struct SalaryDashboardView: View {
    @ObservedObject private var store: SalaryStore
    init(store: SalaryStore? = nil) { self.store = store ?? .shared }
    @State private var showReference = false
    @State private var showAllMilestones = false
    @State private var referenceText = ""
    @State private var actionFeedback: String?
    @State private var actionFeedbackSymbol = "checkmark.circle.fill"
    @State private var actionFeedbackID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.snapshot == nil {
                if let toast = store.toast { feedback(toast) } else { welcome }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.stateLabel).font(.system(size: 11)).foregroundStyle(SalaryPalette.dim)
                        Text(store.clockText).font(.system(size: 28, weight: .medium, design: .monospaced))
                            .foregroundStyle(SalaryPalette.mint).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        Button { SalaryWalletPreviewWindow.shared.show() } label: {
                            SalaryWalletView(state: store.walletState, celebrationID: store.walletRewardID,
                                             claimCelebration: store.consumeWalletReward)
                                .frame(width: 86, height: 72)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("钱包随今日收入慢慢鼓起 · 点击预览动效")
                        .accessibilityLabel("预览心动钱包")
                        VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle().fill(SalaryPalette.mint).frame(width: 5, height: 5)
                            Text(store.isDemo ? "演示数据 · 今日估算收入" : "今日估算收入")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(SalaryPalette.dim)
                        }
                        Text(store.amountText)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit().foregroundStyle(SalaryPalette.gold)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .accessibilityLabel("今日估算收入 \(store.amountText)")
                        }
                    }
                }
                if let snapshot = store.snapshot {
                    HStack(spacing: 0) {
                        rate("每秒", value: snapshot.hourlyYuan / 3600, digits: 4)
                        Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 22)
                        rate("每分钟", value: snapshot.hourlyYuan / 60, digits: 2)
                        Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 22)
                        rate("每小时", value: snapshot.hourlyYuan, digits: 2)
                    }.padding(.vertical, 9).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                }
                if store.privacy {
                    Label("收入和快乐清单已藏好，只管等下班。", systemImage: "eye.slash")
                        .foregroundStyle(SalaryPalette.dim).font(.system(size: 12)).frame(height: 78)
                } else if let toast = store.toast {
                    feedback(toast)
                } else {
                    milestoneRow
                }
            }
            SalaryAIQuotaSection(privacy: store.privacy)
            footer
        }
        .padding(.horizontal, 6).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .overlay(alignment: .bottom) {
            if let actionFeedback {
                Label(actionFeedback, systemImage: actionFeedbackSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SalaryPalette.mint)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(white: 0.13), in: Capsule())
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: actionFeedback)
        .task(id: actionFeedbackID) {
            guard actionFeedback != nil else { return }
            do { try await Task.sleep(for: .seconds(2.5)) }
            catch { return }
            actionFeedback = nil
        }
        .onDisappear { actionFeedback = nil }
        .popover(isPresented: $showReference) {
            VStack(alignment: .leading, spacing: 12) {
                Text("你设置的参考值").font(.headline)
                if store.privacy { Text("隐私模式已隐藏内容。") }
                else {
                    Text("\(SalaryEngine.formatYuan(cents: Double(store.data.preferences.referenceCents))) / 月 · \(store.data.preferences.referenceTax.label)")
                    if store.currentProfile.tax == store.data.preferences.referenceTax {
                        let diff = store.currentProfile.monthlyCents - store.data.preferences.referenceCents
                        Text("你的月薪与参考差额：\(diff >= 0 ? "+" : "−")\(SalaryEngine.formatYuan(cents: abs(Double(diff))))").font(.subheadline)
                    }
                    Text(referenceText).foregroundStyle(.secondary)
                }
                Text("自填参考不是城市平均工资。").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(width: 320)
        }
    }

    private var welcome: some View {
        HStack(spacing: 22) {
            Image("SalaryLogo").resizable().scaledToFit()
                .frame(width: 100, height: 100).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text("每一秒，都有一点甜。").font(.system(size: 22, weight: .semibold))
                Text("等下班的时候，看时间变成奶茶、好饭，\n和一件喜欢的衣服。")
                    .font(.system(size: 13)).foregroundStyle(SalaryPalette.dim).lineSpacing(3)
                HStack {
                    Button("设置我的薪酬") { SalarySettingsWindow.shared.show() }.buttonStyle(.borderedProminent).tint(SalaryPalette.mint).foregroundStyle(.black)
                    Button("先看演示") { store.startDemo() }.buttonStyle(.bordered)
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    }

    private func rate(_ label: String, value: Double, digits: Int) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(SalaryPalette.dim)
            Text(store.privacy ? "•••" : (value > 0 && value < 0.0001 ? "<¥0.0001" : "¥" + String(format: "%.*f", digits, value)))
                .monospacedDigit().foregroundStyle(.white.opacity(0.9))
        }.font(.system(size: 11)).frame(maxWidth: .infinity).lineLimit(1).minimumScaleFactor(0.7)
    }

    private var milestoneRow: some View {
        let items = store.milestones.filter(\.enabled)
        let pending = items.filter { item in !store.goalReached(item) }
        let achieved = items.filter { item in store.goalReached(item) }
        return VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Label("今天只看时间，快乐由你安排。", systemImage: "sun.max")
                    .font(.system(size: 12)).foregroundStyle(SalaryPalette.dim).frame(maxWidth: .infinity, minHeight: 68)
            } else {
                HStack {
                    Text(pending.isEmpty ? "今天的小快乐" : "下一份小快乐").foregroundStyle(SalaryPalette.dim)
                    Spacer()
                    Button("查看全部 · \(items.count)") { showAllMilestones = true }
                        .buttonStyle(.plain).foregroundStyle(SalaryPalette.mint)
                        .popover(isPresented: $showAllMilestones) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("我的快乐清单").font(.headline)
                                if store.privacy { Text("快乐清单已隐藏。") }
                                else {
                                    ForEach(items) { item in milestoneCard(item) }
                                    Text("累计目标跨天保留，每日目标次日重算。都是估算工资，不是实际存款；各项独立比较。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(16).frame(width: 300)
                        }
                }.font(.system(size: 10))
                HStack(spacing: 8) {
                    ForEach(Array((pending + achieved.reversed()).prefix(2))) { item in milestoneCard(item) }
                }
            }
        }.frame(height: 78)
    }

    private func milestoneCard(_ item: SalaryMilestone) -> some View {
        let achieved = store.todayEvents.first { $0.id == "milestone:" + item.id }
        let reached = store.goalReached(item)
        let cumulative = !store.isDemo && item.mode == .cumulative
        let progress = reached ? 1 : min(1, max(0, Double(store.goalEarnedCents(item)) / Double(item.cents)))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: reached ? "checkmark.circle.fill" : item.symbol)
                    .foregroundStyle(reached ? SalaryPalette.mint : SalaryPalette.gold)
                Text(cumulative ? item.name : (achieved?.name ?? item.name)).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 0)
            }.font(.system(size: 11))
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.09))
                    .overlay(alignment: .leading) {
                        Capsule().fill(reached ? SalaryPalette.mint : SalaryPalette.gold)
                            .frame(width: geometry.size.width * progress)
                    }
            }.frame(height: 3).padding(.vertical, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name + (cumulative ? "累计进度" : "今日进度"))
                .accessibilityValue("\(Int(progress * 100))%")
            Text(reached ? (cumulative ? "累计目标已达成" : (achieved?.cents == item.cents ? "今日已达成" : "按原目标达成")) : targetDetail(item))
                .font(.system(size: 10)).foregroundStyle(SalaryPalette.dim).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .help(cumulative ? "累计估算 \(SalaryEngine.formatYuan(cents: Double(store.goalEarnedCents(item)))) / \(SalaryEngine.formatYuan(cents: Double(item.cents)))；跨天保留，不是实际存款。" : "按今日估算收入计算，次日重新开始。")
            .background(reached ? SalaryPalette.mint.opacity(0.08) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
    }

    private func targetDetail(_ item: SalaryMilestone) -> String {
        if !store.isDemo && item.mode == .cumulative {
            let earned = store.goalEarnedCents(item)
            let percent = min(100, Int(Double(earned) / Double(item.cents) * 100))
            let remaining = SalaryEngine.formatYuan(cents: Double(max(0, item.cents - earned)))
            return "累计 \(percent)% · 还差\(remaining)"
        }
        guard let s = store.snapshot, s.dayCents > 0 else { return "\(SalaryEngine.formatYuan(cents: Double(item.cents))) · 等待营业" }
        if Double(item.cents) > s.dayCents { return "约合 \(Int(ceil(Double(item.cents) / s.dayCents))) 天工资" }
        let rate = s.hourlyYuan * 100 / 60
        return "再工作约\(max(1, Int(ceil((Double(item.cents) - store.earnedCents) / max(rate, 0.000001)))))分钟"
    }

    private func feedback(_ toast: SalaryToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: toast.symbol).font(.system(size: 25)).foregroundStyle(SalaryPalette.gold)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(toast.isDemo ? "演示 · " + toast.title : toast.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(SalaryPalette.mint)
                Text(toast.message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { store.toast = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(SalaryPalette.dim).help("收下这份快乐")
        }.padding(12).frame(maxWidth: .infinity, minHeight: 78, maxHeight: 78, alignment: .leading)
            .background(SalaryPalette.gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if store.isDemo {
                Button("退出演示") { store.endDemo() }.foregroundStyle(SalaryPalette.gold)
            } else {
                Text(store.isFinished ? "今日营业结束，快乐正式开张。" : "时间有价，快乐无价。")
                    .foregroundStyle(SalaryPalette.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if store.data.preferences.referenceEnabled && !store.isDemo {
                Button { referenceText = store.referenceMessage(); showReference = true } label: { Image(systemName: "equal.square") }.help("查看薪资参考")
            }
            Button {
                guard store.setPrivacy(!store.privacy) else { showActionFeedback("修改未保存，请检查磁盘空间与权限", symbol: "exclamationmark.circle"); return }
                showActionFeedback(store.privacy ? "金额与快乐清单已隐藏" : "金额与快乐清单已显示", symbol: store.privacy ? "eye.slash.fill" : "eye")
            } label: { Image(systemName: store.privacy ? "eye.slash.fill" : "eye") }.help("隐私模式").accessibilityLabel("切换隐私模式")
            Button {
                guard store.toggleQuiet() else { showActionFeedback("修改未保存，请检查磁盘空间与权限", symbol: "exclamationmark.circle"); return }
                showActionFeedback(store.quiet ? "安静模式已开启，暂停自动提示" : "已恢复自动提示", symbol: store.quiet ? "bell.slash.fill" : "bell")
            } label: { Image(systemName: store.quiet ? "bell.slash.fill" : "bell") }.help(store.quiet ? "恢复提示" : "安静到下班").accessibilityLabel(store.quiet ? "恢复提示" : "安静到下班")
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.top, 2)
    }

    private func showActionFeedback(_ message: String, symbol: String) {
        actionFeedbackSymbol = symbol
        actionFeedback = message
        actionFeedbackID = UUID()
    }
}

@MainActor
final class SalarySettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SalarySettingsWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "薪动日常 · 今天也有小快乐"
            window.minSize = NSSize(width: 780, height: 620)
            window.contentView = NSHostingView(rootView: SalarySettingsView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) { SalaryStore.shared.interactionSources.insert("settings") }
    func windowDidResignKey(_ notification: Notification) { SalaryStore.shared.interactionSources.remove("settings") }
    func windowDidMiniaturize(_ notification: Notification) { SalaryStore.shared.interactionSources.remove("settings") }
    func windowWillClose(_ notification: Notification) { SalaryStore.shared.interactionSources.remove("settings") }
    func hide() { window?.orderOut(nil); SalaryStore.shared.interactionSources.remove("settings") }
}
