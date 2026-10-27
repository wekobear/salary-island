import Foundation

@main struct SalaryAIQuotaChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let raw = #"{"result":{"rateLimits":{"limitId":"legacy","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1800000300},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1800600000}},"extra":{"limitId":"extra","primary":{"usedPercent":null,"windowDurationMins":null,"resetsAt":null}}}}}"#
        let snapshot = try CodexQuotaParser.parse(Data(raw.utf8), accountID: "fixture-account", updatedAt: now)
        precondition(snapshot.accountID == "fixture-account" && snapshot.updatedAt == now)
        precondition(snapshot.windows.count == 3 && snapshot.windows.allSatisfy { $0.bucketID != "legacy" })
        precondition(snapshot.windows[0].usedPercent == 40 && snapshot.windows[0].durationMinutes == 300)
        precondition(snapshot.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_300))
        precondition(snapshot.windows[1].usedPercent == 60 && snapshot.windows[1].durationMinutes == 10080)
        precondition(snapshot.windows[2].usedPercent == nil && snapshot.windows[2].resetsAt == nil)
        let legacy = #"{"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":-1,"resetsAt":-1}}}}"#
        let one = try CodexQuotaParser.parse(Data(legacy.utf8), accountID: "another", updatedAt: now)
        precondition(one.windows.first?.usedPercent == 0 && one.windows.first?.durationMinutes == nil && one.windows.first?.resetsAt == nil)
        for (code, expected) in [(-32600, AIQuotaError.rpcRejected), (-32603, AIQuotaError.unavailable), (401, AIQuotaError.unavailable)] {
            let data = Data("{\"error\":{\"code\":\(code)}}".utf8)
            do { _ = try CodexQuotaParser.parse(data, accountID: "fixture", updatedAt: now); fatalError("expected error") }
            catch let error as AIQuotaError { precondition(error == expected) }
        }
        do { _ = try CodexQuotaParser.parse(Data("not json".utf8), accountID: "fixture", updatedAt: now); fatalError("expected malformed") }
        catch let error as AIQuotaError { precondition(error == .malformed) }
        let glm = #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":40,"nextResetTime":1800000300000},{"type":"TIME_LIMIT","percentage":null},{"type":"CREDIT_LIMIT","percentage":101}]}}"#
        let plan = try GLMCodingPlanParser.parse(Data(glm.utf8), accountID: "fixture-glm", updatedAt: now)
        precondition(plan.windows.count == 3 && plan.accountID == "fixture-glm")
        precondition(plan.windows[0].unitCode == 3 && plan.windows[0].number == 5 && plan.windows[0].usedPercent == 40)
        precondition(plan.windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_300))
        precondition(plan.windows[1].resetsAt == nil && plan.windows[1].usedPercent == nil)
        precondition(plan.windows[2].usedPercent == nil)
        for (code, expected) in [(401, AIQuotaError.unauthorized), (403, AIQuotaError.unauthorized), (429, AIQuotaError.rateLimited), (500, AIQuotaError.unavailable)] {
            let data = Data("{\"code\":\(code),\"success\":false,\"data\":\"unparseable\"}".utf8)
            do { _ = try GLMCodingPlanParser.parse(data, accountID: "fixture", updatedAt: now); fatalError("expected error") }
            catch let error as AIQuotaError { precondition(error == expected) }
        }
        do { _ = try GLMCodingPlanParser.parse(Data(#"{"code":200,"success":false}"#.utf8), accountID: "fixture", updatedAt: now); fatalError("expected failure") }
        catch let error as AIQuotaError { precondition(error == .unavailable) }
        let agy = #"{"email":"DO-NOT-RETAIN","transcript_path":"DO-NOT-READ","quota":{"gemini-weekly":{"remaining_fraction":0.75,"reset_time":"2027-01-15T08:00:00Z"},"argon":{"remaining_fraction":0.2},"claude-gpt":{"remaining_amount":12.5},"invalid":{"remaining_fraction":2},"disabled":{"disabled":true,"reset_in_seconds":30}}}"#
        let groups = try AGYQuotaParser.parse(Data(agy.utf8), updatedAt: now)
        precondition(groups.count == 5)
        let selected = AGYQuotaParser.selected(groups, bucketIDs: ["gemini-weekly"])
        precondition(selected.count == 1 && selected[0].usedPercent == 25)
        precondition(groups.first { $0.bucketID == "claude-gpt" }?.usedPercent == nil)
        precondition(groups.first { $0.bucketID == "claude-gpt" }?.remainingAmount == 12.5)
        precondition(groups.first { $0.bucketID == "invalid" }?.remainingFraction == nil)
        precondition(groups.first { $0.bucketID == "disabled" }?.disabled == true)
        precondition(groups.first { $0.bucketID == "disabled" }?.resetsAt == now.addingTimeInterval(30))
        precondition(plan.windows[0].durationMinutes == 300)
        precondition(GLMCodingPlanWindow(type: "CREDIT_LIMIT", unitCode: 6, number: 1, usedPercent: 10, resetsAt: nil).durationMinutes == 10080)
        precondition(GLMCodingPlanWindow(type: "UNKNOWN", unitCode: 999, number: 1, usedPercent: nil, resetsAt: nil).durationMinutes == nil)
        var rpc = CodexQuotaRPC()
        let initResponse = try rpc.receive(Data(#"{"id":1,"result":{"userAgent":"fixture"}}"#.utf8))
        precondition(initResponse.write == CodexQuotaRPC.limits && initResponse.response == nil)
        let notification = try rpc.receive(Data(#"{"method":"untrusted/request","params":{"text":"ignored"}}"#.utf8))
        precondition(notification.write == nil && notification.response == nil)
        let quotaResponse = Data(#"{"id":2,"result":{"rateLimits":null}}"#.utf8)
        let finalRPC = try rpc.receive(quotaResponse)
        precondition(finalRPC.response == quotaResponse)
        let methods = String(data: CodexQuotaRPC.initialize + CodexQuotaRPC.limits, encoding: .utf8)!
        precondition(!methods.contains("thread/") && !methods.contains("turn/") && !methods.contains("login"))
        for invalid in [#"{"id":2,"result":{}}"#, #"{"id":2,"result":{"rateLimitsByLimitId":{}}}"#] {
            do { _ = try CodexQuotaParser.parse(Data(invalid.utf8), accountID: "fixture", updatedAt: now); fatalError("missing quota accepted") }
            catch let error as AIQuotaError { precondition(error == .malformed) }
        }
        let credits = try CodexQuotaParser.parse(Data(#"{"result":{"rateLimits":{"credits":{"hasCredits":true}},"accountId":"fixture-backend-A"}}"#.utf8), accountID: "source", updatedAt: now)
        precondition(credits.windows.isEmpty && credits.backendAccountID == "fixture-backend-A")
        print("SalaryAIQuotaChecks: Codex, GLM, AGY and read-only RPC fixtures passed")
    }
}
