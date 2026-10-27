import Foundation

/// Synthetic boundary matrix; never starts a provider process or reads credentials.
@main struct SalaryQuotaAcceptanceChecks {
    @MainActor static func main() throws {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            precondition(value(), label); assertions += 1
        }
        func malformed(_ data: String, _ parse: (Data) throws -> Void) {
            do { try parse(Data(data.utf8)); fatalError("invalid JSON accepted") }
            catch let error as AIQuotaError { check(error == .malformed, "malformed envelope") }
            catch { fatalError("unexpected error") }
        }
        let now = ISO8601DateFormatter().date(from: "2026-10-27T23:59:50Z")!
        func codex(_ token: String, reset: String = "null") throws -> AIQuotaSnapshot {
            try CodexQuotaParser.parse(Data("{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(token),\"resetsAt\":\(reset)}}}}".utf8), accountID: "fixture-source", updatedAt: now)
        }
        func glm(_ token: String, reset: String = "null") throws -> GLMCodingPlanSnapshot {
            try GLMCodingPlanParser.parse(Data("{\"code\":200,\"success\":true,\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"percentage\":\(token),\"nextResetTime\":\(reset)}]}}".utf8), accountID: "fixture-source", updatedAt: now)
        }
        func agy(_ token: String) throws -> [AGYQuotaWindow] {
            try AGYQuotaParser.parse(Data("{\"quota\":{\"gemini\":{\"remaining_fraction\":\(token)}}}".utf8), updatedAt: now)
        }
        for (token, expected) in [("0", Optional(0.0)), ("100", 100), ("12.5", 12.5), ("-1", nil), ("101", nil), ("null", nil)] {
            let c = try codex(token), g = try glm(token)
            check(c.windows[0].usedPercent == expected, "Codex percent boundary")
            check(g.windows[0].usedPercent == expected, "GLM percent boundary")
        }
        for (token, expected) in [("0", Optional(100.0)), ("1", 0), ("0.3333", 66.67), ("-0.1", nil), ("1.1", nil), ("null", nil)] {
            let used = try agy(token)[0].usedPercent
            check(expected.map { abs((used ?? -1000) - $0) < 0.000001 } ?? (used == nil), "AGY remaining conversion")
        }
        for token in ["NaN", "Infinity", "1e309", "\"NaN\""] {
            malformed("{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(token)}}}}") { _ = try CodexQuotaParser.parse($0, accountID: "fixture", updatedAt: now) }
            malformed("{\"code\":200,\"success\":true,\"data\":{\"limits\":[{\"percentage\":\(token)}]}}") { _ = try GLMCodingPlanParser.parse($0, accountID: "fixture", updatedAt: now) }
            malformed("{\"quota\":{\"gemini\":{\"remaining_fraction\":\(token)}}}") { _ = try AGYQuotaParser.parse($0, updatedAt: now) }
        }
        for (value, label) in [(Optional(0.0), "已用 0%"), (100, "已用 100%"), (2.49, "已用 2%"), (2.5, "已用 3%"), (99.6, "已用 100%"), (nil, "已用 —"), (-1, "已用 —"), (.nan, "已用 —"), (.infinity, "已用 —")] {
            check(AIQuotaPresentation.percent(value) == label, "integer half-away display rounding")
        }
        let reset = now.addingTimeInterval(20)
        let c = try codex("12.5", reset: String(reset.timeIntervalSince1970))
        let g = try glm("12.5", reset: String(reset.timeIntervalSince1970 * 1000))
        check(c.windows[0].resetsAt == g.windows[0].resetsAt && c.windows[0].resetsAt == reset, "seconds and milliseconds")
        check(c.windows[0].usedPercent == 12.5, "display rounding never changes raw value")
        check(AIQuotaPresentation.reset(reset, now: now, timeZone: TimeZone(secondsFromGMT: 0)!) == "重置 10/28 00:00", "cross-day UTC")
        check(AIQuotaPresentation.reset(reset, now: now, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!) == "重置 10/28 08:00", "local reset timezone")
        check(AIQuotaPresentation.reset(reset, now: reset) == "已到重置时间 · 待刷新", "reset equality")
        check(AIQuotaPresentation.reset(reset, now: reset.addingTimeInterval(1)) == "已到重置时间 · 待刷新", "past reset")
        check(AIQuotaPresentation.reset(nil, now: now) == "重置时间未知", "unknown reset")
        let expired = AIQuotaCardState(snapshot: c)
        check(!expired.isStale(at: reset.addingTimeInterval(-0.001)) && expired.isStale(at: reset), "reset staleness boundary")
        check(expired.snapshot?.windows[0].usedPercent == 12.5, "reset does not fabricate zero")
        let noWindows = AIQuotaCardState(snapshot: AIQuotaSnapshot(provider: "Codex", accountID: "fixture", updatedAt: now, windows: []))
        check(!noWindows.isStale(at: now.addingTimeInterval(899)) && noWindows.isStale(at: now.addingTimeInterval(900)), "cache age boundary")
        let emptyGLM = try GLMCodingPlanParser.parse(Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8), accountID: "fixture", updatedAt: now)
        check(emptyGLM.windows.isEmpty, "legal GLM no windows")
        malformed(#"{"code":200,"success":true,"data":{}}"#) { _ = try GLMCodingPlanParser.parse($0, accountID: "fixture", updatedAt: now) }
        let emptyAGY = try AGYQuotaParser.parse(Data(#"{"quota":{}}"#.utf8), updatedAt: now)
        check(emptyAGY.isEmpty, "legal statusline no windows")
        let invalidResetC = try codex("0", reset: "-1"), invalidResetG = try glm("0", reset: "-1")
        check(invalidResetC.windows[0].resetsAt == nil && invalidResetG.windows[0].resetsAt == nil, "invalid reset stays unknown")
        // Finite Double extremes must be rejected before Date/calendar conversion.
        for value in [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 1e308] {
            let extremeC = try codex("0", reset: String(value))
            let extremeG = try glm("0", reset: String(value))
            let extremeA = try AGYQuotaParser.parse(Data("{\"quota\":{\"gemini\":{\"reset_in_seconds\":\(value)}}}".utf8), updatedAt: now)
            check(extremeC.windows[0].resetsAt == nil, "Codex finite extreme reset")
            check(extremeG.windows[0].resetsAt == nil, "GLM finite extreme milliseconds")
            check(extremeA[0].resetsAt == nil, "AGY finite extreme relative reset")
            check(AIQuotaPresentation.reset(Date(timeIntervalSince1970: value), now: now) == "重置时间未知", "injected extreme Date display")
        }
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            check(AIQuotaTimestamp.seconds(value) == nil && AIQuotaTimestamp.milliseconds(value) == nil, "non-finite timestamp rejected")
            check(AIQuotaPresentation.reset(Date(timeIntervalSince1970: value), now: now) == "重置时间未知", "non-finite Date display")
        }
        let maximum = AIQuotaTimestamp.maximumUnixSeconds
        check(AIQuotaTimestamp.seconds(maximum + 1) == nil && AIQuotaTimestamp.milliseconds((maximum + 1) * 1000) == nil, "timestamp upper boundary")
        check(AIQuotaTimestamp.relative(1, to: Date(timeIntervalSince1970: maximum)) == nil, "relative addition range overflow")
        check(AIQuotaTimestamp.relative(0, to: Date(timeIntervalSince1970: .greatestFiniteMagnitude)) == nil, "invalid relative base")
        check(AIQuotaTimestamp.relative(0, to: now) == now, "zero relative interval remains valid")
        for offset in [-14 * 3600, 14 * 3600] {
            check(AIQuotaPresentation.reset(AIQuotaTimestamp.seconds(maximum), now: now, timeZone: TimeZone(secondsFromGMT: offset)!).hasPrefix("重置 12/"), "bounded maximum formats at timezone extremes")
        }
        for text in ["10000-01-01T00:00:00Z", "999999999999999999999-01-01T00:00:00Z", "1969-12-31T23:59:59Z"] {
            check(AIQuotaTimestamp.iso8601(text) == nil, "ISO range rejected before calendar display")
        }
        let unknown = GLMCodingPlanWindow(type: "new-limit", unitCode: 3, number: Int.max, usedPercent: nil, resetsAt: nil)
        check(unknown.durationMinutes == nil, "duration multiplication overflow")
        let oversized = Data(repeating: 32, count: 1_048_577)
        do { _ = try GLMCodingPlanParser.parse(oversized, accountID: "fixture", updatedAt: now); fatalError("unbounded GLM accepted") }
        catch let error as AIQuotaError { check(error == .malformed, "GLM input cap") }
        print("SalaryQuotaAcceptanceChecks: \(assertions) executed assertions; synthetic numeric/date/staleness/empty payload matrix passed")
    }
}
