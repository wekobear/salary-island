// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted from AntigravityProvider.fetchSnapshot/quota/windows, commit
// 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. Preserves local-first quota queries,
// then an explicitly authorized OAuth source. No client impersonation, token
// refresh/write, activity-count fallback or cross-source account aggregation.
import Foundation

actor CNAntigravityProvider {
    private let localEndpoint: (() async throws -> CNAntigravityBridge.Endpoint?)?
    private let credentials: (() async throws -> Data)?
    private let transport: any CNHTTPTransport
    private let authorization: CNSessionConsent
    private let group: String
    private var sourceFingerprint: String?
    private var retryNoEarlierThan: Date?
    init(localEndpoint: (() async throws -> CNAntigravityBridge.Endpoint?)? = nil,
         credentials: (() async throws -> Data)? = nil, group: String = "Gemini Models",
         transport: any CNHTTPTransport, authorization: CNSessionConsent) {
        self.localEndpoint = localEndpoint; self.credentials = credentials; self.group = group
        self.transport = transport; self.authorization = authorization
    }
    func fetchSnapshot(sourceID: String, now: Date = Date()) async throws -> AIQuotaSnapshot {
        try authorization.require(.gemini)
        guard ["Gemini Models", "Argon Models"].contains(group) else { throw AIQuotaError.malformed }
        if let deadline = retryNoEarlierThan, deadline > now { throw AIQuotaReadFailure(.rateLimited, retryAfter: deadline.timeIntervalSince(now)) }
        var localFailure: Error?
        if let localEndpoint, let endpoint = try await localEndpoint() {
            do {
                let windows = try await CNAntigravityBridge.quota(from: endpoint, transport: transport, consent: authorization, now: now)
                let chosen = windows.filter { $0.group == group }
                if !chosen.isEmpty { return try CNSnapshotAdapter.snapshot(chosen, provider: .gemini, sourceID: sourceID, at: now) }
            } catch is CancellationError { throw CancellationError() }
            catch let failure as AIQuotaReadFailure {
                if failure.error == .rateLimited {
                    retryNoEarlierThan = now.addingTimeInterval(max(300, failure.retryAfter ?? 0))
                    throw failure
                }
                localFailure = failure
            }
            catch { localFailure = error }
        }
        if credentials == nil, let localFailure { throw localFailure }
        guard let credentials, let credential = CNAntigravityCredentials.decode(try await credentials()),
              credential.expiresAt.map({ $0 > now }) ?? true else { throw AIQuotaError.unauthorized }
            let fingerprint = CNSourceFingerprint.digest([credential.accessToken, credential.projectId ?? ""])
            if let previous = sourceFingerprint, previous != fingerprint { throw AIQuotaError.sourceChanged }
            sourceFingerprint = fingerprint
        try Task.checkCancellation(); try authorization.require(.gemini)
        let endpoints = ["https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                         "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"]
        for address in endpoints {
            var request = URLRequest(url: URL(string: address)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "POST"
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("SalaryIsland/AIQuota", forHTTPHeaderField: "User-Agent")
            let body: [String: String] = credential.projectId.flatMap { !$0.isEmpty && $0.utf8.count <= 1024 ? ["project": $0] : nil } ?? [:]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let response = try await transport.send(request)
            try Task.checkCancellation(); try authorization.require(.gemini)
            // Do not try another client identity to bypass a product/license denial.
            if response.status == 401 || response.status == 403 { throw AIQuotaError.unauthorized }
            if response.status == 429 {
                let wait = max(300, CNUsagePolicy.retryAfter(response.retryAfter, now: now) ?? 0)
                retryNoEarlierThan = now.addingTimeInterval(wait); throw AIQuotaReadFailure(.rateLimited, retryAfter: wait)
            }
            guard response.status == 200 else { continue }
            let windows = try CNAntigravityQuotaParser.parse(response.body, now: now).filter { $0.group == group }
            guard let current = CNAntigravityCredentials.decode(try await credentials()), current.accessToken == credential.accessToken,
                  current.projectId == credential.projectId else { throw AIQuotaError.sourceChanged }
            if !windows.isEmpty { return try CNSnapshotAdapter.snapshot(windows, provider: .gemini, sourceID: sourceID, at: now) }
        }
        throw AIQuotaError.unavailable
    }
}
