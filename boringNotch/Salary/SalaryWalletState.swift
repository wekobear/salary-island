import Foundation

/// Ephemeral visual state. Never persisted and never used to calculate wages.
struct SalaryWalletState: Equatable {
    var progress: Double
    var date: Date
    var snapshot: SalarySnapshot?
    var demo = false
    var hidden = false
    var motionAllowed = true
    var revision = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var quarter: Int {
        if let snapshot, snapshot.plannedSeconds > 0 {
            return min(4, max(0, Int(snapshot.elapsedSeconds(at: date) * 4 / snapshot.plannedSeconds)))
        }
        return Int(floor(displayedProgress * 4))
    }

    var displayedProgress: Double {
        hidden || !progress.isFinite ? 0 : min(1, max(0, progress))
    }

    func isLiveContinuation(of previous: Self) -> Bool {
        let elapsed = date.timeIntervalSince(previous.date)
        return motionAllowed && previous.motionAllowed && !hidden && !previous.hidden
            && snapshot == previous.snapshot && demo == previous.demo && revision == previous.revision
            && elapsed > 0 && elapsed <= 5
            && displayedProgress >= previous.displayedProgress
    }

    func crossesQuarter(since previous: Self) -> Bool {
        isLiveContinuation(of: previous)
            && quarter > previous.quarter
    }
}
