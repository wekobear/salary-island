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
        print("\n\(count) store checks passed.")
    }
}
