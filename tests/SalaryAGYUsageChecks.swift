import Foundation
@main struct SalaryAGYUsageChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = "Quota:\nGemini Models Five Hour Limit Remaining 60% 2027-01-10T08:00:00Z\nGemini Models Weekly Limit Remaining 75% 2027-01-15T08:00:00Z\nArgon Models Weekly Limit Remaining 20% 2027-01-15T08:00:00Z\nClaude and GPT models Weekly Limit Remaining 100% 2027-01-15T08:00:00Z"
        func parse(_ text: String, group: String = "Gemini Models") throws -> AIQuotaSnapshot {
            try AGYUsageTextParser.parse(Data(text.utf8), group: group, sourceID: "fixture", updatedAt: now, timeZone: TimeZone(identifier: "America/New_York")!)
        }
        let value = try parse(report)
        precondition(value.windows.count == 2 && value.windows[0].usedPercent == 40 && value.windows[1].usedPercent == 25)
        precondition(value.windows[0].durationMinutes == 300 && value.windows[1].durationMinutes == 10080)
        let argon = try parse(report, group: "Argon Models")
        precondition(argon.windows.first?.usedPercent == 80)
        for bad in ["", "model response with 50%", report.replacingOccurrences(of: "60%", with: "101%"), report.replacingOccurrences(of: "60%", with: "NaN%"), report.replacingOccurrences(of: "2027-01-10T08:00:00Z", with: "bad-date"), report + "\nGemini Models Weekly Limit Remaining 99% 2027-01-15T08:00:00Z", report.replacingOccurrences(of: "Quota:", with: "QuotaX:"), "\u{1b}]secret\u{7}" + report] {
            do { _ = try parse(bad); fatalError("invalid report accepted") } catch let e as AIQuotaError { precondition(e == .malformed) }
        }
        let unknown = try parse("Quota:\nGemini Models Monthly Limit Remaining 5% unknown")
        precondition(unknown.windows[0].durationMinutes == nil && unknown.windows[0].resetsAt == nil)
        let colour = try parse("\u{1b}[32m" + report + "\u{1b}[0m")
        precondition(colour.windows == value.windows)
        let utc = try QuotaResetDateParser.parse("2027-01-15 08:00 UTC", timeZone: .current)
        let offset = try QuotaResetDateParser.parse("2027-01-15 13:30 +0530", timeZone: .current)
        precondition(utc == offset)
        for bad in ["2027-01-15 08:00 CST", "2026-11-01 01:30 EDT", "2026-03-08 02:30 EST", "2027-01-15 08:00 +1460"] {
            do { _ = try QuotaResetDateParser.parse(bad, timeZone: TimeZone(identifier: "America/New_York")!); fatalError("invalid/ambiguous timezone accepted") }
            catch let e as AIQuotaError { precondition(e == .malformed) }
        }
        print("SalaryAGYUsageChecks: strict report, exact groups, remaining semantics, ANSI, duplicates, offsets and DST checks passed")
    }
}
