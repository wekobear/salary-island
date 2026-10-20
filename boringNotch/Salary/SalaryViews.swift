import SwiftUI
import AppKit

enum SalaryPalette {
    static let mint = Color(red: 0.68, green: 0.95, blue: 0.71)
    static let gold = Color(red: 1, green: 0.84, blue: 0.52)
    static let dim = Color.white.opacity(0.55)
}

struct SalaryCompactView: View {
    @ObservedObject private var store = SalaryStore.shared
    let centerWidth: CGFloat
    let height: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: store.isFinished ? "checkmark" : "hourglass")
                    .font(.system(size: 10, weight: .semibold))
                Text(store.clockText).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(SalaryPalette.mint).frame(width: 111)
            Color.black.frame(width: max(0, centerWidth - 10))
            Text(store.isDemo ? "演示 · \(store.amountText)" : (store.configured ? store.amountText : "薪动岛"))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(SalaryPalette.gold).frame(width: 111)
        }.frame(height: height).accessibilityElement(children: .combine)
    }
}

struct SalaryDashboardView: View {
    @ObservedObject private var store = SalaryStore.shared
    @State private var showReference = false
    @State private var referenceText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let toast = store.toast {
                feedback(toast)
            } else if store.snapshot == nil {
                welcome
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
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
                    Spacer(minLength: 16)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(store.stateLabel).font(.system(size: 11)).foregroundStyle(SalaryPalette.dim)
                        Text(store.clockText).font(.system(size: 28, weight: .medium, design: .monospaced))
                            .foregroundStyle(SalaryPalette.mint).lineLimit(1).minimumScaleFactor(0.7)
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
                        .foregroundStyle(SalaryPalette.dim).font(.system(size: 12)).frame(height: 48)
                } else {
                    milestoneRow
                }
            }
            footer
        }
        .padding(.horizontal, 6).padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
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
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(SalaryPalette.mint.opacity(0.13)).frame(width: 88, height: 100)
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 36)).foregroundStyle(SalaryPalette.mint)
            }
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
        HStack(spacing: 8) {
            let items = store.milestones.filter(\.enabled)
            if items.isEmpty {
                Label("今天只看时间，快乐由你安排。", systemImage: "sun.max")
                    .font(.system(size: 12)).foregroundStyle(SalaryPalette.dim).frame(maxWidth: .infinity, minHeight: 52)
            } else {
                ForEach(items.prefix(3)) { item in
                    let achieved = store.todayEvents.first { $0.id == "milestone:" + item.id }
                    let reached = achieved != nil
                    HStack(spacing: 7) {
                        Image(systemName: reached ? "checkmark.circle.fill" : item.symbol)
                            .font(.system(size: 17)).foregroundStyle(reached ? SalaryPalette.mint : SalaryPalette.gold)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(achieved?.name ?? item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(reached ? (achieved?.cents == item.cents ? "今日已达成" : "按原目标达成") : targetDetail(item)).font(.system(size: 10)).foregroundStyle(SalaryPalette.dim).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.padding(9).frame(maxWidth: .infinity)
                        .background(reached ? SalaryPalette.mint.opacity(0.08) : .white.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                }
            }
        }.frame(height: 54)
        .help("今日收入可分别覆盖的单项价格，不代表已消费，也不能将物品金额相加。全部目标可在设置中查看。")
    }

    private func targetDetail(_ item: SalaryMilestone) -> String {
        guard let s = store.snapshot, s.dayCents > 0 else { return "\(SalaryEngine.formatYuan(cents: Double(item.cents))) · 等待营业" }
        if Double(item.cents) > s.dayCents { return "约需\(Int(ceil(Double(item.cents) / s.dayCents)))个相同班次" }
        let rate = s.hourlyYuan * 100 / 60
        return "还需约\(max(1, Int(ceil((Double(item.cents) - store.earnedCents) / max(rate, 0.000001)))))个计薪分钟"
    }

    private func feedback(_ toast: SalaryToast) -> some View {
        HStack(spacing: 22) {
            Image(systemName: toast.symbol).font(.system(size: 42)).foregroundStyle(SalaryPalette.gold)
                .frame(width: 80, height: 100).background(SalaryPalette.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 10) {
                Text(toast.isDemo ? "效果预览 · 不记录成就" : "一份小快乐，已解锁")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(SalaryPalette.mint)
                Text(toast.title).font(.system(size: 25, weight: .semibold))
                Text(toast.message).font(.system(size: 14)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                Button("收下这份快乐") { store.toast = nil }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(SalaryPalette.mint)
            }
        }.frame(maxWidth: .infinity, minHeight: 190, alignment: .leading)
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
            Button { store.setPrivacy(!store.privacy) } label: { Image(systemName: store.privacy ? "eye.slash.fill" : "eye") }.help("隐私模式").accessibilityLabel("切换隐私模式")
            Button { store.toggleQuiet() } label: { Image(systemName: store.quiet ? "bell.slash.fill" : "bell") }.help(store.quiet ? "恢复提示" : "安静到下班").accessibilityLabel(store.quiet ? "恢复提示" : "安静到下班")
            Button { SalarySettingsWindow.shared.show() } label: { Image(systemName: "slider.horizontal.3") }.help("薪酬与快乐设置").accessibilityLabel("薪酬与快乐设置")
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).padding(.top, 2)
    }
}

@MainActor
final class SalarySettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SalarySettingsWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "薪动岛 · 今天也有小快乐"
            window.minSize = NSSize(width: 780, height: 620)
            window.contentView = NSHostingView(rootView: SalarySettingsView())
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        SalaryStore.shared.interactionSources.insert("settings")
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { SalaryStore.shared.interactionSources.remove("settings") }
    func hide() { window?.orderOut(nil); SalaryStore.shared.interactionSources.remove("settings") }
}
