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
        let headerless = "Gemini Models Weekly Limit Remaining 62% 2028-03-14T09:30:00Z\nGemini Models Five Hour Limit Remaining 48% 2028-03-11T12:45:00Z\nClaude and GPT models Weekly Limit Remaining 91% 2028-03-14T09:30:00Z\nClaude and GPT models Five Hour Limit Remaining 77% 2028-03-11T12:45:00Z\nGemini 7 Argon Gemini 7 Argon Weekly Limit 35% 2028-03-14T09:30:00Z"
        let strict = try parse(headerless)
        precondition(strict.windows.count == 2 && strict.windows[0].position == "Five Hour" && strict.windows[0].usedPercent == 52 && strict.windows[1].position == "Weekly" && strict.windows[1].usedPercent == 38)
        precondition(strict.windows.allSatisfy { $0.durationMinutes != nil } && !strict.windows.contains { $0.usedPercent == 65 })
        let tabbed = "Gemini\u{9}Models \t Weekly \t Limit \t Remaining \t 62% 2028-03-14T09:30:00Z\nGemini Models \t Five \t Hour Limit Remaining 48% 2028-03-11T12:45:00Z\nClaude and GPT models\tWeekly\tLimit\tRemaining 91% 2028-03-14T09:30:00Z\nGemini \t 7 Argon Gemini \t 7 Argon Weekly \t Limit \t 35% 2028-03-11T12:45:00Z"
        // Reproduces the verified CLI column structure using invented values.
        let verifiedShape = try String(contentsOfFile: "tests/fixtures/AGYVerifiedRedactedFixture.txt", encoding: .utf8)
        let verifiedSnapshot = try parse(verifiedShape)
        precondition(verifiedSnapshot.windows.count == 2 && verifiedSnapshot.windows.allSatisfy { $0.usedPercent == 50 })
        precondition(verifiedShape.filter { $0 == "\t" }.count == 15)
        let syntheticPath = "tests/fixtures/AGYHypotheticalTabbedReport.txt"
        let synthetic = try String(contentsOfFile: syntheticPath, encoding: .utf8)
        let syntheticResult = try parse(synthetic)
        precondition(syntheticResult.windows.count == 2 && syntheticResult.windows.allSatisfy { $0.usedPercent == 50 })
        let flexible = try parse(tabbed)
        precondition(flexible.windows.count == 2 && flexible.windows[0].position == "Five Hour" && flexible.windows[0].usedPercent == 52 && flexible.windows[1].position == "Weekly" && flexible.windows[1].usedPercent == 38)
        precondition(flexible.windows == strict.windows)
        let crlfColour = try parse("\u{1b}[32m" + tabbed.replacingOccurrences(of: "\n", with: "\r\n") + "\u{1b}[0m")
        precondition(crlfColour.windows == flexible.windows)
        let tabbedHeader = try parse("Quota:\nGemini\u{9}Models \t Five Hour \t Limit \t Remaining \t 60% 2027-01-10T08:00:00Z")
        precondition(tabbedHeader.windows.count == 1 && tabbedHeader.windows[0].usedPercent == 40 && tabbedHeader.windows[0].durationMinutes == 300)
        for bad in [tabbed.replacingOccurrences(of: "\t", with: "\u{b}"), tabbed.replacingOccurrences(of: "\t", with: "\u{a0}"), tabbed.replacingOccurrences(of: "\t", with: "\u{2003}"), "\u{1b}]0;title\u{7}" + tabbed, tabbed + "\rGemini Models Weekly Limit Remaining 30% 2028-03-14T09:30:00Z", tabbed.replacingOccurrences(of: "62%", with: "101%"), tabbed.replacingOccurrences(of: "62%", with: "6\u{9}2%"), tabbed + "\nGemini Models \t Weekly Limit Remaining 30% 2028-03-14T09:30:00Z"] {
            do { _ = try parse(bad); fatalError("invalid tab, control or percentage report accepted") } catch let e as AIQuotaError { precondition(e == .malformed) }
        }
        for bad in [headerless + "\nquota engine offline", headerless.replacingOccurrences(of: "62%", with: "101%"), headerless.replacingOccurrences(of: "48%", with: "NaN%"), headerless.replacingOccurrences(of: "2028-03-14T09:30:00Z", with: "not-a-date"), headerless + "\nGemini Models Weekly Limit Remaining 30% 2028-03-14T09:30:00Z", headerless + "\nGemini Models Monthly Limit Remaining 5% unknown", headerless.replacingOccurrences(of: "Gemini 7 Argon Gemini 7 Argon", with: "Gemini 7 Argon Gemini 8 Argon"), headerless.replacingOccurrences(of: "Weekly Limit 35%", with: "Weekly Limit 140%"), headerless + "\nGemini 7 Argon Gemini 7 Argon Weekly Limit 12% 2028-03-14T09:30:00Z", headerless.replacingOccurrences(of: "Claude and GPT models", with: "Claude and GPT Models"), "Argon Models Weekly Limit Remaining 15% 2028-03-14T09:30:00Z\nGemini 7 Argon Gemini 7 Argon Weekly Limit 35% 2028-03-14T09:30:00Z"] {
            do { _ = try parse(bad); fatalError("invalid headerless report accepted") } catch let e as AIQuotaError { precondition(e == .malformed) }
        }
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
        print("SalaryAGYUsageChecks: strict report, headerless validation, tab/space separators, control and Unicode whitespace rejection, exact groups, remaining semantics, ANSI, duplicates, offsets and DST checks passed")
    }
}
