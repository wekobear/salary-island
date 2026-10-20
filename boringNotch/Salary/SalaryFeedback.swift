import Foundation

enum SalaryTone: String, Codable, CaseIterable {
    case gentle, playful, bold
    var label: String { switch self { case .gentle: return "温柔"; case .playful: return "抽象"; case .bold: return "嘴替" } }
}

struct SalaryMilestone: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var cents: Int64
    var symbol: String
    var enabled = true
    static var defaults: [SalaryMilestone] { [
        .init(id: "tea", name: "一杯奶茶", cents: 2000, symbol: "cup.and.saucer.fill"),
        .init(id: "meal", name: "一顿好饭", cents: 5000, symbol: "fork.knife"),
        .init(id: "clothes", name: "一件衣服", cents: 20000, symbol: "tshirt.fill")
    ] }
}

struct SalaryEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case milestone, halfway, reminder, finish }
    var id: String
    var kind: Kind
    var name: String
    var cents: Int64 = 0
    var symbol: String
    var occurredAt: Date
    var displayed = false
    var skipped = false
    var priority: Int { switch kind { case .finish: return 4; case .reminder: return 3; case .milestone: return 2; case .halfway: return 1 } }
    func expires(at end: Date) -> Date {
        switch kind { case .finish: return end.addingTimeInterval(30); case .reminder: return end; default: return min(end, occurredAt.addingTimeInterval(1800)) }
    }
}

struct SalaryDayLedger: Codable, Equatable {
    var snapshot: SalarySnapshot
    var events: [SalaryEvent] = []
    var pendingID: String?
    var lastDisplayedAt: Date?
    var ordinaryCount = 0
    var rewardCount = 0

    /// Facts and presentation are separate. Blocked or stale facts are retained but never replayed.
    mutating func advance(now: Date, previous: Date?, milestones: [SalaryMilestone], blocked: Bool, busy: Bool, silent: Bool = false) -> SalaryEvent? {
        guard let end = snapshot.shiftEnd, snapshot.isWorkday else { return nil }
        if let previous, now < previous { skipPending() }
        var candidates: [SalaryEvent] = []
        for m in milestones where m.enabled && snapshot.reached(cents: m.cents, at: now) {
            let id = "milestone:" + m.id
            guard !events.contains(where: { $0.id == id }) else { continue }
            if let crossing = snapshot.crossingDate(cents: m.cents) {
                candidates.append(SalaryEvent(id: id, kind: .milestone, name: m.name, cents: m.cents, symbol: m.symbol, occurredAt: crossing))
            }
        }
        let enabled = milestones.filter(\.enabled)
        if !enabled.isEmpty && enabled.allSatisfy({ !snapshot.reached(cents: $0.cents, at: end) }), snapshot.progress(at: now) >= 0.5, !events.contains(where: { $0.id == "halfway" }) {
            let target = (snapshot.plannedSeconds + 1) / 2
            var remaining = target
            var crossing = end
            for interval in snapshot.intervals {
                let length = Int64(interval.end.timeIntervalSince(interval.start))
                if remaining <= length { crossing = interval.start.addingTimeInterval(Double(remaining)); break }
                remaining -= length
            }
            candidates.append(.init(id: "halfway", kind: .halfway, name: "半场结束", symbol: "flag.checkered", occurredAt: crossing))
        }
        let reminder = end.addingTimeInterval(-300)
        if now >= reminder && !events.contains(where: { $0.id == "reminder" }) {
            candidates.append(.init(id: "reminder", kind: .reminder, name: "准备下班", symbol: "figure.walk", occurredAt: reminder))
        }
        if now >= end && !events.contains(where: { $0.id == "finish" }) {
            // A long gap is sleep/quit, not observing the boundary live.
            let live = previous.map { $0 < end && now.timeIntervalSince($0) <= 5 } ?? false
            candidates.append(.init(id: "finish", kind: .finish, name: "生活时间开始", symbol: "sparkles", occurredAt: end, skipped: !live))
        }
        for var event in candidates {
            event.skipped = event.skipped || silent || blocked || now >= event.expires(at: end)
            events.append(event)
        }
        for i in events.indices where !events[i].displayed {
            if blocked || silent || now >= events[i].expires(at: end) { events[i].skipped = true }
        }
        let available = events.filter { !$0.displayed && !$0.skipped }
        let selected = available.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.kind == .milestone && $0.cents != $1.cents { return $0.cents > $1.cents }
            return $0.occurredAt > $1.occurredAt
        }.first
        pendingID = selected?.id
        // There is one waiting slot. Lower-ranked events remain only in the summary.
        for i in events.indices where !events[i].displayed && events[i].id != selected?.id { events[i].skipped = true }
        guard let selected, !blocked, !silent, !busy else { return nil }
        if selected.kind != .finish {
            guard ordinaryCount < 5, selected.kind == .reminder || rewardCount < 4 else {
                skipPending(); return nil
            }
            if let lastDisplayedAt, now.timeIntervalSince(lastDisplayedAt) < 1200 { return nil }
            ordinaryCount += 1
            if selected.kind != .reminder { rewardCount += 1 }
            lastDisplayedAt = now
        }
        if let i = events.firstIndex(where: { $0.id == selected.id }) { events[i].displayed = true }
        pendingID = nil
        return selected
    }

    mutating func skipPending() {
        for i in events.indices where !events[i].displayed { events[i].skipped = true }
        pendingID = nil
    }
}

enum SalaryCopy {
    static func variants(for event: SalaryEvent, tone: SalaryTone) -> [String] {
        switch event.kind {
        case .halfway: return tone == .gentle ? ["已经走过半程，今天辛苦了。", "再给自己一点时间，离下班更近了。"] : ["半场结束，离下班又近了一截。", "进度过半。你的灵魂正在加载下班路线。"]
        case .reminder: return tone == .gentle ? ["还有5分钟，今天辛苦了。", "给今天收个尾，生活在等你。"] : ["灵魂已到地铁口，肉身还剩5分钟。", "下班倒计时：请准备切换成人类模式。"]
        case .finish:
            if tone == .gentle { return ["今天到这里，生活时间开始。", "今天也认真生活了，接下来留给自己。"] }
            if tone == .bold { return ["今日份窝囊费估算完毕，建议本人离场。", "工位使用时间结束。请归还本人。"] }
            return ["下班！今天出售的时间，已全部交付。", "今日营业结束，快乐正式开张。", "系统提示：你的自由已到账。"]
        case .milestone:
            if tone == .gentle { return ["\(event.name)，已经赚到了。", "又攒下一点生活的小快乐：\(event.name)。", "今天的小奖励：\(event.name)。"] }
            let isOriginalPreset = SalaryMilestone.defaults.contains { $0.name == event.name && $0.symbol == event.symbol }
            guard isOriginalPreset else {
                return ["\(event.name)的钱到手。打工突然具象化了。", "本场打工已赞助：\(event.name)。", "快乐清单新增一项：\(event.name)。"]
            }
            switch event.symbol {
            case "cup.and.saucer.fill": return ["奶茶钱到手。今天先替珍珠打工到这里。", "本杯奶茶，由刚才认真活着的你赞助。", "珍珠已就位，快乐预算 +1。"]
            case "fork.knife": return ["午饭已被本场打工赞助。", "这顿饭，工位请客。", "劳动成果：一顿不用纠结的好饭。"]
            case "tshirt.fill": return ["衣服到手。工位坐着，衣柜更新着。", "今天的工位，正在为衣柜融资。", "快乐可以穿在身上了。"]
            default: return ["\(event.name)的钱到手。打工突然具象化了。", "本场打工已赞助：\(event.name)。", "快乐清单新增一项：\(event.name)。"]
            }
        }
    }
}
