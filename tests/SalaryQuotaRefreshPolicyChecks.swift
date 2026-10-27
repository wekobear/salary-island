import AppKit
import Foundation

@MainActor private final class RefreshClock { var now = Date() }
private actor RefreshHTTP: CNHTTPTransport {
    var calls = 0
    let reset: Int
    init(reset: Int) { self.reset = reset }
    func send(_ request: URLRequest) async throws -> CNHTTPResponse {
        calls += 1
        return CNHTTPResponse(status: 200, retryAfter: nil,
            body: Data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":40,\"limit_window_seconds\":18000,\"reset_at\":\(reset)}}}".utf8))
    }
}
@main struct SalaryQuotaRefreshPolicyChecks {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { count += 1; precondition(value,label) }
    @MainActor static func main() async throws {
        let clock = RefreshClock()
        let base = clock.now
        let store = AIQuotaStore(now:{clock.now})
        var calls = 0, fail = false
        var reset = base.addingTimeInterval(60)
        func snapshot() -> AIQuotaSnapshot {
            AIQuotaSnapshot(provider:"Codex",accountID:"fixture",updatedAt:clock.now,windows:[
                AIQuotaWindow(bucketID:"fixture",bucketName:nil,position:"primary",usedPercent:40,durationMinutes:300,resetsAt:reset),
                AIQuotaWindow(bucketID:"fixture",bucketName:nil,position:"secondary",usedPercent:25,durationMinutes:10080,resetsAt:reset)])
        }
        store.connect(.codex,accountID:"fixture") {
            calls += 1
            if fail { throw AIQuotaReadFailure(.rateLimited,retryAfter:1000) }
            return snapshot()
        }
        store.setSuspended(false)
        await store.refresh(.codex)
        check(calls == 1,"initial read once")
        clock.now = base.addingTimeInterval(59)
        await store.refresh(.codex)
        check(calls == 1,"no request before five minutes or reset")
        clock.now = base.addingTimeInterval(60)
        await store.refresh(.codex)
        check(calls == 2,"two simultaneous resets coalesce to one supplemental read")
        for offset in 61...75 { clock.now = base.addingTimeInterval(Double(offset)); await store.refresh(.codex) }
        check(calls == 2,"stale server reset cannot trigger on every clock check")
        clock.now = base.addingTimeInterval(359); await store.refresh(.codex)
        check(calls == 2,"normal cadence stays five minutes after supplemental read")
        clock.now = base.addingTimeInterval(360); await store.refresh(.codex)
        check(calls == 3,"normal five-minute read resumes")
        clock.now = base.addingTimeInterval(365); await store.refresh(.codex,manual:true)
        check(calls == 4,"manual action may refresh before next normal deadline")
        check(store.state(for:.codex).snapshot?.updatedAt == clock.now,"manual result updates timestamp")
        clock.now = base.addingTimeInterval(366); await store.refresh(.codex)
        check(calls == 4,"manual action does not create extra automatic requests")

        // Concurrent reset/manual requests use the same in-flight work.
        var concurrentCalls = 0
        let concurrent = AIQuotaStore(now:{clock.now})
        concurrent.setSuspended(false)
        concurrent.connect(.codex,accountID:"fixture") {
            concurrentCalls += 1
            try await Task.sleep(for:.milliseconds(20))
            return snapshot()
        }
        async let left: Void = concurrent.refresh(.codex)
        async let right: Void = concurrent.refresh(.codex,manual:true)
        _ = await (left,right)
        check(concurrentCalls == 1,"manual and scheduled calls share one request")

        // A future reset and manual action cannot override 429 Retry-After.
        reset = clock.now.addingTimeInterval(20)
        await store.refresh(.codex,manual:true)
        fail = true; clock.now.addTimeInterval(1)
        await store.refresh(.codex,manual:true)
        let limitedCalls = calls
        let retry = store.state(for:.codex).nextRefreshAt!
        clock.now.addTimeInterval(30)
        await store.refresh(.codex); await store.refresh(.codex,manual:true)
        check(calls == limitedCalls,"reset and manual respect rate-limit backoff")
        clock.now = retry.addingTimeInterval(-1); await store.refresh(.codex,manual:true)
        check(calls == limitedCalls,"no early retry")
        fail = false; clock.now = retry; await store.refresh(.codex)
        check(calls == limitedCalls+1,"retry allowed at server deadline")
        store.setSuspended(true); clock.now.addTimeInterval(1000)
        await store.refresh(.codex,manual:true)
        check(calls == limitedCalls+1,"suspension blocks manual and automatic work")
        store.disconnect(.codex); store.setSuspended(false)
        await store.refresh(.codex,manual:true)
        check(!store.state(for:.codex).isConnected && calls == limitedCalls+1,"disconnect stops future reads")

        // Exercise the real manager loop with a fast test-only wake and fake HTTP.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-refresh-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("synthetic-auth.json")
        try Data(#"{"tokens":{"access_token":"synthetic-token","account_id":"synthetic-account"}}"#.utf8).write(to:source)
        let managerClock = RefreshClock(), start = Date()
        managerClock.now = start
        let fake = RefreshHTTP(reset:Int(start.timeIntervalSince1970)+60)
        let manager = AIQuotaConnections(store:AIQuotaStore(now:{managerClock.now}),waitForRefreshCheck:{ try await Task.sleep(for:.milliseconds(2)) })
        manager.setVisible(true)
        try manager.selectCodenotch(.codex,url:source)
        try await manager.connectCodenotch(.codex,periodically:true,transport:fake)
        let initialCalls = await fake.calls
        check(manager.automatic == [.codex] && initialCalls == 1,"explicit periodic grant wires fake reader")
        try await Task.sleep(for:.milliseconds(20))
        check(await fake.calls == 1,"many local clock checks produce no early network reads")
        managerClock.now = start.addingTimeInterval(60)
        for _ in 0..<100 { if await fake.calls >= 2 { break }; try await Task.sleep(for:.milliseconds(2)) }
        check(await fake.calls == 2,"manager loop detects reset supplemental read")
        try await Task.sleep(for:.milliseconds(20))
        check(await fake.calls == 2,"manager does not repeat expired reset")
        managerClock.now = start.addingTimeInterval(360)
        for _ in 0..<100 { if await fake.calls >= 3 { break }; try await Task.sleep(for:.milliseconds(2)) }
        check(await fake.calls == 3,"manager loop observes normal five-minute cadence")
        manager.disconnect(.codex); managerClock.now.addTimeInterval(1000)
        try await Task.sleep(for:.milliseconds(20))
        check(await fake.calls == 3 && manager.automatic.isEmpty,"disconnect stops loop")
        try manager.selectCodenotch(.codex,url:source)
        try await manager.connectCodenotch(.codex,periodically:true,transport:fake)
        let beforeExit = await fake.calls
        NotificationCenter.default.post(name:NSApplication.willTerminateNotification,object:nil)
        check(manager.automatic.isEmpty && manager.codenotchFiles.isEmpty && !manager.store.state(for:.codex).isConnected,"termination revokes grants and source")
        managerClock.now.addTimeInterval(1000)
        try await Task.sleep(for:.milliseconds(20))
        check(await fake.calls == beforeExit,"termination stops future loop requests")
        print("SalaryQuotaRefreshPolicyChecks: \(count) executed assertions across cadence, reset-once, manual, coalescing, backoff, suspension, disconnect and termination; fake HTTP only")
    }
}
