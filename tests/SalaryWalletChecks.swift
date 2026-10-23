import Foundation

/// Pure fixtures only: no SalaryStore, app runtime, or on-disk salary data.
@main @MainActor
struct SalaryWalletChecks {
    static var count = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }
        count += 1
        print("PASS \(label)")
    }

    static func time(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        SalaryEngine.date(for: "2026-01-05", timeZoneID: "Asia/Shanghai")
            .addingTimeInterval(Double(hour * 3600 + minute * 60 + second))
    }

    static func fixture() -> SalarySnapshot {
        SalarySnapshot(
            id: "2026-01-05|Asia/Shanghai", dayKey: "2026-01-05", versionID: "wallet-fixture",
            monthlyCents: 1_760_000, denominatorSeconds: 22 * 8 * 3600,
            intervals: [.init(start: time(9), end: time(12)), .init(start: time(13), end: time(18))],
            shiftStart: time(9), shiftEnd: time(18), tax: .afterTax, timeZoneID: "Asia/Shanghai"
        )
    }

    static func state(at date: Date, snapshot: SalarySnapshot?) -> SalaryWalletState {
        let progress: Double
        if let snapshot, snapshot.dayCents > 0 {
            progress = snapshot.earnedCents(at: date) / snapshot.dayCents
        } else {
            progress = 0
        }
        return SalaryWalletState(progress: progress, date: date, snapshot: snapshot)
    }

    static func checkSuppressed(_ label: String, previous: SalaryWalletState, current: SalaryWalletState) {
        check(!current.isLiveContinuation(of: previous), "\(label): not a live continuation")
        check(!current.crossesQuarter(since: previous), "\(label): no falling coin")
    }

    static func main() {
        let snapshot = fixture()
        let clampingCases: [(String, Double, Double)] = [
            ("NaN", .nan, 0), ("positive infinity", .infinity, 0),
            ("negative infinity", -.infinity, 0), ("negative progress", -0.1, 0),
            ("empty", 0, 0), ("partial", 0.375, 0.375),
            ("full", 1, 1), ("overfull", 1.1, 1)
        ]
        for (label, input, expected) in clampingCases {
            let value = SalaryWalletState(progress: input, date: time(11), snapshot: nil)
            check(value.displayedProgress == expected, "display clamps \(label)")
        }
        for progress in [0.0, 0.25, 0.5, 1.0, 1.5] {
            var value = SalaryWalletState(progress: progress, date: time(11), snapshot: snapshot)
            value.hidden = true
            check(value.displayedProgress == 0, "privacy fixes fullness at zero for \(progress)")
        }

        // Eight paid hours, with an unpaid lunch: 25/50/75/100% at 11/14/16/18.
        for (index, boundary) in [time(11), time(14), time(16), time(18)].enumerated() {
            let quarter = index + 1
            let previous = state(at: boundary.addingTimeInterval(-1), snapshot: snapshot)
            var current = state(at: boundary, snapshot: snapshot)
            // Deliberately model a floating-point ratio just below its true value.
            // The coin boundary must still come from integer paid seconds.
            current.progress = (Double(quarter) / 4).nextDown
            let following = state(at: boundary.addingTimeInterval(1), snapshot: snapshot)
            check(previous.quarter == quarter - 1, "\(quarter * 25)% not reached one second early")
            check(current.quarter == quarter, "\(quarter * 25)% uses the exact paid-second boundary")
            check(current.isLiveContinuation(of: previous), "\(quarter * 25)% is a live transition")
            check(current.crossesQuarter(since: previous), "\(quarter * 25)% drops one coin")
            check(!following.crossesQuarter(since: current), "\(quarter * 25)% does not replay next second")
        }

        // A duration not divisible by four requires rounding each boundary up.
        var shortSnapshot = snapshot
        shortSnapshot.intervals = [.init(start: time(9), end: time(9, 0, 7))]
        shortSnapshot.shiftEnd = time(9, 0, 7)
        for (index, seconds) in [2, 4, 6, 7].enumerated() {
            let previous = state(at: time(9, 0, seconds - 1), snapshot: shortSnapshot)
            let current = state(at: time(9, 0, seconds), snapshot: shortSnapshot)
            check(previous.quarter == index, "seven-second shift quarter \(index + 1) does not arrive early")
            check(current.quarter == index + 1 && current.crossesQuarter(since: previous),
                  "seven-second shift quarter \(index + 1) arrives at its first whole paid second")
        }

        let beforeWork = state(at: time(8), snapshot: snapshot)
        check(beforeWork.displayedProgress == 0 && beforeWork.quarter == 0, "before work is empty")
        let atStart = state(at: time(9), snapshot: snapshot)
        check(atStart.displayedProgress == 0 && atStart.quarter == 0, "shift start is empty")
        var restSnapshot = snapshot
        restSnapshot.intervals = []
        restSnapshot.shiftStart = nil
        restSnapshot.shiftEnd = nil
        let rest = state(at: time(12), snapshot: restSnapshot)
        check(rest.displayedProgress == 0 && rest.quarter == 0, "rest day is empty without division by zero")
        let finished = state(at: time(18), snapshot: snapshot)
        check(finished.displayedProgress == 1 && finished.quarter == 4, "shift end is full")
        let afterWork = state(at: time(19), snapshot: snapshot)
        check(afterWork.displayedProgress == 1 && afterWork.quarter == 4, "after work remains capped at full")

        let lunchStart = state(at: time(12), snapshot: snapshot)
        let lunchMiddle = state(at: time(12, 30), snapshot: snapshot)
        let lunchNext = state(at: time(12, 30, 1), snapshot: snapshot)
        check(lunchStart.displayedProgress == lunchMiddle.displayedProgress, "unpaid lunch does not fill the wallet")
        check(lunchStart.quarter == lunchMiddle.quarter, "unpaid lunch does not change the quarter")
        check(lunchNext.isLiveContinuation(of: lunchMiddle), "ordinary lunch ticks remain live")
        check(!lunchNext.crossesQuarter(since: lunchMiddle), "ordinary lunch ticks do not drop a coin")
        let noSnapshot = state(at: time(11), snapshot: nil)
        check(noSnapshot.displayedProgress == 0 && noSnapshot.quarter == 0, "unconfigured state is empty")

        let previous = state(at: time(10, 59, 59), snapshot: snapshot)
        let current = state(at: time(11), snapshot: snapshot)
        var longGap = current
        longGap.date = previous.date.addingTimeInterval(6)
        checkSuppressed("gap greater than five seconds", previous: previous, current: longGap)
        var sameTime = current
        sameTime.date = previous.date
        checkSuppressed("same timestamp", previous: previous, current: sameTime)
        var backwards = current
        backwards.date = previous.date.addingTimeInterval(-1)
        checkSuppressed("clock moves backwards", previous: previous, current: backwards)

        var demoCurrent = current
        demoCurrent.demo = true
        checkSuppressed("entering demo", previous: previous, current: demoCurrent)
        var demoPrevious = previous
        demoPrevious.demo = true
        checkSuppressed("leaving demo", previous: demoPrevious, current: current)
        var changedIncome = current
        changedIncome.snapshot?.monthlyCents += 100
        checkSuppressed("income correction with the same snapshot ID", previous: previous, current: changedIncome)
        var changedSchedule = current
        changedSchedule.snapshot?.intervals[0].end = time(11, 59)
        checkSuppressed("schedule correction with the same snapshot ID", previous: previous, current: changedSchedule)
        var changedDay = current
        changedDay.snapshot?.id = "2026-01-06|Asia/Shanghai"
        changedDay.snapshot?.dayKey = "2026-01-06"
        checkSuppressed("day identity changes", previous: previous, current: changedDay)
        var missingSnapshot = current
        missingSnapshot.snapshot = nil
        checkSuppressed("snapshot disappears", previous: previous, current: missingSnapshot)
        var revised = current
        revised.revision = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        checkSuppressed("motion revision changes", previous: previous, current: revised)

        var disallowedPrevious = previous
        disallowedPrevious.motionAllowed = false
        checkSuppressed("motion was disallowed", previous: disallowedPrevious, current: current)
        var disallowedCurrent = current
        disallowedCurrent.motionAllowed = false
        checkSuppressed("motion becomes disallowed", previous: previous, current: disallowedCurrent)
        var hiddenPrevious = previous
        hiddenPrevious.hidden = true
        checkSuppressed("privacy is turned off", previous: hiddenPrevious, current: current)
        var hiddenCurrent = current
        hiddenCurrent.hidden = true
        checkSuppressed("privacy is turned on", previous: previous, current: hiddenCurrent)
        checkSuppressed("privacy stays on", previous: hiddenPrevious, current: hiddenCurrent)
        var decreased = current
        decreased.progress = 0.1
        checkSuppressed("progress decreases", previous: previous, current: decreased)

        let fiveSecondsBefore = state(at: time(10, 59, 55), snapshot: snapshot)
        check(current.isLiveContinuation(of: fiveSecondsBefore), "exactly five seconds remains live")
        check(current.crossesQuarter(since: fiveSecondsBefore), "exactly five seconds can cross a quarter")
        print("SalaryWalletChecks: \(count) checks passed")
    }
}
