// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted from CodexLocalProvider.fetchSnapshot/retryAfter at commit
// 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. Quota endpoint only; no profiles,
// reset-credit actions, SQLite catalogues, transcripts or session files.
import Foundation

actor CNCodexLocalProvider {
    private let credentials: () async throws -> Data
    private let transport: any CNHTTPTransport
    private let authorization: CNSessionConsent
    private var sourceFingerprint: String?
    private var retryNoEarlierThan: Date?
    init(credentials: @escaping () async throws -> Data, transport: any CNHTTPTransport,
         authorization: CNSessionConsent) {
        self.credentials = credentials; self.transport = transport; self.authorization = authorization
    }
    func fetchSnapshot(sourceID: String, now: Date = Date()) async throws -> AIQuotaSnapshot {
        try authorization.require(.codex)
        if let deadline = retryNoEarlierThan, deadline > now { throw AIQuotaReadFailure(.rateLimited, retryAfter: deadline.timeIntervalSince(now)) }
        do {
            // Re-read the original client-owned file on each fetch; never refresh/write its token.
            let credential = try CNCodexCredentials.load(from: await credentials(), now: now)
            let fingerprint = CNSourceFingerprint.digest([credential.accountID, credential.accessToken])
            if let previous = sourceFingerprint, previous != fingerprint { throw AIQuotaError.sourceChanged }
            sourceFingerprint = fingerprint
            try Task.checkCancellation(); try authorization.require(.codex)
            var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.httpMethod = "GET"
            request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
            let response = try await transport.send(request)
            try Task.checkCancellation(); try authorization.require(.codex)
            if response.status == 401 || response.status == 403 { throw CNUsageProviderError.needsAuth }
            if response.status == 429 {
                let delay = max(60, CNUsagePolicy.retryAfter(response.retryAfter, now: now) ?? 0)
                retryNoEarlierThan = now.addingTimeInterval(delay)
                throw AIQuotaReadFailure(.rateLimited, retryAfter: delay)
            }
            guard (200..<300).contains(response.status) else { throw CNUsageProviderError.badResponse(status: response.status) }
            let current = try CNCodexCredentials.load(from: await credentials(), now: now)
            guard CNSourceFingerprint.digest([current.accountID, current.accessToken]) == fingerprint else { throw AIQuotaError.sourceChanged }
            let windows = try CNCodexUsage.windows(from: response.body, now: now, includeExtras: true)
            retryNoEarlierThan = nil
            return try CNSnapshotAdapter.snapshot(windows, provider: .codex, sourceID: sourceID, accountID: credential.accountID, at: now)
        } catch let error as CNUsageProviderError { throw error.appError }
    }
}
