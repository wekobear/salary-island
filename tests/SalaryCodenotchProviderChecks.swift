import Foundation
import Darwin

private actor FixtureHTTP: CNHTTPTransport {
    var responses: [CNHTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [CNHTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> CNHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw AIQuotaError.unavailable }
        return responses.removeFirst()
    }
    var count: Int { requests.count }
    var last: URLRequest? { requests.last }
}
private actor FixtureSource {
    var values: [Data]; var reads = 0
    init(_ values: [Data]) { self.values = values }
    func read() -> Data { reads += 1; return values.count > 1 ? values.removeFirst() : values[0] }
}
@main struct SalaryCodenotchProviderChecks {
    static var assertions = 0
    static func check(_ value: Bool, _ label: String) { assertions += 1; precondition(value, label) }
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Accepted invalid fixture: \(label)") } catch { assertions += 1 }
    }
    static func rejectsAsync(_ label: String, _ body: () async throws -> Void) async {
        do { try await body(); fatalError("Accepted invalid fixture: \(label)") } catch { assertions += 1 }
    }
    static func data(_ text: String) -> Data { Data(text.utf8) }
    static func response(_ text: String, status: Int = 200, retry: String? = nil) -> CNHTTPResponse {
        CNHTTPResponse(status: status, retryAfter: retry, body: data(text))
    }
    static let codexAuth = data(#"{"tokens":{"access_token":"synthetic-token","account_id":"fixture-account-A"}}"#)
    static let codexQuota = #"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_at":1800003600},"secondary_window":{"used_percent":25,"limit_window_seconds":604800,"reset_at":1800604800}}}"#
    static let glmAuth = data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"synthetic-glm-key","ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic"}}"#)
    static let glmQuota = #"{"code":200,"success":true,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12.5,"nextResetTime":1800003600000},{"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":65},{"type":"TIME_LIMIT","percentage":20}]}}"#
    static let agyAuth = data(#"{"access_token":"synthetic-agy-token","expiry_date":1800010000000,"project_id":"synthetic-project"}"#)
    static let agyQuota = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"5h","remainingFraction":0.75,"resetTime":"2027-01-15T09:00:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":0.6}}]},{"displayName":"Argon Models","buckets":[{"bucketId":"weekly","remainingFraction":0.1}]}]}"#
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Scenario 1: default-denied access and revocation happen before any load/request.
        let source = FixtureSource([codexAuth]), http = FixtureHTTP([response(codexQuota)])
        let permission = CNSessionConsent()
        let denied = CNCodexLocalProvider(credentials: { await source.read() }, transport: http, authorization: permission)
        await rejectsAsync("no consent") { _ = try await denied.fetchSnapshot(sourceID: "fixture", now: now) }
        let deniedReads = await source.reads, deniedSends = await http.count
        check(deniedReads == 0 && deniedSends == 0, "default must not read or send")
        // Scenario 2: actual Codex request adaptation and true window lengths.
        let codexPermission = CNSessionConsent(approved: [.codex])
        let codex = CNCodexLocalProvider(credentials: { codexAuth }, transport: http, authorization: codexPermission)
        let c = try await codex.fetchSnapshot(sourceID: "fixture", now: now)
        check(c.windows.map(\.usedPercent) == [40,25], "Codex already used percentages")
        check(c.windows.map(\.durationMinutes) == [300,10080], "Codex actual durations")
        check(c.backendAccountID == "fixture-account-A", "backend identity kept in memory")
        let cr = await http.last!
        check(cr.httpMethod == "GET" && cr.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage", "fixed Codex request")
        check(cr.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token", "Codex Bearer")
        check(cr.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture-account-A", "Codex account header")
        codexPermission.revokeAll()
        await rejectsAsync("revoked") { _ = try await codex.fetchSnapshot(sourceID: "fixture", now: now) }
        check(await http.count == 1, "revocation prevents request")
        // Scenario 3: malformed quota containers versus legitimate empty/credit-only seats.
        for text in ["{}", #"{"rate_limit":42}"#, #"{"additional_rate_limits":false}"#] {
            rejects("Codex container") { _ = try CNCodexUsage.windows(from: data(text), now: now) }
        }
        check(try CNCodexUsage.windows(from: data(#"{"rate_limit":{}}"#), now: now).isEmpty, "valid empty seat")
        let invalid = try CNCodexUsage.windows(from: data(#"{"rate_limit":{"primary_window":{"used_percent":101,"limit_window_seconds":3600,"reset_at":1e300}}}"#), now: now)
        check(invalid.first?.usedFraction == nil && invalid.first?.resetsAt == nil, "invalid values unknown")
        for pct in [0.0,100.0,12.125] {
            let parsed = try CNCodexUsage.windows(from: data("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(pct)}}}"), now: now)
            check(parsed.first?.usedFraction == pct/100, "Codex numeric boundary")
        }
        check(try CNCodexUsage.windows(from: data(#"{"spend_control":{"individual_limit":{"used_percent":25,"limit":80,"used":20}}}"#), now: now).first?.usedFraction == 0.25, "official credit percent")
        check(try CNCodexUsage.windows(from: data(#"{"spend_control":{"individual_limit":{"limit":80,"used":20}}}"#), now: now).isEmpty, "no invented cash percent")
        rejects("header injection") { _ = try CNCodexCredentials.load(from: data(#"{"tokens":{"access_token":"bad\r\nx:1","account_id":"fixture"}}"#), now: now) }
        let jwt = "fixture." + data(#"{"exp":1}"#).base64EncodedString() + ".fixture"
        rejects("expired JWT") { _ = try CNCodexCredentials.load(from: data("{\"tokens\":{\"access_token\":\"\(jwt)\",\"account_id\":\"fixture\"}}"), now: now) }
        // Scenario 4: source switched while in flight cannot stamp an old account result.
        let changed = FixtureSource([codexAuth, data(#"{"tokens":{"access_token":"synthetic-new","account_id":"fixture-B"}}"#)])
        let switcher = CNCodexLocalProvider(credentials: { await changed.read() }, transport: FixtureHTTP([response(codexQuota)]), authorization: CNSessionConsent(approved:[.codex]))
        do { _ = try await switcher.fetchSnapshot(sourceID:"fixture",now:now); fatalError("source switch accepted") }
        catch let e as AIQuotaError { check(e == .sourceChanged,"source changed") }
        let sameAccountNewToken = data(#"{"tokens":{"access_token":"synthetic-other-token","account_id":"fixture-account-A"}}"#)
        let tokenSwitch = FixtureSource([codexAuth, sameAccountNewToken])
        let tokenSwitchHTTP = FixtureHTTP([response(codexQuota)])
        let tokenSwitchProvider = CNCodexLocalProvider(credentials:{ await tokenSwitch.read() },transport:tokenSwitchHTTP,authorization:CNSessionConsent(approved:[.codex]))
        do { _ = try await tokenSwitchProvider.fetchSnapshot(sourceID:"fixture",now:now); fatalError("same-account new token accepted in flight") }
        catch let error as AIQuotaError { check(error == .sourceChanged,"same account in-flight token switch invalidates response") }
        let laterToken = FixtureSource([codexAuth, codexAuth, sameAccountNewToken])
        let laterHTTP = FixtureHTTP([response(codexQuota)])
        let laterProvider = CNCodexLocalProvider(credentials:{ await laterToken.read() },transport:laterHTTP,authorization:CNSessionConsent(approved:[.codex]))
        _ = try await laterProvider.fetchSnapshot(sourceID:"fixture",now:now)
        do { _ = try await laterProvider.fetchSnapshot(sourceID:"fixture",now:now.addingTimeInterval(301)); fatalError("same-account new token accepted across refresh") }
        catch let error as AIQuotaError { check(error == .sourceChanged,"same account cross-refresh token switch invalidates source") }
        check(await laterHTTP.count == 1,"new token source rejected before network")
        var sourceClock = now
        let sourceStore = AIQuotaStore(now:{sourceClock})
        let sourceSequence = FixtureSource([codexAuth, codexAuth, sameAccountNewToken])
        let sourceHTTP = FixtureHTTP([response(codexQuota)])
        let sourceProvider = CNCodexLocalProvider(credentials:{ await sourceSequence.read() },transport:sourceHTTP,authorization:CNSessionConsent(approved:[.codex]))
        sourceStore.connect(.codex,accountID:"fixture") { try await sourceProvider.fetchSnapshot(sourceID:"fixture",now:sourceClock) }
        sourceStore.setSuspended(false); await sourceStore.refresh(.codex)
        check(sourceStore.state(for:.codex).snapshot != nil,"original token snapshot visible before switch")
        sourceClock = sourceClock.addingTimeInterval(301); await sourceStore.refresh(.codex)
        check(sourceStore.state(for:.codex).snapshot == nil && !sourceStore.state(for:.codex).isConnected,"same-account token switch clears snapshot and connection")
        check(sourceStore.state(for:.codex).error == .sourceChanged,"token switch is explicit source failure")
        // Scenario 5: HTTP status and provider-owned Retry-After gates.
        for status in [401,403,429,500] {
            let h = FixtureHTTP([response("{}",status:status,retry:"7200")])
            let p = CNCodexLocalProvider(credentials:{codexAuth},transport:h,authorization:CNSessionConsent(approved:[.codex]))
            do { _ = try await p.fetchSnapshot(sourceID:"fixture",now:now); fatalError("HTTP failure accepted") }
            catch let e as AIQuotaReadFailure {
                check(e.error == (status == 429 ? .rateLimited : status == 500 ? .unavailable : .unauthorized),"HTTP status mapping")
                if status == 429 {
                    check(e.retryAfter == 7200,"server delay retained")
                    await rejectsAsync("backoff") { _ = try await p.fetchSnapshot(sourceID:"fixture",now:now.addingTimeInterval(1000)) }
                    check(await h.count == 1,"no send during backoff")
                }
            }
        }
        // Scenario 6: GLM Claude Code-only extraction, exact host allowlist.
        check(CNGLMCredentials.claudeCode(glmAuth)?.source == "Claude Code","Claude source")
        for base in ["http://api.z.ai", "https://api.z.ai.evil.invalid", "https://api.anthropic.com", "https://u:p@api.z.ai", "https://api.z.ai:444"] {
            let value = data("{\"env\":{\"ANTHROPIC_AUTH_TOKEN\":\"fixture\",\"ANTHROPIC_BASE_URL\":\"\(base)\"}}")
            check(CNGLMCredentials.claudeCode(value) == nil,"GLM host rejection")
        }
        check(CNGLMCredentials.claudeCode(data(#"{"apiKey":"fixture","provider":"zcode"}"#)) == nil,"no other client")
        let gh = FixtureHTTP([response(glmQuota)])
        let glm = CNGLMProvider(credentials:{glmAuth},transport:gh,authorization:CNSessionConsent(approved:[.glm]))
        let g = try await glm.fetchSnapshot(sourceID:"fixture",now:now)
        check(g.windows.count == 3,"GLM credit token and MCP")
        check(g.windows.first?.usedPercent == 12.5 && g.windows.first?.durationMinutes == 300,"GLM shared 5h")
        check(g.windows.first?.resetsAt?.timeIntervalSince1970 == 1800003600,"milliseconds converted")
        check(g.windows.contains { $0.usedPercent == 20 && $0.resetsAt == nil },"MCP no reset retained")
        let gr = await gh.last!
        check(gr.url?.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit","fixed China target")
        check(gr.value(forHTTPHeaderField:"Authorization") == "synthetic-glm-key","raw key expected")
        for text in ["{}",#"{"code":200,"success":true,"data":{}}"#,#"{"code":500,"success":true,"data":{"limits":[]}}"#] {
            rejects("GLM envelope") { _ = try CNGLMUsage.parse(data(text)) }
        }
        do { _ = try CNGLMUsage.parse(data(#"{"code":401,"success":false,"data":"not-a-payload"}"#)); fatalError("auth envelope ignored") }
        catch let e as CNUsageProviderError { if case .needsAuth = e { check(true,"envelope precedes data") } else { fatalError("wrong failure") } }
        for pct in [-1.0, 0, 100, 100.1] {
            let w = try CNGLMUsage.parse(data("{\"code\":200,\"success\":true,\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":3,\"number\":5,\"percentage\":\(pct),\"nextResetTime\":1e300}]}}")).windows[0]
            check(w.usedFraction == ((0...100).contains(pct) ? pct/100 : nil),"GLM unknown boundary")
            check(w.resetsAt == nil,"GLM extreme reset safe")
        }
        check(CNGLMProvider.backoff(forAttempt: 99,retryAfter:7200) == 7200,"GLM hint not truncated")
        // Scenario 7: AGY credentials, source grouping and remaining conversion.
        check(CNAntigravityCredentials.decode(agyAuth)?.expiresAt?.timeIntervalSince1970 == 1800010000,"AGY ms expiry")
        check(CNAntigravityCredentials.decode(data(#"{"access_token":"fixture","expiry_date":1e300}"#)) == nil,"invalid expiry not unknown")
        let wrapped = data(#"{"auth_method":"consumer","token":{"access_token":"fixture","expiry":"2027-01-15T10:00:00Z"}}"#).base64EncodedString()
        check(CNAntigravityCredentials.decode(data("go-keyring-base64:"+wrapped))?.accessToken == "fixture","upstream base64 format")
        let ah = FixtureHTTP([response(agyQuota)])
        let agy = CNAntigravityProvider(credentials:{agyAuth},transport:ah,authorization:CNSessionConsent(approved:[.gemini]))
        let a = try await agy.fetchSnapshot(sourceID:"fixture",now:now)
        check(a.windows.count == 2 && a.windows.map(\.usedPercent) == [25,40],"exact Gemini group only")
        let ar = await ah.last!
        check(ar.value(forHTTPHeaderField:"User-Agent") == "SalaryIsland/AIQuota","own client identity")
        check(ar.value(forHTTPHeaderField:"Client-Metadata") == nil,"no impersonation metadata")
        check(ar.value(forHTTPHeaderField:"Authorization") == "Bearer synthetic-agy-token","Google bearer")
        let models = try CNAntigravityQuotaParser.parse(data(#"{"buckets":[{"modelId":"gemini-A","remainingFraction":0.9},{"modelId":"gemini-B","remainingFraction":0.3}]}"#),now:now)
        check(models.count == 2 && models[0].usedFraction != models[1].usedFraction,"model denominators not merged")
        check(models.allSatisfy { $0.duration == nil },"no reset-age inference")
        rejects("nested absent quota") { _ = try CNAntigravityQuotaParser.parse(data(#"{"response":{}}"#),now:now) }
        let forbidden = FixtureHTTP([response("{}",status:403)])
        let ap = CNAntigravityProvider(credentials:{agyAuth},transport:forbidden,authorization:CNSessionConsent(approved:[.gemini]))
        await rejectsAsync("Google denial") { _ = try await ap.fetchSnapshot(sourceID:"fixture",now:now) }
        check(await forbidden.count == 1,"403 stops without fallback identity")
        // Scenario 8: local request/discovery is pure injection; no process scan/listener.
        let endpoint = CNAntigravityBridge.discover(processTable:"123 /fixture/bin/agy",listeningPorts:{_ in [23456,23456,-1]})
        check(endpoint?.ports == [23456],"injected discovery bounded")
        check(CNAntigravityBridge.discover(processTable:"123 /fixture/fake-agy",listeningPorts:{_ in [2]}) == nil,"exact executable name")
        let local = FixtureHTTP([response(agyQuota)])
        _ = try await CNAntigravityBridge.quota(from:.init(ports:[23456],csrfToken:"synthetic-csrf"),transport:local,consent:CNSessionConsent(approved:[.gemini]),now:now)
        let lr = await local.last!
        check(lr.url?.host == "127.0.0.1" && lr.httpBody == data(#"{"forceRefresh":true}"#),"original local RPC")
        check(lr.value(forHTTPHeaderField:CNAntigravityBridge.csrfHeader) == "synthetic-csrf","CSRF limited to loopback")
        let localLimited = FixtureHTTP([response("{}",status:429,retry:"7200")])
        let localProvider = CNAntigravityProvider(localEndpoint:{.init(ports:[23456,23457],csrfToken:nil)},credentials:{agyAuth},transport:localLimited,authorization:CNSessionConsent(approved:[.gemini]))
        await rejectsAsync("local backoff") { _ = try await localProvider.fetchSnapshot(sourceID:"fixture",now:now) }
        await rejectsAsync("local backoff repeat") { _ = try await localProvider.fetchSnapshot(sourceID:"fixture",now:now.addingTimeInterval(1000)) }
        check(await localLimited.count == 1,"local 429 does not query other port or OAuth")
        // Scenario 9: URL policy and redirect rejection, no live session tasks resumed.
        for target in CNRequestPolicy.remoteURLs { check(CNRequestPolicy.permits(URL(string:target)),"allow exact target") }
        for target in ["http://chatgpt.com/backend-api/wham/usage","https://evil.invalid/usage","https://chatgpt.com/backend-api/wham/usage?q=1","https://u:p@chatgpt.com/backend-api/wham/usage","https://127.0.0.1:23456/other"] { check(!CNRequestPolicy.permits(URL(string:target)),"reject unapproved target") }
        let session = URLSession(configuration:.ephemeral)
        let task = session.dataTask(with:URL(string:"https://example.invalid")!)
        var rejected = false
        CNRejectRedirects().urlSession(session,task:task,willPerformHTTPRedirection:HTTPURLResponse(url:URL(string:"https://example.invalid")!,statusCode:302,httpVersion:nil,headerFields:nil)!,newRequest:URLRequest(url:URL(string:"https://evil.invalid")!)) { rejected = $0 == nil }
        check(rejected,"never forward credentials on redirect"); task.cancel(); session.invalidateAndCancel()
        // Scenario 10: bounded retry parsing.
        for text in ["NaN","Infinity","-1","1e300","604801","0x10","9,000","Tue, 99 Oct 2026 00:00:00 GMT"] { check(CNUsagePolicy.retryAfter(text,now:now) == nil,"invalid delay") }
        check(CNUsagePolicy.retryAfter("7200",now:now) == 7200,"valid long delay")
        check(CNUsagePolicy.retryAfter("0.5",now:now) == 0.5,"fractional delay")
        check(CNUsagePolicy.retryAfter("Fri, 15 Jan 2027 09:00:00 GMT",now:now) == 3600,"HTTP date")
        // Scenario 11: bounded explicit file access, only owned synthetic temp fixtures.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("salary-provider-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("synthetic-auth.json")
        try codexAuth.write(to:file)
        let fileConsent = CNSessionConsent()
        let reader = CNPermittedCredentialFile(kind:.codexAuth,url:file,consent:fileConsent)
        rejects("file denied") { _ = try reader.read() }
        let allowed = CNSessionConsent(approved:[.codex])
        check(try CNPermittedCredentialFile(kind:.codexAuth,url:file,consent:allowed).read() == codexAuth,"explicit fixture file")
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        rejects("symlink") { _ = try CNPermittedCredentialFile(kind:.codexAuth,url:link,consent:allowed).read() }
        allowed.revokeAll()
        rejects("file revoked") { _ = try CNPermittedCredentialFile(kind:.codexAuth,url:file,consent:allowed).read() }
        // Scenario 12: production connection wiring with fake HTTP and owned file only.
        let manager = AIQuotaConnections(), connectionHTTP = FixtureHTTP([response(codexQuota)])
        try manager.selectCodenotch(.codex,url:file)
        check(await connectionHTTP.count == 0 && manager.automatic.isEmpty,"selection never connects")
        manager.setVisible(true)
        try await manager.connectCodenotch(.codex,transport:connectionHTTP)
        check(manager.store.state(for:.codex).snapshot?.windows.first?.usedPercent == 40,"ported reader wired")
        check(manager.automatic.isEmpty,"explicit one-shot connection leaves periodic refresh OFF")
        manager.setVisible(false); manager.setVisible(true); manager.setPaused(true); manager.setPaused(false)
        check(await connectionHTTP.count == 1 && manager.automatic.isEmpty,"reopening or unpausing cannot opt into automatic refresh")
        manager.setLocked(true); await manager.refresh(.codex)
        check(await connectionHTTP.count == 1,"lock stops refresh")
        manager.disconnect(.codex)
        check(manager.store.state(for:.codex).snapshot == nil && manager.codenotchFiles.isEmpty,"disconnect drops data and source")
        let glmManager = AIQuotaConnections(), glmConnectionHTTP = FixtureHTTP([response(glmQuota)])
        do { try glmManager.selectCodenotch(.glm, url: file); fatalError("disabled GLM source accepted") }
        catch let error as AIQuotaError { check(error == .unavailable, "GLM source disabled") }
        do { try await glmManager.connectCodenotch(.glm, periodically: true, transport: glmConnectionHTTP); fatalError("disabled GLM connected") }
        catch let error as AIQuotaError { check(error == .unavailable, "GLM connection disabled") }
        await glmManager.refresh(.glm, manual: true)
        let glmRequests = await glmConnectionHTTP.count
        check(glmRequests == 0 && glmManager.visibleProviders.isEmpty && glmManager.automatic.isEmpty, "disabled GLM never queries or shows")
        let failedHTTP = FixtureHTTP([response("{}")])
        let failedManager = AIQuotaConnections(waitForRefreshCheck: { try await Task.sleep(for: .milliseconds(2)) })
        try failedManager.selectCodenotch(.codex, url: file)
        failedManager.setVisible(true)
        try await failedManager.connectCodenotch(.codex, periodically: true, transport: failedHTTP)
        try await Task.sleep(for: .milliseconds(30))
        let failedCount = await failedHTTP.count
        check(failedManager.visibleProviders.isEmpty && failedCount == 1, "hidden failed source has no automatic requests")
        failedManager.disconnect(.codex)
        check(CNUsagePolicy.hasWindowRolledOver(in:[c],since:now,at:now.addingTimeInterval(3600)),"upstream reset crossing")
        check(!CNUsagePolicy.hasWindowRolledOver(in:[c],since:now.addingTimeInterval(3600),at:now.addingTimeInterval(3601)),"reset only once")
        // Additional assertions stay within the same source/lifecycle scenarios.
        let switchingGLM = FixtureSource([glmAuth, glmAuth, data(#"{"env":{"ANTHROPIC_AUTH_TOKEN":"synthetic-other-key","ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic"}}"#)])
        let switchingHTTP = FixtureHTTP([response(glmQuota)])
        let switchingProvider = CNGLMProvider(credentials:{ await switchingGLM.read() },transport:switchingHTTP,authorization:CNSessionConsent(approved:[.glm]))
        _ = try await switchingProvider.fetchSnapshot(sourceID:"fixture",now:now)
        do { _ = try await switchingProvider.fetchSnapshot(sourceID:"fixture",now:now.addingTimeInterval(301)); fatalError("new source accepted") }
        catch let error as AIQuotaError { check(error == .sourceChanged,"between-refresh GLM source change") }
        check(await switchingHTTP.count == 1,"source change rejected before network")
        let hourly = try CNAntigravityQuotaParser.parse(data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"hourly","remainingFraction":0.5},{"bucketId":"session","remainingFraction":0.5}]}]}"#),now:now)
        check(hourly.contains(where: { $0.duration == 3600 }),"hourly is not 5h")
        check(hourly.contains(where: { $0.duration == nil }),"session duration unknown")
        let hard = directory.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at:file,to:hard)
        rejects("hardlink") { _ = try CNPermittedCredentialFile(kind:.codexAuth,url:hard,consent:CNSessionConsent(approved:[.codex])).read() }
        try FileManager.default.removeItem(at:hard)
        let fifo = directory.appendingPathComponent("fifo")
        guard mkfifo(fifo.path,0o600) == 0 else { fatalError("fixture fifo creation failed") }
        rejects("nonregular file") { _ = try CNPermittedCredentialFile(kind:.codexAuth,url:fifo,consent:CNSessionConsent(approved:[.codex])).read() }
        var clock = now
        let cached = AIQuotaStore(now:{clock})
        let cacheHTTP = FixtureHTTP([response(codexQuota),response("{}")])
        let cacheProvider = CNCodexLocalProvider(credentials:{codexAuth},transport:cacheHTTP,authorization:CNSessionConsent(approved:[.codex]))
        cached.connect(.codex,accountID:"fixture") { try await cacheProvider.fetchSnapshot(sourceID:"fixture",now:clock) }
        cached.setSuspended(false); await cached.refresh(.codex)
        let old = cached.state(for:.codex).snapshot
        clock = clock.addingTimeInterval(301); await cached.refresh(.codex)
        check(cached.state(for:.codex).snapshot == old && old != nil,"malformed port payload does not erase valid cache")
        check(cached.state(for:.codex).isStale(at:clock),"malformed refresh marks cache stale")
        // Scenario 13: stable window identity, missing IDs and shared meter periods.
        let agyNoIDs = data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Five Hour Limit","window":"5h","remainingFraction":0.7},{"displayName":"Weekly Limit","window":"weekly","remainingFraction":0.2}]}]}"#)
        let agyIdentityWindows = try CNAntigravityQuotaParser.parse(agyNoIDs,now:now)
        let agyIdentity = try CNSnapshotAdapter.snapshot(agyIdentityWindows,provider:.gemini,sourceID:"fixture",at:now)
        check(agyIdentity.windows.count == 2 && Set(agyIdentity.windows.map(\.bucketID)).count == 2,"AGY missing bucket IDs still distinct by window")
        check(agyIdentity.windows.map(\.durationMinutes) == [300,10080],"AGY dual windows preserved")
        check(abs((agyIdentity.windows[0].usedPercent ?? 0)-30) < 0.00001 && agyIdentity.windows[1].usedPercent == 80,"AGY values not merged")
        let agyReversed = data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Weekly Limit","window":"weekly","remainingFraction":0.1},{"displayName":"Five Hour Limit","window":"5h","remainingFraction":0.6}]}]}"#)
        check(Set(try CNAntigravityQuotaParser.parse(agyReversed,now:now.addingTimeInterval(60)).map(\.id)) == Set(agyIdentityWindows.map(\.id)),"AGY identities stable across order and usage changes")
        let sameBucketModels = try CNAntigravityQuotaParser.parse(data(#"{"buckets":[{"bucketId":"5h","modelId":"gemini-one","remainingFraction":0.9},{"bucketId":"5h","modelId":"gemini-two","remainingFraction":0.4}]}"#),now:now)
        check(Set(sameBucketModels.map(\.id)).count == 2,"AGY same bucket separate model IDs preserved")
        let bothMeters = try CNGLMUsage.parse(data(#"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":10},{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":70}]}}"#)).windows
        let glmIdentity = try CNSnapshotAdapter.snapshot(bothMeters,provider:.glm,sourceID:"fixture",at:now)
        check(glmIdentity.windows.count == 2 && Set(glmIdentity.windows.map(\.bucketID)).count == 2,"GLM same duration different meter has unique identity")
        check(Set(glmIdentity.windows.compactMap(\.usedPercent)) == [10,70],"GLM different denominators both preserved")
        check(Set(glmIdentity.windows.compactMap(\.bucketName)).count == 2,"GLM meter labels distinguish windows")
        let ambiguous = try CNAntigravityQuotaParser.parse(data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"remainingFraction":0.8},{"remainingFraction":0.3}]}]}"#),now:now)
        rejects("ambiguous repeated canonical ID") { _ = try CNSnapshotAdapter.snapshot(ambiguous,provider:.gemini,sourceID:"fixture",at:now) }
        rejects("duplicate GLM meter window") { _ = try CNSnapshotAdapter.snapshot([bothMeters[0],bothMeters[0]],provider:.glm,sourceID:"fixture",at:now) }
        var identityClock = now
        let identityStore = AIQuotaStore(now:{identityClock})
        var validIdentity = true
        identityStore.connect(.gemini,accountID:"fixture") {
            try CNSnapshotAdapter.snapshot(validIdentity ? agyIdentityWindows : ambiguous,provider:.gemini,sourceID:"fixture",at:identityClock)
        }
        identityStore.setSuspended(false); await identityStore.refresh(.gemini)
        let retainedIdentity = identityStore.state(for:.gemini).snapshot
        validIdentity = false; identityClock = identityClock.addingTimeInterval(301)
        await identityStore.refresh(.gemini)
        check(identityStore.state(for:.gemini).snapshot == retainedIdentity && retainedIdentity != nil,"duplicate identity cannot replace old snapshot")
        check(identityStore.state(for:.gemini).error == .malformed && identityStore.state(for:.gemini).isStale(at:identityClock),"duplicate identity flags stale cache")
        print("SalaryCodenotchProviderChecks: \(assertions) executed assertions in 13 fixture scenarios; no real credentials, network or CLI queries")
    }
}
