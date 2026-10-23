import Foundation

@main
struct SalaryCoreChecks {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ title: String) {
        guard value() else { fatalError("FAIL: \(title)") }
        count += 1; print("PASS \(title)")
    }
    static func time(_ day: String, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        SalaryEngine.date(for: day, timeZoneID: "Asia/Shanghai").addingTimeInterval(Double(hour*3600+minute*60+second))
    }
    static func time(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date { time("2026-01-05", hour, minute, second) }
    static func main() throws {
        let p = SalaryProfile(monthlyCents: 1_760_000, tax: .afterTax, schedule: SalarySchedule(timeZoneID: "Asia/Shanghai"))
        let versions = [SalaryVersion(effectiveDay: "2026-01-01", profile: p)]
        let snap = try SalaryEngine.snapshot(at: time(10), versions: versions)
        check(snap.denominatorSeconds == 22*8*3600, "A01 January contains 22 weekdays")
        check(snap.hourlyYuan == 100, "A01 hourly rate")
        check(snap.earnedCents(at: time(10)) == 10000, "A01 10:00 100 yuan")
        check(snap.earnedCents(at: time(12,30)) == 30000, "A02 unpaid lunch")
        check(snap.earnedCents(at: time(13,30)) == 35000, "A01 after lunch 350")
        check(snap.earnedCents(at: time(19)) == 80000, "A04 capped after work")
        check(snap.earnedCents(at: time(8)) == 0, "before work no income")
        check(!snap.reached(cents: 2000, at: time(9,11,59)), "A13 not a second early")
        check(snap.reached(cents: 2000, at: time(9,12)), "A13 exact integer boundary")
        check(snap.crossingDate(cents: 2000) == time(9,12), "crossingDate maps exact second")
        check(snap.crossingDate(cents: 35000) == time(13,30), "crossingDate skips unpaid break")
        check(snap.crossingDate(cents: 90000) == nil, "unreachable daily target")
        check(!snap.reached(cents: Int64.max, at: time(19)), "overflow target rejected")
        let rest = try SalaryEngine.snapshot(at: time("2026-01-04",10), versions: versions)
        check(!rest.isWorkday && rest.dayCents == 0 && rest.shiftEnd == nil, "A08 rest day")
        var paid = p; paid.schedule.paidBreak = true
        let paidSnapshot = try SalaryEngine.snapshot(at: time(12,30), versions: [.init(effectiveDay: "2026-01-01", profile: paid)])
        check(paidSnapshot.elapsedSeconds(at: time(12,30)) == 12600, "paid lunch keeps earning")
        let pre = try SalaryEngine.effectiveDay(for: p, versions: versions, now: time(8))
        let post = try SalaryEngine.effectiveDay(for: p, versions: versions, now: time(10))
        check(pre == "2026-01-05" && post == "2026-01-05", "A07 same-zone changes apply today before and after shift")
        var early = p; early.schedule.startMinute = 420
        let effectiveEarly = try SalaryEngine.effectiveDay(for: early, versions: versions, now: time(8))
        check(effectiveEarly == "2026-01-05", "earlier new start recalculates today immediately")
        var added = p; added.schedule.exceptions["2026-01-17"] = true
        let amended = versions + [.init(effectiveDay: "2026-01-16", profile: added)]
        let newSnapshot = try SalaryEngine.snapshot(at: time("2026-01-16",10), versions: amended)
        check(newSnapshot.denominatorSeconds == 23*8*3600, "A20 new monthly denominator")
        check(snap.dayCents == 80000, "A20 existing snapshot unchanged")
        let nextMonth = try SalaryEngine.snapshot(at: time("2026-02-02",10), versions: versions)
        check(nextMonth.denominatorSeconds == 20*8*3600, "A08 month rollover")
        var changedZone = p; changedZone.schedule.timeZoneID = "America/New_York"
        let zoneVersion = try SalaryEngine.proposedVersion(for: changedZone, versions: versions, now: time(8))
        check(zoneVersion.effectiveAt == time("2026-01-06", 9), "timezone change deferred to old next shift instant")
        check(zoneVersion.effectiveDay == "2026-01-05", "destination civil date matches activation")
        let zoneVersions = versions + [zoneVersion]
        let priorZone = try SalaryEngine.context(at: time("2026-01-06", 8, 59, 59), versions: zoneVersions)
        let nextZone = try SalaryEngine.context(at: time("2026-01-06", 9), versions: zoneVersions)
        check(priorZone.version.profile.schedule.timeZoneID == "Asia/Shanghai" && nextZone.version.id == zoneVersion.id, "one instant selects both version and ledger zone")
        let zoneSnapshot = try SalaryEngine.snapshot(at: time("2026-01-06", 9), versions: zoneVersions)
        check(zoneSnapshot.id == nextZone.id && zoneSnapshot.earnedCents(at: time("2026-01-06", 9)) == 0, "destination does not retroactively earn")
        check(zoneSnapshot.id != snap.id, "same civil day in two zones has distinct ledger")
        var restTuesday = p; restTuesday.schedule.exceptions["2026-01-06"] = false
        let restVersion = try SalaryEngine.proposedVersion(for: restTuesday, versions: versions, now: time(10))
        let tuesday = try SalaryEngine.snapshot(at: time("2026-01-06", 10), versions: versions + [restVersion])
        check(restVersion.effectiveDay == "2026-01-05" && !tuesday.isWorkday, "new rest exception applies immediately to the plan")
        var tokyo = p; tokyo.schedule.timeZoneID = "Asia/Tokyo"
        let tokyoVersion = try SalaryEngine.proposedVersion(for: tokyo, versions: versions, now: time(10))
        let tokyoSnapshot = try SalaryEngine.snapshot(at: time("2026-01-06", 9), versions: versions + [tokyoVersion])
        check(tokyoSnapshot.plannedSeconds == 7*3600 && tokyoSnapshot.earnedCents(at: time("2026-01-06", 9)) == 0, "partial destination shift starts at switch instant")
        let nyInitial = SalaryVersion(effectiveDay: "2026-01-01", profile: changedZone)
        let nyNow = SalaryEngine.moment("2026-01-05", minute: 23*60, schedule: changedZone.schedule)
        let eastward = try SalaryEngine.proposedVersion(for: tokyo, versions: [nyInitial], now: nyNow)
        let eastStart = SalaryEngine.moment("2026-01-06", minute: 9*60, schedule: changedZone.schedule)
        check(eastward.effectiveAt == eastStart, "NY to Tokyo waits for old next shift")
        let eastBefore = try SalaryEngine.context(at: eastStart.addingTimeInterval(-1), versions: [nyInitial, eastward])
        let eastAfter = try SalaryEngine.snapshot(at: eastStart, versions: [nyInitial, eastward])
        check(eastBefore.version.id == nyInitial.id && eastAfter.timeZoneID == "Asia/Tokyo" && eastAfter.earnedCents(at: eastStart) == 0, "eastward date crossing has no early activation or retroactive pay")
        var nextMondayOff = p; nextMondayOff.schedule.weekdays.remove(2)
        let mondayRule = try SalaryEngine.proposedVersion(for: nextMondayOff, versions: versions, now: time(10))
        let nextMonday = try SalaryEngine.snapshot(at: time("2026-01-12", 10), versions: versions + [mondayRule])
        check(!nextMonday.isWorkday, "removed weekday applies on following week")
        var saturdayOn = p; saturdayOn.schedule.exceptions["2026-01-10"] = true
        let saturdayRule = try SalaryEngine.proposedVersion(for: saturdayOn, versions: versions, now: time(10))
        let saturday = try SalaryEngine.snapshot(at: time("2026-01-10", 10), versions: versions + [saturdayRule])
        check(saturday.isWorkday, "added weekend shift applies")
        let renamed = SalaryEvent(id: "milestone:tea", kind: .milestone, name: "一场电影", cents: 2000, symbol: "cup.and.saucer.fill", occurredAt: time(10))
        check(SalaryTone.allCases.allSatisfy { tone in SalaryCopy.variants(for: renamed, tone: tone).allSatisfy { !$0.contains("奶茶") && !$0.contains("珍珠") } }, "renamed preset uses generic copy")
        let parsed = try SalaryEngine.moneyCents("17600.01")
        check(parsed == 1760001, "exact cent parsing")
        for invalid in ["", "0", "-1", "nan", "1e4", "1.001", "1000000000.01", "99999999999999999999", ".5"] {
            do { _ = try SalaryEngine.moneyCents(invalid); fatalError("accepted invalid money") } catch { check(true, "invalid money rejected: \(invalid)") }
        }
        var emptyMonth = p
        for day in 1...31 { emptyMonth.schedule.exceptions[String(format:"2026-01-%02d",day)] = false }
        do { _ = try SalaryEngine.snapshot(at: time(10), versions: [.init(effectiveDay:"2026-01-01",profile:emptyMonth)]); fatalError("zero month accepted") } catch { check(true,"A08 zero month rejected") }

        var ledger = SalaryDayLedger(snapshot: snap)
        let first = ledger.advance(now: time(9,12), previous: time(9,11,59), milestones: SalaryMilestone.defaults, blocked: false, busy: false)
        check(first?.id == "milestone:tea", "A05 first milestone")
        check(ledger.advance(now: time(9,13), previous: time(9,12), milestones: SalaryMilestone.defaults, blocked: false, busy: false) == nil, "A05 no replay")
        let data = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(SalaryDayLedger.self, from: data)
        check(restored.advance(now: time(9,14), previous: nil, milestones: SalaryMilestone.defaults, blocked: false, busy: false) == nil, "A03 restart deduplication")
        var wake = SalaryDayLedger(snapshot: snap)
        let merged = wake.advance(now: time(11,5), previous: time(9), milestones: SalaryMilestone.defaults, blocked: false, busy: false)
        check(merged?.id == "milestone:clothes" && wake.events.count == 3, "A06 recent highest only, all facts kept")
        var stale = SalaryDayLedger(snapshot: snap)
        check(stale.advance(now: time(15), previous: time(9), milestones: SalaryMilestone.defaults, blocked: false, busy: false) == nil, "A19 stale wake no replay")
        var privacy = SalaryDayLedger(snapshot: snap)
        _ = privacy.advance(now: time(9,12), previous: time(9,11,59), milestones: SalaryMilestone.defaults, blocked: true, busy: false)
        check(privacy.events.first?.skipped == true, "A09 privacy records fact quietly")
        check(privacy.advance(now: time(9,13), previous: time(9,12), milestones: SalaryMilestone.defaults, blocked: false, busy: false) == nil, "privacy off no replay")
        var busy = SalaryDayLedger(snapshot: snap)
        _ = busy.advance(now: time(9,12), previous: time(9,11,59), milestones: SalaryMilestone.defaults, blocked: false, busy: true)
        check(busy.pendingID == "milestone:tea" && busy.ordinaryCount == 0, "user interaction queues without spending quota")
        check(busy.advance(now: time(9,13), previous: time(9,12), milestones: SalaryMilestone.defaults, blocked: false, busy: false)?.id == "milestone:tea", "queue delivers after interaction")
        var cap = SalaryDayLedger(snapshot: snap, ordinaryCount: 4, rewardCount: 4)
        let reminder = cap.advance(now: time(17,55), previous: time(17,54,59), milestones: [], blocked: false, busy: false)
        check(reminder?.kind == .reminder && cap.ordinaryCount == 5, "A16 reminder reserved quota")
        var cooldown = SalaryDayLedger(snapshot: snap, lastDisplayedAt: time(17,50), ordinaryCount: 1, rewardCount: 1)
        check(cooldown.advance(now: time(17,55), previous: time(17,54,59), milestones: [], blocked: false, busy: false) == nil, "A16 reminder honors 20min gap")
        check(cooldown.advance(now: time(18), previous: time(17,59,59), milestones: [], blocked: false, busy: false)?.kind == .finish, "finish separately allowed")
        check(!cooldown.events.contains(where: { $0.kind == .reminder && $0.displayed }), "expired reminder not shown")
        var sleptPast = SalaryDayLedger(snapshot: snap)
        check(sleptPast.advance(now: time(18,1), previous: time(17), milestones: [], blocked: false, busy: false) == nil, "sleep across end no celebration replay")
        var low = p; low.monthlyCents = 10000
        let lowSnap = try SalaryEngine.snapshot(at: time(14), versions:[.init(effectiveDay:"2026-01-01",profile:low)])
        var lowLedger = SalaryDayLedger(snapshot:lowSnap)
        check(lowLedger.advance(now: time(14),previous:time(13,59,59),milestones:SalaryMilestone.defaults,blocked:false,busy:false)?.kind == .halfway, "A12 nonconsumer halfway encouragement")
        var noTargets = SalaryDayLedger(snapshot:lowSnap)
        check(noTargets.advance(now:time(14),previous:time(13),milestones:[],blocked:false,busy:false) == nil,"A19 no targets no encouragement")
        var edited = SalaryDayLedger(snapshot:snap)
        _ = edited.advance(now:time(10),previous:nil,milestones:[.init(id:"edit",name:"Test",cents:2000,symbol:"gift")],blocked:false,busy:false,silent:true)
        check(edited.events.first?.skipped == true && edited.events.first?.displayed == false,"A15 edit silently records")
        var rollback = SalaryDayLedger(snapshot:snap)
        _ = rollback.advance(now:time(9,12),previous:time(9,11,59),milestones:SalaryMilestone.defaults,blocked:false,busy:true)
        check(rollback.advance(now:time(9,10),previous:time(9,12),milestones:SalaryMilestone.defaults,blocked:false,busy:false) == nil, "clock rollback clears pending rewards")
        check(rollback.advance(now:time(9,12),previous:time(9,11,59),milestones:SalaryMilestone.defaults,blocked:false,busy:false) == nil, "clock re-crossing cannot replay reward")
        check(SalaryGoalMath.earnedCents(snapshot: snap, from: time(9), through: time(10)) == 10_000, "cumulative math clips to requested paid interval")
        check(SalaryGoalMath.earnedCents(snapshot: snap, from: time(12), through: time(13)) == 0, "cumulative math excludes unpaid break")
        check(SalaryGoalMath.totalCents(snapshots: [snap, snap], from: time(9), through: time(10)) == 10_000, "cumulative math deduplicates snapshot IDs")
        check(SalaryGoalMath.earnedCents(snapshot: snap, from: time(11), through: time(10)) == 0, "cumulative math rejects reversed interval")
        check(SalaryGoalMath.earnedCents(snapshot: snap, from: time(9), through: time(9,0,1)) == 2, "cumulative math floors fractional cents without premature threshold")
        print("\n\(count) checks passed.")
    }
}
