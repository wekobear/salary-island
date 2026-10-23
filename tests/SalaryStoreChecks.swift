import AppKit
import Combine
import Foundation

// Isolated app services: tests never launch the app or touch its real salary file.
@MainActor final class BoringViewCoordinator {
    static let shared = BoringViewCoordinator()
    struct Presentation { var show = false }
    var selectedScreenUUID = "test"
    var sneakPeek = Presentation()
    var expandingView = Presentation()
}
@MainActor final class FullscreenMediaDetector {
    static let shared = FullscreenMediaDetector()
    @Published var fullscreenStatus: [String: Bool] = [:]
}
@MainActor final class SharingStateManager {
    static let shared = SharingStateManager()
    var preventNotchClose = false
}

@main @MainActor struct SalaryStoreChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }
        count += 1; print("PASS \(label)")
    }
    static func time(_ day: String, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        SalaryEngine.date(for: day, timeZoneID: "Asia/Shanghai").addingTimeInterval(Double(hour*3600 + minute*60 + second))
    }
    static func time(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date { time("2026-01-05", hour, minute, second) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SalaryStoreChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = SalaryProfile(monthlyCents: 1_760_000, tax: .afterTax, schedule: SalarySchedule(timeZoneID: "Asia/Shanghai"))
        var now = time(10)
        let url = root.appendingPathComponent("salary.json")
        let store = SalaryStore(storageURL: url, clock: { now }, startRuntime: false)
        try store.saveProfile(profile)
        let originalDay = store.snapshot!
        var rest = profile; rest.schedule.exceptions["2026-01-06"] = false
        try store.saveProfile(rest)
        check(store.snapshot?.dayKey == originalDay.dayKey && store.snapshot?.denominatorSeconds == 21*8*3600, "saving a rest exception refreshes today's monthly denominator")
        now = time("2026-01-06", 10); store.tick()
        check(store.snapshot?.isWorkday == false, "future rest exception active in store")
        let reloaded = SalaryStore(storageURL: url, clock: { now }, startRuntime: false)
        check(reloaded.data.days.count == store.data.days.count && reloaded.snapshot == store.snapshot, "persisted day identity survives restart")

        now = time(10)
        let zoneURL = root.appendingPathComponent("zone.json")
        let zoneStore = SalaryStore(storageURL: zoneURL, clock: { now }, startRuntime: false)
        try zoneStore.saveProfile(profile)
        let oldID = zoneStore.snapshot!.id
        let oldLedger = zoneStore.data.days[oldID]!
        var ny = profile; ny.schedule.timeZoneID = "America/New_York"
        try zoneStore.saveProfile(ny)
        now = time("2026-01-06", 9); zoneStore.tick()
        let newID = zoneStore.snapshot!.id
        check(newID != oldID && zoneStore.currentProfile.schedule.timeZoneID == "America/New_York", "switch creates a distinct destination ledger")
        check(zoneStore.data.days[oldID] == oldLedger, "switch preserves old timezone ledger")
        let firstDestination = zoneStore.data.days[newID]
        zoneStore.tick(); zoneStore.tick()
        check(zoneStore.data.days.count == 2 && zoneStore.data.days[newID] == firstDestination, "repeated ticks use same destination key")

        // Legacy date-only records migrate without losing event history.
        var legacy = SalaryData(); legacy.versions = [.init(effectiveDay: "2026-01-01", profile: profile)]
        var legacySnapshot = originalDay; legacySnapshot.id = legacySnapshot.dayKey
        var legacyLedger = SalaryDayLedger(snapshot: legacySnapshot)
        _ = legacyLedger.advance(now: time(10), previous: nil, milestones: legacy.milestones, blocked: true, busy: false)
        legacy.days[legacySnapshot.dayKey] = legacyLedger
        let legacyURL = root.appendingPathComponent("legacy.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        now = time(10)
        let migrated = SalaryStore(storageURL: legacyURL, clock: { now }, startRuntime: false)
        check(migrated.data.days.count == 1 && migrated.realTodayEvents == legacyLedger.events, "legacy migration retains achievements")
        check(migrated.snapshot?.id == oldID, "legacy migration adds zone to key")

        // A path whose parent is a file forces a deterministic write error.
        let blockedParent = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedParent)
        let failed = SalaryStore(storageURL: blockedParent.appendingPathComponent("salary.json"), clock: { now }, startRuntime: false)
        do { try failed.saveProfile(profile); fatalError("write failure accepted") }
        catch { check(!failed.configured && failed.welcomeMessage == nil, "failed save neither publishes profile nor success") }
        check(!failed.setPrivacy(true) && !failed.privacy, "failed privacy save returns failure and retains state")
        var preferences = failed.data.preferences; preferences.sound = true
        do { try failed.savePreferences(preferences); fatalError("write failure accepted") }
        catch { check(!failed.data.preferences.sound && failed.errorMessage != nil, "preferences are transactional") }

        var unsupported = SalaryData(); unsupported.schema = 99; unsupported.versions = legacy.versions
        let corruptURL = root.appendingPathComponent("unsupported.json")
        let originalBytes = try JSONEncoder().encode(unsupported); try originalBytes.write(to: corruptURL)
        let corrupt = SalaryStore(storageURL: corruptURL, clock: { now }, startRuntime: false)
        check(!corrupt.configured && corrupt.snapshot == nil && corrupt.errorMessage != nil, "invalid schema never partially publishes data")
        corrupt.tick(); _ = corrupt.toggleQuiet()
        let retainedBytes = try Data(contentsOf: corruptURL)
        check(retainedBytes == originalBytes, "unreadable original preserved across ticks and edits")

        now = time(9, 11, 59)
        let interaction = SalaryStore(storageURL: root.appendingPathComponent("interaction.json"), clock: { now }, startRuntime: false)
        try interaction.saveProfile(profile)
        interaction.visibleSources.insert("test")
        interaction.interactionSources.insert("settings")
        now = time(9, 12); interaction.tick()
        check(interaction.toast == nil, "active settings defer milestone")
        interaction.interactionSources.remove("settings"); interaction.tick()
        check(interaction.toast?.title == "一杯奶茶", "settings resign allows queued milestone")
        interaction.interactionSources.insert("settings"); now = time(9, 12, 5); interaction.tick()
        check(interaction.toast == nil, "settings do not pin an existing toast forever")

        now = time(9, 29, 59)
        FullscreenMediaDetector.shared.fullscreenStatus["test"] = true
        let before = interaction.earnedCents
        now = time(9, 30); interaction.tick()
        check(interaction.earnedCents > before && interaction.toast == nil, "fullscreen updates time while suppressing prompts")
        FullscreenMediaDetector.shared.fullscreenStatus["test"] = false

        now = time(9)
        let demo = SalaryStore(storageURL: root.appendingPathComponent("demo.json"), clock: { now }, startRuntime: false)
        try demo.saveProfile(profile); demo.visibleSources.insert("test"); demo.startDemo()
        now = time(9, 0, 6); demo.tick()
        check(demo.todayEvents.contains { $0.id == "milestone:tea" } && demo.realTodayEvents.isEmpty, "demo achievement does not contaminate formal settings")
        now = time(9, 12); demo.tick()
        check(demo.realTodayEvents.contains { $0.id == "milestone:tea" && $0.skipped }, "real ledger advances silently during demo")
        demo.endDemo(); check(demo.toast == nil, "leaving demo does not replay real milestones")
        check(demo.setPrivacy(true), "privacy persists successfully")
        demo.previewCelebration(); check(demo.toast == nil, "explicit preview respects privacy")
        // Same-zone saves reprice today, never prior days, and survive restart.
        now = time("2026-01-02", 18)
        let liveURL = root.appendingPathComponent("live.json")
        let live = SalaryStore(storageURL: liveURL, clock: { now }, startRuntime: false)
        try live.saveProfile(profile)
        let historicalID = live.snapshot!.id
        let historical = live.data.days[historicalID]
        now = time(10); live.tick()
        var raised = profile; raised.monthlyCents *= 2
        let preview = try live.previewProfile(raised).1
        try live.saveProfile(raised)
        check(live.snapshot?.monthlyCents == 3_520_000 && live.earnedCents == 20_000, "raise immediately reprices elapsed hour")
        check(live.snapshot?.dayCents == 160_000 && live.snapshot?.hourlyYuan == 200, "raise immediately updates day and hourly rates")
        check(live.snapshot?.dayCents == preview.dayCents && live.snapshot?.intervals == preview.intervals && live.snapshot?.denominatorSeconds == preview.denominatorSeconds, "preview matches persisted calculation")
        check(live.data.days[historicalID] == historical, "repricing leaves historical ledger unchanged")
        let liveReloaded = SalaryStore(storageURL: liveURL, clock: { now }, startRuntime: false)
        check(liveReloaded.snapshot == live.snapshot && liveReloaded.earnedCents == 20_000, "immediate result survives restart")
        let versionCount = live.data.versions.count
        var lowered = profile; lowered.monthlyCents /= 2
        try live.saveProfile(lowered)
        check(live.earnedCents == 5_000 && live.snapshot?.hourlyYuan == 50 && live.snapshot?.dayCents == 40_000, "lowering reprices immediately without freezing earned amount")
        check(live.data.versions.count == versionCount, "same-day saves replace rather than accumulate versions")
        var changedHours = lowered; changedHours.schedule.endMinute = 17*60
        try live.saveProfile(changedHours)
        check(live.snapshot?.plannedSeconds == 7*3600 && live.snapshot?.shiftEnd == time(17), "hours update today's shift and countdown immediately")
        now = time(12,30)
        var paidLunch = changedHours; paidLunch.schedule.paidBreak = true
        try live.saveProfile(paidLunch)
        check(!live.onBreak && live.snapshot?.elapsedSeconds(at: now) == 12_600, "paid lunch recalculates today's elapsed time")
        var restToday = paidLunch; restToday.schedule.exceptions["2026-01-05"] = false
        try live.saveProfile(restToday)
        check(live.snapshot?.isWorkday == false && live.earnedCents == 0 && live.remaining == 0, "rest-day edit clears income and countdown immediately")
        try live.saveProfile(paidLunch)
        check(live.snapshot?.isWorkday == true && live.earnedCents > 0, "rest-to-work edit immediately restores calculated earnings")

        now = time(9,11,59)
        let rewards = SalaryStore(storageURL: root.appendingPathComponent("rewards.json"), clock: { now }, startRuntime: false)
        try rewards.saveProfile(profile); rewards.visibleSources.insert("test")
        now = time(9,12); rewards.tick()
        let displayedTea = rewards.realTodayEvents.first { $0.id == "milestone:tea" }
        rewards.interactionSources.insert("settings")
        now = time(9,30); rewards.tick()
        check(rewards.data.days[rewards.snapshot!.id]?.pendingID == "milestone:meal", "fixture has a pending reward before save")
        let oldCount = rewards.data.days[rewards.snapshot!.id]!.ordinaryCount
        now = time(10); try rewards.saveProfile(raised)
        check(rewards.realTodayEvents.first { $0.id == "milestone:tea" } == displayedTea && displayedTea?.displayed == true, "save retains previously displayed achievement")
        check(rewards.data.days[rewards.snapshot!.id]?.pendingID == nil && rewards.realTodayEvents.contains { $0.id == "milestone:meal" && $0.skipped }, "save clears and skips old pending rewards")
        check(rewards.realTodayEvents.contains { $0.id == "milestone:clothes" && $0.skipped } && rewards.toast == nil, "newly reached threshold is silent on repricing")
        check(rewards.data.days[rewards.snapshot!.id]?.ordinaryCount == oldCount, "save preserves notification counts")
        try rewards.saveProfile(lowered); try rewards.saveProfile(raised)
        rewards.interactionSources.remove("settings"); rewards.tick()
        check(rewards.toast == nil && rewards.realTodayEvents.filter { $0.id == "milestone:clothes" }.count == 1, "repeated repricing does not replay milestones")

        var queued = SalaryData()
        queued.versions = [.init(effectiveDay: "2026-01-01", profile: profile), .init(effectiveDay: "2026-01-06", profile: raised)]
        let queuedURL = root.appendingPathComponent("queued.json")
        try JSONEncoder().encode(queued).write(to: queuedURL)
        let queuedStore = SalaryStore(storageURL: queuedURL, clock: { now }, startRuntime: false)
        try queuedStore.saveProfile(queuedStore.editingProfile)
        check(queuedStore.earnedCents == 20_000 && queuedStore.data.versions.allSatisfy { $0.effectiveDay <= "2026-01-05" }, "resave applies old queued salary today and removes future override")
        now = time("2026-01-06", 10); queuedStore.tick()
        check(queuedStore.currentProfile.monthlyCents == raised.monthlyCents && queuedStore.earnedCents == 20_000, "new salary remains active tomorrow")

        now = time(10)
        let transition = SalaryStore(storageURL: root.appendingPathComponent("transition.json"), clock: { now }, startRuntime: false)
        try transition.saveProfile(profile)
        let priorZoneLedger = transition.data.days[transition.snapshot!.id]!
        var tokyo = profile; tokyo.schedule.timeZoneID = "Asia/Tokyo"
        try transition.saveProfile(tokyo)
        now = time("2026-01-06", 10); transition.tick()
        tokyo.monthlyCents *= 2
        try transition.saveProfile(tokyo)
        check(transition.snapshot?.shiftStart == time("2026-01-06",9) && transition.snapshot?.elapsedSeconds(at: now) == 3600, "same-zone edit after timezone switch retains transition cutoff")
        try transition.saveProfile(tokyo)
        check(transition.snapshot?.elapsedSeconds(at: now) == 3600 && transition.data.days[priorZoneLedger.snapshot.id] == priorZoneLedger, "repeated transition-day edits retain cutoff and old-zone history")

        now = time(10)
        let rollbackDir = root.appendingPathComponent("rollback")
        let rollback = SalaryStore(storageURL: rollbackDir.appendingPathComponent("salary.json"), clock: { now }, startRuntime: false)
        try rollback.saveProfile(profile)
        let beforeFailure = rollback.snapshot
        let versionsBeforeFailure = rollback.data.versions
        try FileManager.default.removeItem(at: rollbackDir)
        try Data("blocked".utf8).write(to: rollbackDir)
        do { try rollback.saveProfile(raised); fatalError("write failure accepted") }
        catch { check(rollback.snapshot == beforeFailure && rollback.data.versions == versionsBeforeFailure && rollback.earnedCents == 10_000, "failed immediate save leaves active salary and snapshot unchanged") }
        // Cumulative goals: synthetic profiles only; all files are isolated under root.
        now = time(10)
        let goalURL = root.appendingPathComponent("goals.json")
        let goals = SalaryStore(storageURL: goalURL, clock: { now }, startRuntime: false)
        try goals.saveProfile(profile)
        let robot = SalaryMilestone(id: "robot", name: "Robot", cents: 200_000, symbol: "gift", mode: .cumulative)
        try goals.saveMilestones([robot, .init(id: "coffee", name: "Coffee", cents: 2_000, symbol: "cup", mode: .daily)])
        func goal(_ id: String = "robot") -> SalaryMilestone { goals.data.milestones.first { $0.id == id }! }
        check(goals.goalEarnedCents(goal()) == 10_000, "new cumulative goal includes today's planned earnings")
        let goalStart = goal().startedAt
        now = time("2026-01-06", 8); goals.tick()
        check(goals.goalEarnedCents(goal()) == 80_000, "midnight preserves previous day's complete earnings")
        check(!goals.goalReached(goal("coffee")), "daily goal resets independently at next day")
        now = time("2026-01-06", 10); goals.tick()
        check(goals.goalEarnedCents(goal()) == 90_000, "cumulative goal adds today's partial earnings")
        let goalsReloaded = SalaryStore(storageURL: goalURL, clock: { now }, startRuntime: false)
        check(goalsReloaded.goalEarnedCents(goalsReloaded.data.milestones.first { $0.id == "robot" }!) == 90_000, "cumulative total and start date survive restart")
        goals.tick(); goals.tick()
        check(goals.goalEarnedCents(goal()) == 90_000, "repeated ticks never double count earnings")
        var changedRobot = goal(); changedRobot.name = "Renamed"; changedRobot.cents = 400_000
        try goals.saveMilestones([changedRobot, goal("coffee")])
        check(goal().startedAt == goalStart && goals.goalEarnedCents(goal()) == 90_000, "rename and price edits retain cumulative start and balance")
        now = time("2026-01-08", 10); goals.tick()
        check(goals.goalEarnedCents(goal()) == 250_000, "offline missed workday is filled from historical plan")
        let recordedPast = goals.data.days[SalaryEngine.ledgerID(day: "2026-01-07", zone: "Asia/Shanghai")]
        var doublePay = profile; doublePay.monthlyCents *= 2
        try goals.saveProfile(doublePay)
        check(goals.goalEarnedCents(goal()) == 260_000 && goals.data.days[recordedPast!.snapshot.id] == recordedPast, "salary edit updates today without repricing past cumulative days")
        try goals.saveMilestones([goal(), goal("coffee"), .init(id: "new", name: "New", cents: 500_000, symbol: "gift", mode: .cumulative)])
        check(goals.goalEarnedCents(goal("new")) == 20_000, "new goal does not inherit income from before creation day")
        now = time("2026-01-08", 18); goals.tick()
        check(goals.goalReached(goal()) && goal().achievedAt != nil, "cumulative goal completion is persisted")
        now = time("2026-01-09", 10); goals.tick()
        check(goals.goalReached(goal()) && !goals.todayEvents.contains { $0.kind == .cumulative }, "completed goal remains reached without another day's celebration")
        let totalBeforeDemo = goals.goalEarnedCents(goal())
        goals.startDemo(); goals.tick(); goals.endDemo()
        check(goals.goalEarnedCents(goal()) == totalBeforeDemo, "demo salary does not enter real cumulative progress")
        now = time("2026-01-10", 10); goals.tick()
        let saturdayTotal = goals.goalEarnedCents(goal("new"))
        now = time("2026-01-11", 18); goals.tick()
        check(goals.goalEarnedCents(goal("new")) == saturdayTotal, "rest days preserve balance without new earnings")
        now = time("2026-02-02", 10); goals.tick()
        check(goals.goalEarnedCents(goal("new")) > saturdayTotal, "cumulative progress crosses month boundaries")
        let beforeReset = goal("new").startedAt
        try goals.saveMilestones(goals.data.milestones.filter { $0.id != "new" })
        try goals.saveMilestones(goals.data.milestones + [.init(id: "replacement", name: "Replacement", cents: 500_000, symbol: "gift", mode: .cumulative)])
        check(goal("replacement").startedAt! > beforeReset!, "deleting and recreating a goal starts from the new day")

        var legacyGoals = SalaryData()
        legacyGoals.versions = [.init(effectiveDay: "2026-01-05", profile: profile)]
        let migrationSnapshot = try SalaryEngine.snapshot(at: time(10), versions: legacyGoals.versions)
        legacyGoals.days[migrationSnapshot.id] = SalaryDayLedger(snapshot: migrationSnapshot)
        legacyGoals.milestones = [.init(id: "old-large", name: "Legacy", cents: 400_000, symbol: "gift"), .init(id: "old-small", name: "Small", cents: 2_000, symbol: "cup")]
        let migrateURL = root.appendingPathComponent("legacy-goals.json")
        try JSONEncoder().encode(legacyGoals).write(to: migrateURL)
        now = time("2026-01-06",10)
        let migratedGoals = SalaryStore(storageURL: migrateURL, clock: { now }, startRuntime: false)
        let large = migratedGoals.data.milestones.first { $0.id == "old-large" }!
        check(large.mode == .cumulative && migratedGoals.goalEarnedCents(large) == 90_000, "legacy large goal migrates using earliest retained day")
        check(migratedGoals.data.milestones.first { $0.id == "old-small" }?.mode == .daily, "legacy small goal keeps daily behavior")
        let migratedAgain = SalaryStore(storageURL: migrateURL, clock: { now }, startRuntime: false)
        check(migratedAgain.data.milestones == migratedGoals.data.milestones, "goal migration is idempotent")

        now = time("2026-01-05", 10)
        let celebration = SalaryStore(storageURL: root.appendingPathComponent("celebration.json"), clock: { now }, startRuntime: false)
        try celebration.saveProfile(profile)
        try celebration.saveMilestones([.init(id: "big", name: "Big", cents: 81_000, symbol: "gift", mode: .cumulative)])
        now = time("2026-01-06", 9,5,59); celebration.tick(); celebration.toast = nil
        celebration.visibleSources.insert("test")
        now = time("2026-01-06", 9,6); celebration.tick()
        check(celebration.todayEvents.filter { $0.kind == .cumulative && $0.displayed }.count == 1, "live cumulative threshold shares existing notification scheduler")
        celebration.toast = nil; celebration.tick()
        check(celebration.todayEvents.filter { $0.kind == .cumulative }.count == 1, "repeated threshold tick cannot replay cumulative reward")
        try celebration.saveMilestones([.init(id: "lower", name: "Lower", cents: 500, symbol: "gift", mode: .cumulative)])
        check(celebration.toast == nil && celebration.data.milestones.first?.achievedAt != nil, "new already-funded goal records silently")

        // A timezone switch must not earn overlapping old-zone work after activation.
        now = time("2026-01-05",10)
        let travel = SalaryStore(storageURL: root.appendingPathComponent("goal-travel.json"), clock: { now }, startRuntime: false)
        try travel.saveProfile(profile)
        try travel.saveMilestones([.init(id: "trip-goal", name: "Trip", cents: 900_000, symbol: "gift", mode: .cumulative)])
        var destination = profile; destination.schedule.timeZoneID = "Asia/Tokyo"
        try travel.saveProfile(destination)
        now = time("2026-01-06",8); travel.tick()
        now = time("2026-01-06",10); travel.tick()
        let travelGoal = travel.data.milestones[0]
        let tokyoRate = travel.snapshot!.hourlyYuan * 100
        check(travel.goalEarnedCents(travelGoal) == 80_000 + Int64(tokyoRate), "timezone switch clips old zone and counts only destination time after activation")
        let travelBefore = travel.goalEarnedCents(travelGoal)
        now = time("2026-01-06",9,30); travel.tick()
        check(travel.goalEarnedCents(travelGoal) <= travelBefore, "clock rollback recomputes without accumulating duplicate seconds")
        now = time("2026-01-06",10); travel.tick()
        check(travel.goalEarnedCents(travelGoal) == travelBefore, "clock recovery returns to same cumulative balance")

        now = time("2026-01-05",10)
        let failGoalDir = root.appendingPathComponent("fail-goal-dir")
        let failGoals = SalaryStore(storageURL: failGoalDir.appendingPathComponent("salary.json"), clock: { now }, startRuntime: false)
        try failGoals.saveProfile(profile)
        let beforeGoals = failGoals.data.milestones
        try FileManager.default.removeItem(at: failGoalDir)
        try Data("blocked".utf8).write(to: failGoalDir)
        do { try failGoals.saveMilestones([robot]); fatalError("goal write failure accepted") }
        catch { check(failGoals.data.milestones == beforeGoals, "failed goal save leaves prior mode and progress intact") }
        print("\n\(count) store checks passed.")
    }
}
