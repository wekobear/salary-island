import Foundation

enum SalaryTax: String, Codable, CaseIterable {
    case beforeTax, afterTax
    var label: String { self == .beforeTax ? "税前" : "税后" }
}

struct SalaryCalculationError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct SalarySchedule: Codable, Equatable {
    var weekdays: Set<Int> = [2,3,4,5,6]
    var startMinute = 540
    var endMinute = 1080
    var breakStartMinute = 720
    var breakEndMinute = 780
    var hasBreak = true
    var paidBreak = false
    var timeZoneID = TimeZone.current.identifier
    var exceptions: [String: Bool] = [:]
    var paidSeconds: Int64 {
        Int64(max(0, endMinute - startMinute - (hasBreak && !paidBreak ? breakEndMinute - breakStartMinute : 0))) * 60
    }
    func validate() throws {
        guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else { throw SalaryCalculationError("请至少选择一个有效工作日。") }
        guard (0...1439).contains(startMinute), (0...1439).contains(endMinute), startMinute < endMinute else { throw SalaryCalculationError("下班须晚于上班；首版不支持跨午夜班次。") }
        if hasBreak {
            guard breakStartMinute >= startMinute, breakEndMinute <= endMinute, breakStartMinute < breakEndMinute,
                  breakEndMinute - breakStartMinute < endMinute - startMinute else { throw SalaryCalculationError("午休须在班次内，且短于整个班次。") }
        }
        guard TimeZone(identifier: timeZoneID) != nil else { throw SalaryCalculationError("请输入有效时区，例如 Asia/Shanghai。") }
        guard paidSeconds > 0 else { throw SalaryCalculationError("每日计薪时间必须大于0。") }
        for key in exceptions.keys {
            guard SalaryEngine.validDayKey(key, timeZoneID: timeZoneID) else { throw SalaryCalculationError("排班日期格式无效。") }
        }
    }
}

struct SalaryProfile: Codable, Equatable {
    var monthlyCents: Int64 = 0
    var tax: SalaryTax = .afterTax
    var schedule = SalarySchedule()
    func validate() throws {
        guard (1...100_000_000_000).contains(monthlyCents) else { throw SalaryCalculationError("月薪须大于0，且不超过10亿元。") }
        try schedule.validate()
    }
}

struct SalaryVersion: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var effectiveDay: String
    var profile: SalaryProfile
    var effectiveAt: Date? = nil
}

struct SalaryInterval: Codable, Equatable { var start: Date; var end: Date }

struct SalarySnapshot: Codable, Equatable, Identifiable {
    var id: String
    var dayKey: String
    var versionID: String
    var monthlyCents: Int64
    var denominatorSeconds: Int64
    var intervals: [SalaryInterval]
    var shiftStart: Date?
    var shiftEnd: Date?
    var tax: SalaryTax
    var timeZoneID: String
    var plannedSeconds: Int64 { intervals.reduce(0) { $0 + Int64($1.end.timeIntervalSince($1.start)) } }
    var isWorkday: Bool { plannedSeconds > 0 }
    func elapsedSeconds(at date: Date) -> Int64 {
        intervals.reduce(0) { sum, interval in sum + Int64(max(0, floor(min(date, interval.end).timeIntervalSince(interval.start)))) }
    }
    func earnedCents(at date: Date) -> Double {
        guard denominatorSeconds > 0 else { return 0 }
        return Double(monthlyCents) * Double(elapsedSeconds(at: date)) / Double(denominatorSeconds)
    }
    var dayCents: Double { denominatorSeconds > 0 ? Double(monthlyCents) * Double(plannedSeconds) / Double(denominatorSeconds) : 0 }
    var hourlyYuan: Double { denominatorSeconds > 0 ? Double(monthlyCents) * 36 / Double(denominatorSeconds) : 0 }
    func reached(cents: Int64, at date: Date) -> Bool {
        guard cents > 0, cents <= 100_000_000_000, monthlyCents > 0, denominatorSeconds > 0 else { return false }
        let left = monthlyCents.multipliedReportingOverflow(by: elapsedSeconds(at: date))
        let right = cents.multipliedReportingOverflow(by: denominatorSeconds)
        return !left.overflow && !right.overflow && left.partialValue >= right.partialValue
    }
    func crossingDate(cents: Int64) -> Date? {
        guard cents > 0, cents <= 100_000_000_000, monthlyCents > 0, denominatorSeconds > 0 else { return nil }
        let product = cents.multipliedReportingOverflow(by: denominatorSeconds)
        guard !product.overflow else { return nil }
        var seconds = product.partialValue / monthlyCents + (product.partialValue % monthlyCents == 0 ? 0 : 1)
        guard seconds <= plannedSeconds else { return nil }
        for interval in intervals {
            let count = Int64(interval.end.timeIntervalSince(interval.start))
            if seconds <= count { return interval.start.addingTimeInterval(Double(seconds)) }
            seconds -= count
        }
        return nil
    }
    func progress(at date: Date) -> Double { plannedSeconds > 0 ? Double(elapsedSeconds(at: date)) / Double(plannedSeconds) : 0 }
}

enum SalaryEngine {
    static func calendar(_ zone: String) -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone) ?? .current; c.locale = Locale(identifier: "en_US_POSIX"); return c
    }
    static func dayKey(_ date: Date, timeZoneID: String) -> String {
        let c = calendar(timeZoneID).dateComponents([.year,.month,.day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func date(for dayKey: String, timeZoneID: String) -> Date {
        let values = dayKey.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return .distantPast }
        return calendar(timeZoneID).date(from: DateComponents(year: values[0], month: values[1], day: values[2])) ?? .distantPast
    }
    static func validDayKey(_ key: String, timeZoneID: String) -> Bool {
        guard key.count == 10 else { return false }
        return dayKey(date(for: key, timeZoneID: timeZoneID), timeZoneID: timeZoneID) == key
    }
    static func selected(_ key: String, versions: [SalaryVersion]) -> SalaryVersion? {
        let ordered = versions.sorted { a, b in
            a.effectiveDay == b.effectiveDay ? activation(of: a, in: versions) < activation(of: b, in: versions) : a.effectiveDay < b.effectiveDay
        }
        return ordered.last(where: { $0.effectiveDay <= key }) ?? ordered.first
    }
    static func profile(for dayKey: String, versions: [SalaryVersion]) -> SalaryProfile {
        selected(dayKey, versions: versions)?.profile ?? SalaryProfile()
    }
    static func works(_ key: String, schedule: SalarySchedule) -> Bool {
        if let value = schedule.exceptions[key] { return value }
        return schedule.weekdays.contains(calendar(schedule.timeZoneID).component(.weekday, from: date(for: key, timeZoneID: schedule.timeZoneID)))
    }
    static func moment(_ key: String, minute: Int, schedule: SalarySchedule) -> Date {
        let c = calendar(schedule.timeZoneID)
        return c.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: date(for: key, timeZoneID: schedule.timeZoneID))!
    }
    static func intervals(_ key: String, schedule: SalarySchedule) -> [SalaryInterval] {
        guard works(key, schedule: schedule) else { return [] }
        let start = moment(key, minute: schedule.startMinute, schedule: schedule)
        let end = moment(key, minute: schedule.endMinute, schedule: schedule)
        if !schedule.hasBreak || schedule.paidBreak { return [.init(start: start, end: end)] }
        let breakStart = moment(key, minute: schedule.breakStartMinute, schedule: schedule)
        let breakEnd = moment(key, minute: schedule.breakEndMinute, schedule: schedule)
        return [SalaryInterval(start: start, end: breakStart), SalaryInterval(start: breakEnd, end: end)].filter { $0.end > $0.start }
    }
    static func activation(of version: SalaryVersion, in versions: [SalaryVersion]) -> Date {
        if let instant = version.effectiveAt { return instant }
        let ordered = versions.sorted { $0.effectiveDay < $1.effectiveDay }
        if let index = ordered.firstIndex(where: { $0.id == version.id }), index > 0 {
            let prior = ordered[index - 1].profile.schedule
            if prior.timeZoneID != version.profile.schedule.timeZoneID {
                return moment(version.effectiveDay, minute: prior.startMinute, schedule: prior)
            }
        }
        return date(for: version.effectiveDay, timeZoneID: version.profile.schedule.timeZoneID)
    }
    static func activeVersion(at now: Date, versions: [SalaryVersion]) -> SalaryVersion? {
        let ordered = versions.sorted { activation(of: $0, in: versions) < activation(of: $1, in: versions) }
        return ordered.last { activation(of: $0, in: versions) <= now } ?? ordered.first
    }
    static func ledgerID(day: String, zone: String) -> String { zone + "|" + day }
    static func context(at now: Date, versions: [SalaryVersion]) throws -> (version: SalaryVersion, day: String, id: String) {
        guard let version = activeVersion(at: now, versions: versions) else { throw SalaryCalculationError("请先填写月薪与作息。") }
        try version.profile.validate()
        let day = dayKey(now, timeZoneID: version.profile.schedule.timeZoneID)
        return (version, day, ledgerID(day: day, zone: version.profile.schedule.timeZoneID))
    }
    static func plannedIntervals(_ key: String, version: SalaryVersion, versions: [SalaryVersion]) -> [SalaryInterval] {
        let paid = intervals(key, schedule: version.profile.schedule)
        let ordered = versions.sorted { activation(of: $0, in: versions) < activation(of: $1, in: versions) }
        guard let index = ordered.firstIndex(where: { $0.id == version.id }), index > 0,
              ordered[index - 1].profile.schedule.timeZoneID != version.profile.schedule.timeZoneID else { return paid }
        // A timezone transition never earns retroactively in the destination's already elapsed hours.
        let instant = activation(of: version, in: versions)
        return paid.compactMap { interval in
            let start = max(interval.start, instant)
            return start < interval.end ? SalaryInterval(start: start, end: interval.end) : nil
        }
    }
    static func snapshot(at now: Date, versions: [SalaryVersion]) throws -> SalarySnapshot {
        let resolved = try context(at: now, versions: versions)
        let key = resolved.day, version = resolved.version
        let schedule = version.profile.schedule
        let c = calendar(schedule.timeZoneID)
        let day = date(for: key, timeZoneID: schedule.timeZoneID)
        guard let month = c.dateInterval(of: .month, for: day) else { throw SalaryCalculationError("无法生成月度计划。") }
        var current = month.start
        var denominator: Int64 = 0
        while current < month.end {
            let dateKey = dayKey(current, timeZoneID: schedule.timeZoneID)
            guard let planned = selected(dateKey, versions: versions) else { break }
            try planned.profile.validate()
            for interval in plannedIntervals(dateKey, version: planned, versions: versions) {
                denominator += Int64(interval.end.timeIntervalSince(interval.start))
            }
            current = c.date(byAdding: .day, value: 1, to: current)!
        }
        guard denominator > 0, denominator <= 32 * 86400 else { throw SalaryCalculationError("当月没有有效计薪时间，请检查工作日与休息日期。") }
        let paid = plannedIntervals(key, version: version, versions: versions)
        let ordered = versions.sorted { activation(of: $0, in: versions) < activation(of: $1, in: versions) }
        let index = ordered.firstIndex(where: { $0.id == version.id }) ?? 0
        let cutoff = index > 0 && ordered[index - 1].profile.schedule.timeZoneID != schedule.timeZoneID
            ? activation(of: version, in: versions) : .distantPast
        return SalarySnapshot(id: resolved.id, dayKey: key, versionID: version.id, monthlyCents: version.profile.monthlyCents, denominatorSeconds: denominator, intervals: paid,
            shiftStart: paid.isEmpty ? nil : max(moment(key, minute: schedule.startMinute, schedule: schedule), cutoff),
            shiftEnd: paid.isEmpty ? nil : moment(key, minute: schedule.endMinute, schedule: schedule), tax: version.profile.tax, timeZoneID: schedule.timeZoneID)
    }
    static func proposedVersion(for newProfile: SalaryProfile, versions: [SalaryVersion], now: Date) throws -> SalaryVersion {
        try newProfile.validate()
        guard let old = activeVersion(at: now, versions: versions)?.profile else {
            let key = dayKey(now, timeZoneID: newProfile.schedule.timeZoneID)
            return SalaryVersion(effectiveDay: key, profile: newProfile, effectiveAt: date(for: key, timeZoneID: newProfile.schedule.timeZoneID))
        }
        let key = dayKey(now, timeZoneID: old.schedule.timeZoneID)
        let zoneChanged = old.schedule.timeZoneID != newProfile.schedule.timeZoneID
        let c = calendar(old.schedule.timeZoneID)
        var instant = date(for: key, timeZoneID: old.schedule.timeZoneID)
        if zoneChanged {
            var found = false
            for _ in 0..<370 {
                instant = c.date(byAdding: .day, value: 1, to: instant)!
                let next = dayKey(instant, timeZoneID: old.schedule.timeZoneID)
                if works(next, schedule: old.schedule) {
                    instant = moment(next, minute: old.schedule.startMinute, schedule: old.schedule)
                    found = true; break
                }
            }
            guard found else { throw SalaryCalculationError("旧计划未来一年没有工作日，无法确定时区切换时刻。") }
        } else {
            // Recalculate the whole current day. A timezone transition that has
            // already happened today remains a hard boundary for earned time.
            let ordered = versions.sorted { activation(of: $0, in: versions) < activation(of: $1, in: versions) }
            for index in ordered.indices.dropFirst() {
                let version = ordered[index]
                let boundary = activation(of: version, in: versions)
                if boundary <= now,
                   version.profile.schedule.timeZoneID == old.schedule.timeZoneID,
                   ordered[index - 1].profile.schedule.timeZoneID != old.schedule.timeZoneID {
                    instant = max(instant, boundary)
                }
            }
        }
        return SalaryVersion(effectiveDay: dayKey(instant, timeZoneID: newProfile.schedule.timeZoneID), profile: newProfile, effectiveAt: instant)
    }
    static func effectiveDay(for newProfile: SalaryProfile, versions: [SalaryVersion], now: Date) throws -> String {
        try proposedVersion(for: newProfile, versions: versions, now: now).effectiveDay
    }
    static func moneyCents(_ text: String) throws -> Int64 {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || parts[1].count <= 2,
              let whole = Int64(parts[0]), whole <= 1_000_000_000 else { throw SalaryCalculationError("金额请填写正数，最多两位小数，上限10亿元。") }
        let fractional = parts.count == 2 ? Int64(parts[1].padding(toLength: 2, withPad: "0", startingAt: 0))! : 0
        let result = whole * 100 + fractional
        guard (1...100_000_000_000).contains(result) else { throw SalaryCalculationError("金额须大于0，且不超过10亿元。") }
        return result
    }
    static func formatYuan(cents: Double) -> String {
        let f = NumberFormatter(); f.locale = Locale(identifier: "zh_CN"); f.numberStyle = .currency; f.currencySymbol = "¥"; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2; f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: cents / 100)) ?? "¥0.00"
    }
}

enum SalaryGoalMath {
    /// 与门槛校验一致的收入上限：10 亿元 = 100_000_000_000 分。
    static let centsCap: Int64 = 100_000_000_000

    /// 计算 [start, end] 内按快照计薪区间累计的收入（分）。
    /// 计薪秒数完全复用 SalarySnapshot.elapsedSeconds(at:)（逐区间向下取整后求和，
    /// 区间外时间被裁剪），seconds = max(0, elapsed(end) - elapsed(start))。
    /// 金额只用整数运算：monthly/denominator*seconds + (monthly%denominator)*seconds/denominator，
    /// 乘加全部使用带溢出检查的 Int64 运算；非法输入返回 0，结果封顶 centsCap。
    static func earnedCents(snapshot: SalarySnapshot, from start: Date, through end: Date) -> Int64 {
        guard (1...32 * 86400).contains(snapshot.denominatorSeconds),
              (0...centsCap).contains(snapshot.monthlyCents) else { return 0 }
        let seconds = max(0, snapshot.elapsedSeconds(at: end) - snapshot.elapsedSeconds(at: start))
        guard seconds > 0 else { return 0 }
        let monthly = snapshot.monthlyCents
        let denominator = snapshot.denominatorSeconds
        let base = (monthly / denominator).multipliedReportingOverflow(by: seconds)
        guard !base.overflow else { return centsCap }
        let extra = (monthly % denominator).multipliedReportingOverflow(by: seconds)
        guard !extra.overflow else { return centsCap }
        let sum = base.partialValue.addingReportingOverflow(extra.partialValue / denominator)
        guard !sum.overflow else { return centsCap }
        return min(sum.partialValue, centsCap)
    }

    /// 汇总多份快照在 [start, end] 内的收入（分）。按 snapshot.id 去重（保留首次出现），
    /// 按输入顺序累加并逐项封顶，溢出按上限处理，结果确定可复现。
    static func totalCents(snapshots: [SalarySnapshot], from start: Date, through end: Date) -> Int64 {
        var seen = Set<String>()
        var total: Int64 = 0
        for snapshot in snapshots {
            guard seen.insert(snapshot.id).inserted else { continue }
            let earned = earnedCents(snapshot: snapshot, from: start, through: end)
            let sum = total.addingReportingOverflow(earned)
            if sum.overflow { return centsCap }
            total = min(sum.partialValue, centsCap)
        }
        return total
    }
}
