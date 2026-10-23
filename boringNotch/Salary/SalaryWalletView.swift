import SwiftUI
import AppKit

struct SalaryWalletView: View {
    let state: SalaryWalletState
    var compact = false
    var celebrationID: UUID? = nil
    var claimCelebration: (() -> Bool)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownProgress = 0.0
    @State private var scale = 1.0
    @State private var lift = 0.0
    @State private var coinPosition = 0.0
    @State private var coinVisible = false
    @State private var effect: Effect = .none
    @State private var effectID = UUID()
    @State private var highestQuarter = 0

    init(state: SalaryWalletState, compact: Bool = false, celebrationID: UUID? = nil,
         claimCelebration: (() -> Bool)? = nil) {
        self.state = state; self.compact = compact
        self.celebrationID = celebrationID; self.claimCelebration = claimCelebration
        _shownProgress = State(initialValue: state.displayedProgress)
        _highestQuarter = State(initialValue: state.quarter)
    }

    private enum Effect { case none, coin, celebration }
    private var motionEnabled: Bool { state.motionAllowed && !state.hidden && !reduceMotion }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SalaryWalletArtwork(progress: shownProgress, compact: compact)
                    .saturation(state.hidden ? 0.12 : 1)
                    .opacity(state.hidden ? 0.6 : 1)
                    .scaleEffect(x: scale, y: 1 / scale, anchor: .bottom)
                    .offset(y: lift)
                if coinVisible {
                    Ellipse()
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.91, blue: 0.65), SalaryPalette.gold,
                                                       Color(red: 0.79, green: 0.52, blue: 0.20)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Ellipse().stroke(.white.opacity(0.35), lineWidth: compact ? 0.4 : 0.8))
                        .frame(width: geometry.size.width * 0.16, height: geometry.size.width * 0.18)
                        .position(x: geometry.size.width * 0.5,
                                  y: geometry.size.height * (0.04 + coinPosition * (0.62 - shownProgress * 0.30)))
                        .opacity(coinPosition > 0.85 ? 0 : 1)
                }
                if state.hidden {
                    Image(systemName: "lock.fill")
                        .font(.system(size: compact ? 8 : 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日收入进度")
        .accessibilityValue(state.hidden ? "已隐藏" : "\(Int(state.displayedProgress * 100))%")
        .onAppear {
            highestQuarter = state.quarter
            reset()
            celebrateIfFresh()
        }
        .onDisappear { cancelMotion() }
        .onChange(of: state) { old, new in
            let unseenQuarter = new.quarter > highestQuarter
            highestQuarter = old.snapshot != new.snapshot || old.demo != new.demo || old.revision != new.revision
                ? new.quarter : max(highestQuarter, new.quarter)
            guard motionEnabled, new.isLiveContinuation(of: old) else { reset(); return }
            withAnimation(.easeOut(duration: 0.22)) { shownProgress = new.displayedProgress }
            if unseenQuarter, new.crossesQuarter(since: old), effect != .celebration { start(.coin) }
        }
        .onChange(of: reduceMotion) { _, _ in reset() }
        .onChange(of: celebrationID) { _, new in
            if new != nil { celebrateIfFresh() }
        }
        .task(id: effectID) {
            let token = effectID
            guard motionEnabled, effect != .none else { return }
            if effect == .coin {
                coinPosition = 0; coinVisible = true
                withAnimation(.easeIn(duration: 0.38)) { coinPosition = 1 }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard token == effectID else { return }
                coinVisible = false
            }
            withAnimation(.easeOut(duration: 0.12)) { scale = 1.055; lift = compact ? -0.5 : -2 }
            do { try await Task.sleep(for: .milliseconds(130)) } catch { return }
            guard token == effectID else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.64)) { scale = 1; lift = 0 }
            do { try await Task.sleep(for: .milliseconds(360)) } catch { return }
            guard token == effectID else { return }
            effect = .none
        }
    }

    private func celebrateIfFresh() {
        guard celebrationID != nil else { return }
        let fresh = claimCelebration?() ?? true
        if fresh && motionEnabled { start(.celebration) }
    }

    private func start(_ newEffect: Effect) {
        cancelMotion()
        effect = newEffect
        effectID = UUID()
    }

    private func cancelMotion() {
        effectID = UUID()
        effect = .none
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { scale = 1; lift = 0; coinVisible = false; coinPosition = 0 }
    }

    private func reset() {
        cancelMotion()
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { shownProgress = state.displayedProgress }
    }
}

/// Visual sandbox only: no store, salary configuration, or achievement writes.
struct SalaryWalletPreviewView: View {
    @State private var progress = 0.0
    @State private var date = Date()
    @State private var playing = false
    @State private var celebrationID: UUID?
    @State private var revision = UUID()

    private var sample: SalaryWalletState {
        .init(progress: progress, date: date, snapshot: nil, demo: true, revision: revision)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("心动钱包").font(.headline)
            HStack(alignment: .center, spacing: 32) {
                SalaryWalletView(state: sample, celebrationID: celebrationID).frame(width: 132, height: 110)
                VStack(spacing: 8) {
                    HStack(spacing: 5) {
                        SalaryWalletView(state: sample, compact: true, celebrationID: celebrationID)
                            .frame(width: 22, height: 22)
                        Text("¥88.88").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(SalaryPalette.gold)
                    }.padding(8).background(.black, in: Capsule())
                    Text("收起态 · 实际大小").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                ForEach(0..<5) { step in
                    Button("\(step * 25)%") {
                        playing = false
                        date = Date(); progress = Double(step) / 4
                    }.buttonStyle(.bordered).tint(progress == Double(step) / 4 ? SalaryPalette.mint : .gray)
                }
            }
            Button { playing.toggle() } label: {
                Text(playing ? "停止演示" : "播放从瘪到鼓")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(SalaryPalette.mint, in: RoundedRectangle(cornerRadius: 9))
            }.buttonStyle(.plain)
            Text("仅演示外观，不修改薪酬与累计目标。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 360).background(Color(white: 0.06))
        .task(id: playing) {
            guard playing else { return }
            progress = 0; date = Date(); celebrationID = nil; revision = UUID()
            for step in 1...60 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard playing else { return }
                date = Date(); progress = Double(step) / 60
            }
            celebrationID = UUID()
            playing = false
        }
        .onDisappear { playing = false }
    }
}

/// Keep the visual sandbox independent of the notch's hover-to-close lifecycle.
@MainActor
final class SalaryWalletPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = SalaryWalletPreviewWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 330),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "心动钱包 · 外观演示"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        window?.contentView = NSHostingView(rootView: SalaryWalletPreviewView().preferredColorScheme(.dark))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
    }
}
