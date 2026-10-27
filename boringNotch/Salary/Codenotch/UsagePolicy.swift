// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Port of UsageStore.hasWindowRolledOver/shouldRefresh/shouldRefreshOnEvent
// and provider retryAfter, commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Bounded numeric Retry-After validation also reviewed from a GLM 5.3 draft.
import Foundation

enum CNUsagePolicy {
    static func hasWindowRolledOver(in snapshots: [AIQuotaSnapshot], since last: Date?, at now: Date) -> Bool {
        guard let last else { return false }
        return snapshots.contains { snapshot in
            snapshot.windows.contains { window in
                guard let resetsAt = window.resetsAt else { return false }
                return resetsAt > last && resetsAt <= now
            }
        }
    }
    static func shouldRefresh(isBusy: Bool, sinceLastAttempt: TimeInterval, idleInterval: TimeInterval,
                              busyInterval: TimeInterval = 0, resetDue: Bool = false) -> Bool {
        if resetDue { return true }
        if isBusy { return sinceLastAttempt >= busyInterval }
        return sinceLastAttempt >= idleInterval
    }
    static func shouldRefreshOnEvent(sinceLastRefresh: TimeInterval, spacing: TimeInterval) -> Bool {
        sinceLastRefresh >= spacing
    }
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let raw = value, raw.utf8.count <= 128 else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil {
            guard let seconds = Double(text), seconds.isFinite, (0...604800).contains(seconds) else { return nil }
            return seconds
        }
        guard AIQuotaTimestamp.validated(now) != nil,
              text.range(of: #"^[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"; formatter.isLenient = false
        guard let date = formatter.date(from: text).flatMap(AIQuotaTimestamp.validated), formatter.string(from: date) == text else { return nil }
        let seconds = date.timeIntervalSince(now)
        return seconds.isFinite && (0...604800).contains(seconds) ? seconds : nil
    }
}
