import AppKit
import Combine
import Foundation

struct SalaryPreferences: Codable, Equatable {
    var tone: SalaryTone = .playful
    var privacy = false
    var sound = false
    var quietUntil: Date?
    var referenceEnabled = false
    var referenceCents: Int64 = 0
    var referenceTax: SalaryTax = .afterTax
    var referenceHumor = true
    var referenceLastShown: [String: Date] = [:]
}

struct SalaryData: Codable {
    var schema = 1
    var versions: [SalaryVersion] = []
    var days: [String: SalaryDayLedger] = [:]
    var milestones = SalaryMilestone.defaults
    var preferences = SalaryPreferences()
    var copyHistory: [String: Date] = [:]
}

struct SalaryToast: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var symbol: String
    var isDemo: Bool
}

@MainActor
final class SalaryStore: ObservableObject {
    static let shared = SalaryStore()
    @Published private(set) var data = SalaryData()
    @Published private(set) var now = Date()
    @Published private(set) var snapshot: SalarySnapshot?
    @Published var toast: SalaryToast?
    @Published private(set) var isDemo = false
    @Published var errorMessage: String?
    @Published var welcomeMessage: String?
    var interactionSources: Set<String> = []
    var visibleSources: Set<String> = []
    var requestOpenIsland: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var locked = false
    private var sleeping = false
    private var previousTick: Date?
    private var previousRealTick: Date?
    private var toastAt: Date?
    private var demoStarted: Date?
    private var demoBase: Date?
    private var demoLedger: SalaryDayLedger?
    private var loadFailed = false
    private let clock: () -> Date
    let storageURL: URL

    var configured: Bool { !data.versions.isEmpty }
    var privacy: Bool { data.preferences.privacy }
    var milestones: [SalaryMilestone] { isDemo ? SalaryMilestone.defaults : data.milestones }
    var quiet: Bool { data.preferences.quietUntil.map { $0 > clock() } ?? false }
    var currentProfile: SalaryProfile {
        SalaryEngine.activeVersion(at: clock(), versions: data.versions)?.profile ?? SalaryProfile()
    }
    var editingProfile: SalaryProfile { data.versions.last?.profile ?? SalaryProfile() }
    var todayEvents: [SalaryEvent] { isDemo ? (demoLedger?.events ?? []) : (snapshot.flatMap { data.days[$0.id]?.events } ?? []) }
    var realTodayEvents: [SalaryEvent] {
        guard let context = try? SalaryEngine.context(at: clock(), versions: data.versions) else { return [] }
        return data.days[context.id]?.events ?? []
    }
    var earnedCents: Double { snapshot?.earnedCents(at: now) ?? 0 }
    var remaining: TimeInterval { max(0, (snapshot?.shiftEnd ?? now).timeIntervalSince(now)) }
    var isFinished: Bool { snapshot?.shiftEnd.map { now >= $0 } ?? false }
    var beforeWork: Bool { snapshot?.shiftStart.map { now < $0 } ?? false }
    var onBreak: Bool {
        guard let s = snapshot, !beforeWork, !isFinished, s.isWorkday else { return false }
        return !s.intervals.contains { now >= $0.start && now < $0.end }
    }
    var clockText: String {
        guard let s = snapshot else { return "开始营业" }
        if !s.isWorkday { return "今日休息" }
        if isFinished { return "已下班" }
        let duration = beforeWork ? s.shiftStart!.timeIntervalSince(now) : remaining
        let seconds = max(0, Int(ceil(duration)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var stateLabel: String {
        guard configured || isDemo else { return "把时间换成一点甜" }
        if snapshot?.isWorkday == false { return "今日不营业" }
        if isFinished { return "生活时间开始" }
        if beforeWork { return "距离上班" }
        if onBreak { return "补给中 · 距下班" }
        return "距下班还有"
    }
    var amountText: String { privacy ? "¥•••" : SalaryEngine.formatYuan(cents: earnedCents) }

    init(storageURL: URL? = nil, clock: @escaping () -> Date = Date.init, startRuntime: Bool = true) {
        self.clock = clock
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SalaryIsland", isDirectory: true).appendingPathComponent("salary-v1.json")
        if FileManager.default.fileExists(atPath: self.storageURL.path) {
            do {
                var loaded = try JSONDecoder().decode(SalaryData.self, from: Data(contentsOf: self.storageURL))
                guard loaded.schema == 1 else { throw NSError(domain: "SalaryIsland", code: 1) }
                for version in loaded.versions { try version.profile.validate() }
                let legacy = loaded.versions
                loaded.versions = legacy.map { version in
                    var value = version
                    value.effectiveAt = SalaryEngine.activation(of: version, in: legacy)
                    value.effectiveDay = SalaryEngine.dayKey(value.effectiveAt!, timeZoneID: value.profile.schedule.timeZoneID)
                    return value
                }
                var days: [String: SalaryDayLedger] = [:]
                for var ledger in loaded.days.values {
                    let id = SalaryEngine.ledgerID(day: ledger.snapshot.dayKey, zone: ledger.snapshot.timeZoneID)
                    guard days[id] == nil else { throw SalaryStoreError("重复的薪酬记录。") }
                    ledger.snapshot.id = id; days[id] = ledger
                }
                loaded.days = days
                data = loaded
            } catch {
                loadFailed = true
                errorMessage = "本地薪酬记录无法读取，已保留原文件。请先备份后再处理，当前不会覆盖它。"
            }
        }
        guard startRuntime else { tick(); return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.toast = nil; self?.refreshTimer() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.refreshTimer() }
        })
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.locked = value; if value { self?.toast = nil }; self?.refreshTimer() }
            })
        }
        FullscreenMediaDetector.shared.$fullscreenStatus.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTimer() }
        }.store(in: &cancellables)
        tick()
        refreshTimer()
    }

    var fullscreen: Bool {
        let id = BoringViewCoordinator.shared.selectedScreenUUID
        return FullscreenMediaDetector.shared.fullscreenStatus[id] ?? false
    }

    func refreshTimer() {
        timer?.invalidate(); timer = nil
        if locked || sleeping { toast = nil; return }
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick(silent: Bool = false) {
        guard !loadFailed else { snapshot = nil; return }
        let realNow = clock()
        let date = isDemo ? (demoBase ?? realNow).addingTimeInterval(realNow.timeIntervalSince(demoStarted ?? realNow)) : realNow
        now = date
        defer { previousTick = date; previousRealTick = realNow }
        if let toastAt, realNow.timeIntervalSince(toastAt) >= 4, interactionSources.subtracting(["settings"]).isEmpty { toast = nil }
        guard configured || isDemo else { snapshot = nil; return }
        do {
            var ledger: SalaryDayLedger
            if isDemo {
                if configured {
                    let context = try SalaryEngine.context(at: realNow, versions: data.versions)
                    var realLedger = try data.days[context.id] ?? SalaryDayLedger(snapshot: SalaryEngine.snapshot(at: realNow, versions: data.versions))
                    let prior = realLedger
                    _ = realLedger.advance(now: realNow, previous: previousRealTick, milestones: data.milestones, blocked: true, busy: false)
                    if realLedger != prior || data.days[context.id] == nil {
                        var updated = data; updated.days[context.id] = realLedger; try commit(updated)
                    }
                }
                guard let demoLedger else { return }
                ledger = demoLedger
            } else {
                let context = try SalaryEngine.context(at: date, versions: data.versions)
                if let existing = data.days[context.id] { ledger = existing }
                else { ledger = SalaryDayLedger(snapshot: try SalaryEngine.snapshot(at: date, versions: data.versions)) }
            }
            let old = ledger
            snapshot = ledger.snapshot
            let c = BoringViewCoordinator.shared
            let blocked = privacy || quiet || locked || sleeping || fullscreen || visibleSources.isEmpty
            let busy = !interactionSources.isEmpty || c.sneakPeek.show || c.expandingView.show || SharingStateManager.shared.preventNotchClose || toast != nil
            let event = ledger.advance(now: date, previous: previousTick, milestones: milestones, blocked: blocked, busy: busy, silent: silent)
            if isDemo { demoLedger = ledger }
            else if old != ledger || data.days[ledger.snapshot.id] == nil {
                var updated = data; updated.days[ledger.snapshot.id] = ledger
                try commit(updated)
            }
            if let event { present(event, demo: isDemo) }
        } catch { errorMessage = "暂时无法计算：\(error.localizedDescription)" }
    }

    private func present(_ event: SalaryEvent, demo: Bool) {
        let options = SalaryCopy.variants(for: event, tone: data.preferences.tone)
        let date = clock()
        let fresh = options.filter { date.timeIntervalSince(data.copyHistory[$0] ?? .distantPast) >= 7 * 86400 }
        let message = fresh.first ?? options.first ?? event.name
        toast = SalaryToast(title: event.name, message: message, symbol: event.symbol, isDemo: demo)
        toastAt = date
        if !demo { var updated = data; updated.copyHistory[message] = date; try? commit(updated) }
        if data.preferences.sound && !privacy && !quiet { NSSound(named: "Pop")?.play() }
    }

    @discardableResult
    func setPrivacy(_ value: Bool) -> Bool {
        do {
            var updated = data; updated.preferences.privacy = value
            suppressPending(in: &updated)
            try commit(updated); toast = nil; tick(silent: true)
            return true
        } catch { return false }
    }

    @discardableResult
    func toggleQuiet() -> Bool {
        do {
            var updated = data
            if quiet { updated.preferences.quietUntil = nil }
            else {
                let realSnapshot = try? SalaryEngine.snapshot(at: clock(), versions: data.versions)
                updated.preferences.quietUntil = realSnapshot?.shiftEnd.flatMap { $0 > clock() ? $0 : nil }
                    ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: clock()))
            }
            suppressPending(in: &updated)
            try commit(updated); toast = nil; tick(silent: true)
            return true
        } catch { return false }
    }

    private func suppressPending(in value: inout SalaryData) {
        for id in Array(value.days.keys) { value.days[id]?.skipPending() }
    }

    private func proposedPlan(_ profile: SalaryProfile) throws -> (SalaryVersion, [SalaryVersion], SalarySnapshot) {
        guard !loadFailed else { throw SalaryStoreError("本地记录读取失败，已禁止覆盖。") }
        let proposed = try SalaryEngine.proposedVersion(for: profile, versions: data.versions, now: clock())
        let instant = proposed.effectiveAt!
        var versions = data.versions.filter { SalaryEngine.activation(of: $0, in: data.versions) < instant }
        versions.append(proposed)
        return (proposed, versions, try SalaryEngine.snapshot(at: instant, versions: versions))
    }

    func previewProfile(_ profile: SalaryProfile) throws -> (String, SalarySnapshot) {
        let (proposed, _, snapshot) = try proposedPlan(profile)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: profile.schedule.timeZoneID)
        return (formatter.string(from: proposed.effectiveAt!) + " · " + profile.schedule.timeZoneID, snapshot)
    }

    func saveProfile(_ profile: SalaryProfile) throws {
        let first = !configured
        let (proposed, versions, revisedSnapshot) = try proposedPlan(profile)
        var updated = data; updated.versions = versions
        if proposed.effectiveAt! <= clock() {
            var ledger = updated.days[revisedSnapshot.id] ?? SalaryDayLedger(snapshot: revisedSnapshot)
            ledger.snapshot = revisedSnapshot
            ledger.skipPending()
            _ = ledger.advance(now: clock(), previous: nil, milestones: updated.milestones, blocked: true, busy: false, silent: true)
            updated.days[revisedSnapshot.id] = ledger
        }
        try commit(updated)
        isDemo = false; demoLedger = nil; toast = nil; previousTick = nil
        tick(silent: true)
        if first { welcomeMessage = "你的工资开始按秒营业了。今天的快乐，从这里开始。" }
    }

    func correctedToday(monthlyCents: Int64) throws -> SalarySnapshot {
        guard var result = snapshot, !isDemo else { throw SalaryStoreError("请先设置正式薪酬。") }
        var p = currentProfile; p.monthlyCents = monthlyCents; try p.validate()
        result.monthlyCents = monthlyCents
        return result
    }

    func correctToday(monthlyCents: Int64) throws {
        let corrected = try correctedToday(monthlyCents: monthlyCents)
        guard var ledger = data.days[corrected.id] else { return }
        ledger.snapshot = corrected; ledger.skipPending()
        _ = ledger.advance(now: clock(), previous: nil, milestones: data.milestones, blocked: true, busy: false, silent: true)
        var updated = data; updated.days[corrected.id] = ledger
        try commit(updated); toast = nil; tick(silent: true)
    }

    func saveMilestones(_ items: [SalaryMilestone]) throws {
        guard items.count <= 5 else { throw SalaryStoreError("每日最多设置5个目标。") }
        for item in items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.count <= 16,
                  item.cents > 0, item.cents <= 100_000_000_000 else { throw SalaryStoreError("目标名称需为1–16个字，金额需大于0且不超过10亿元。") }
        }
        var updated = data; updated.milestones = items.sorted { $0.cents < $1.cents }
        suppressPending(in: &updated)
        try commit(updated); toast = nil; tick(silent: true)
    }

    func savePreferences(_ preferences: SalaryPreferences) throws {
        if preferences.referenceEnabled && !(1...100_000_000_000).contains(preferences.referenceCents) { throw SalaryStoreError("请填写有效的参考月薪。") }
        var updated = data; updated.preferences = preferences
        suppressPending(in: &updated)
        try commit(updated); toast = nil; tick(silent: true)
    }

    func referenceMessage() -> String {
        let p = data.preferences, current = currentProfile
        guard p.referenceEnabled, !privacy else { return "" }
        guard p.referenceTax == current.tax else { return "税前 / 税后口径不同，暂不比较高低。" }
        guard p.referenceCents > 0 else { return "请先填写参考月薪。" }
        let ratio = Double(current.monthlyCents - p.referenceCents) / Double(p.referenceCents)
        if abs(ratio) < 0.1 { return "与参考相差不到10%。按自己的节奏来。" }
        let key = "\(p.referenceCents)-\(p.referenceTax.rawValue)"
        if p.referenceHumor && clock().timeIntervalSince(p.referenceLastShown[key] ?? .distantPast) >= 7 * 86400 {
            var updated = data; updated.preferences.referenceLastShown[key] = clock(); try? commit(updated)
            if ratio > 0 { return "这份报价，比你设的参考更亮眼。" }
            switch p.tone {
            case .gentle: return "你的努力值得好待遇，也可以留意新机会。"
            case .playful: return "这份报价，值得再找几家问问。"
            case .bold: return "可以看看新工作了，先更新简历，别急着更新离职状态。"
            }
        }
        return "与自填参考相差 \(String(format: "%+.1f%%", ratio * 100))。这只是你设置的参考。"
    }

    func startDemo() {
        let p = SalaryProfile(monthlyCents: 1_760_000, tax: .afterTax, schedule: SalarySchedule(timeZoneID: "Asia/Shanghai"))
        let base = SalaryEngine.date(for: "2026-01-05", timeZoneID: "Asia/Shanghai").addingTimeInterval(9 * 3600 + 11 * 60 + 55)
        if let snap = try? SalaryEngine.snapshot(at: base, versions: [.init(effectiveDay: "2026-01-01", profile: p)]) {
            demoLedger = SalaryDayLedger(snapshot: snap); demoBase = base; demoStarted = clock()
            isDemo = true; previousTick = base; toast = nil; tick(silent: true)
        }
    }

    func previewCelebration() {
        guard !privacy else { return }
        present(.init(id: "preview", kind: .milestone, name: "一杯奶茶", cents: 2000, symbol: "cup.and.saucer.fill", occurredAt: clock()), demo: true)
    }

    func endDemo() { isDemo = false; demoLedger = nil; demoBase = nil; demoStarted = nil; toast = nil; previousTick = nil; tick() }

    func clearSalaryData() throws {
        try commit(SalaryData(), allowRecovery: true)
        loadFailed = false; snapshot = nil; isDemo = false; demoLedger = nil; toast = nil; previousTick = nil
        tick()
    }

    private func commit(_ candidate: SalaryData, allowRecovery: Bool = false) throws {
        guard !loadFailed || allowRecovery else {
            throw SalaryStoreError("本地薪酬记录无法读取，已保留原文件；本次修改未保存。")
        }
        do {
            let dir = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoded = try JSONEncoder().encode(candidate)
            try encoded.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
            data = candidate; errorMessage = nil
        } catch {
            let failure = SalaryStoreError("保存失败，请检查磁盘空间与文件权限。本次修改未保存。")
            errorMessage = failure.message
            throw failure
        }
    }

}

struct SalaryStoreError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
