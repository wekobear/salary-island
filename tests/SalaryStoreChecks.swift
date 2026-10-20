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
        check(store.snapshot == originalDay, "saving future plan preserves today's snapshot")
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
        print("\n\(count) store checks passed.")
    }
}
