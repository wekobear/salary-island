import Foundation

@MainActor final class QuotaTestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}
@MainActor final class QuotaTestGate {
    var calls = 0
    var continuation: CheckedContinuation<AIQuotaSnapshot, Error>?
    func read() async throws -> AIQuotaSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ value: AIQuotaSnapshot) { continuation?.resume(returning: value); continuation = nil }
}
@main struct SalaryAIQuotaStoreChecks {
    @MainActor static func main() async {
        let clock = QuotaTestClock()
        let store = AIQuotaStore(now: { clock.date })
        var calls = 0
        func sample(account: String = "fixture-a", provider: String = "Codex") -> AIQuotaSnapshot {
            AIQuotaSnapshot(provider: provider, accountID: account, updatedAt: clock.date, windows: [])
        }
        await store.refresh(.codex)
        precondition(!store.state(for: .codex).isConnected)
        store.connect(.codex, accountID: "fixture-a") { calls += 1; return sample() }
        await store.refresh(.codex)
        precondition(calls == 0, "hidden/locked must not read")
        store.setSuspended(false)
        await store.refresh(.codex)
        await store.refresh(.codex)
        precondition(calls == 1 && store.state(for: .codex).snapshot != nil, "minimum refresh interval")
        clock.date.addTimeInterval(901)
        precondition(store.state(for: .codex).isStale(at: clock.date))
        await store.refresh(.codex)
        precondition(calls == 2 && !store.state(for: .codex).isStale(at: clock.date))

        let gate = QuotaTestGate()
        store.connect(.codex, accountID: "fixture-a") { try await gate.read() }
        let first = Task { await store.refresh(.codex) }
        while gate.calls == 0 { await Task.yield() }
        let second = Task { await store.refresh(.codex) }
        for _ in 0..<20 { await Task.yield() }
        precondition(gate.calls == 1, "concurrent refresh must coalesce")
        gate.finish(sample())
        await first.value; await second.value
        precondition(!store.state(for: .codex).isRefreshing)

        store.connect(.codex, accountID: "fixture-a") { try await gate.read() }
        let canceled = Task { await store.refresh(.codex) }
        while gate.calls < 2 { await Task.yield() }
        store.disconnect(.codex)
        gate.finish(sample())
        await canceled.value
        precondition(!store.state(for: .codex).isConnected && store.state(for: .codex).snapshot == nil,
                     "late results after disconnect must not resurrect account")

        store.connect(.codex, accountID: "fixture-a") { try await gate.read() }
        let locked = Task { await store.refresh(.codex) }
        while gate.calls < 3 { await Task.yield() }
        store.setSuspended(true)
        gate.finish(sample())
        await locked.value
        precondition(!store.state(for: .codex).isRefreshing && store.state(for: .codex).snapshot == nil)
        store.setSuspended(false)

        var limitedCalls = 0
        store.connect(.codex, accountID: "fixture-a") {
            limitedCalls += 1
            throw AIQuotaReadFailure(.rateLimited, retryAfter: 2000)
        }
        await store.refresh(.codex)
        precondition(store.state(for: .codex).error == .rateLimited)
        clock.date.addTimeInterval(1999)
        await store.refresh(.codex)
        precondition(limitedCalls == 1, "Retry-After respected by manual refresh too")
        clock.date.addTimeInterval(1)
        await store.refresh(.codex)
        precondition(limitedCalls == 2)

        var offline = false
        store.connect(.codex, accountID: "fixture-a") {
            if offline { throw URLError(.notConnectedToInternet) }
            return sample()
        }
        await store.refresh(.codex)
        let lastGood = store.state(for: .codex).snapshot
        offline = true; clock.date.addTimeInterval(301)
        await store.refresh(.codex)
        precondition(store.state(for: .codex).error == .offline && store.state(for: .codex).snapshot == lastGood)
        precondition(store.state(for: .codex).isStale(at: clock.date), "failure labels preserved values stale")

        var unauthorizedCalls = 0
        store.connect(.codex, accountID: "fixture-a") { unauthorizedCalls += 1; throw AIQuotaError.unauthorized }
        await store.refresh(.codex)
        clock.date.addTimeInterval(10000)
        await store.refresh(.codex)
        precondition(unauthorizedCalls == 1 && store.state(for: .codex).error == .unauthorized)
        precondition(!store.state(for: .codex).isConnected && store.state(for: .codex).snapshot == nil)

        store.connect(.codex, accountID: "fixture-a") { sample(account: "other-account") }
        await store.refresh(.codex)
        precondition(store.state(for: .codex).snapshot == nil && store.state(for: .codex).error == .malformed)
        store.connect(.codex, accountID: "fixture-a") { sample(provider: "Gemini") }
        await store.refresh(.codex)
        precondition(store.state(for: .codex).snapshot == nil && store.state(for: .codex).error == .malformed)
        store.connect(.codex, accountID: "fixture-a") { throw CancellationError() }
        await store.refresh(.codex)
        precondition(store.state(for: .codex).error == nil && !store.state(for: .codex).isRefreshing)
        store.disconnect(.codex)
        var malformed = false
        store.connect(.codex, accountID: "fixture-a") {
            if malformed { return try CodexQuotaParser.parse(Data(#"{"id":2,"result":{}}"#.utf8), accountID: "fixture-a", updatedAt: clock.date) }
            return sample()
        }
        await store.refresh(.codex)
        let beforeMalformed = store.state(for: .codex).snapshot
        malformed = true; clock.date.addTimeInterval(301)
        await store.refresh(.codex)
        precondition(store.state(for: .codex).snapshot == beforeMalformed && store.state(for: .codex).error == .malformed)
        precondition(store.state(for: .codex).isStale(at: clock.date))
        var backend = "fixture-backend-A"
        store.connect(.codex, accountID: "fixture-a") {
            var result = sample(); result.backendAccountID = backend; return result
        }
        await store.refresh(.codex)
        backend = "fixture-backend-B"; clock.date.addTimeInterval(301)
        await store.refresh(.codex)
        precondition(store.state(for: .codex).accountChanged && store.state(for: .codex).snapshot?.backendAccountID == backend)
        var rejectedCalls = 0
        store.connect(.codex, accountID: "fixture-a") { rejectedCalls += 1; throw AIQuotaError.rpcRejected }
        await store.refresh(.codex); clock.date.addTimeInterval(10000); await store.refresh(.codex)
        precondition(rejectedCalls == 1 && !store.state(for: .codex).isConnected)
        store.disconnect(.codex)
        store.connect(.codex, accountID: "fixture-a") { try await gate.read() }
        let oldAccountRequest = Task { await store.refresh(.codex) }
        while gate.calls < 4 { await Task.yield() }
        store.connect(.codex, accountID: "fixture-b") { sample(account: "fixture-b") }
        precondition(store.state(for: .codex).snapshot == nil, "switch clears old source before reading new")
        await store.refresh(.codex)
        gate.finish(sample(account: "fixture-a")); await oldAccountRequest.value
        precondition(store.state(for: .codex).snapshot?.accountID == "fixture-b", "old source cannot overwrite new source")
        store.connect(.codex, accountID: "fixture-a") {
            AIQuotaSnapshot(provider: "Codex", accountID: "fixture-a", updatedAt: clock.date.addingTimeInterval(61), windows: [])
        }
        await store.refresh(.codex)
        precondition(store.state(for: .codex).error == .malformed && store.state(for: .codex).snapshot == nil, "future cache timestamp rejected")
        store.disconnect(.codex)
        print("SalaryAIQuotaStoreChecks: suspension, freshness, coalescing, disconnect, cancellation, simulated auth/rate-limit, retry, offline, source/provider checks and optional backend identity passed")
    }
}
