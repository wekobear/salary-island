// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted from GLMProvider at commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Only Claude Code's explicitly permitted settings source is accepted.
import Foundation

actor CNGLMProvider {
    private let credentials: () async throws -> Data
    private let transport: any CNHTTPTransport
    private let authorization: CNSessionConsent
    private var sourceFingerprint: String?
    private var retryNoEarlierThan: Date?
    private var consecutiveRateLimits = 0
    init(credentials: @escaping () async throws -> Data, transport: any CNHTTPTransport,
         authorization: CNSessionConsent) {
        self.credentials = credentials; self.transport = transport; self.authorization = authorization
    }
    func fetchSnapshot(sourceID: String, now: Date = Date()) async throws -> AIQuotaSnapshot {
        try authorization.require(.glm)
        if let deadline = retryNoEarlierThan, deadline > now { throw AIQuotaReadFailure(.rateLimited, retryAfter: deadline.timeIntervalSince(now)) }
        do {
            guard let credential = CNGLMCredentials.claudeCode(try await credentials()) else { throw CNUsageProviderError.needsAuth }
            let fingerprint = CNSourceFingerprint.digest([credential.token, credential.baseURL.absoluteString])
            if let previous = sourceFingerprint, previous != fingerprint { throw AIQuotaError.sourceChanged }
            sourceFingerprint = fingerprint
            try Task.checkCancellation(); try authorization.require(.glm)
            let url = credential.baseURL.appendingPathComponent("api/monitor/usage/quota/limit")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue(credential.token, forHTTPHeaderField: "Authorization") // Original monitor expects the raw key.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let response = try await transport.send(request)
            try Task.checkCancellation(); try authorization.require(.glm)
            if response.status == 401 || response.status == 403 { throw CNUsageProviderError.needsAuth }
            if response.status == 429 {
                let delay = Self.backoff(forAttempt: consecutiveRateLimits, retryAfter: CNUsagePolicy.retryAfter(response.retryAfter, now: now))
                consecutiveRateLimits = min(consecutiveRateLimits + 1, 8)
                retryNoEarlierThan = now.addingTimeInterval(delay)
                throw AIQuotaReadFailure(.rateLimited, retryAfter: delay)
            }
            guard (200..<300).contains(response.status) else { throw CNUsageProviderError.badResponse(status: response.status) }
            guard let current = CNGLMCredentials.claudeCode(try await credentials()), current.token == credential.token,
                  current.baseURL == credential.baseURL else { throw AIQuotaError.sourceChanged }
            let payload = try CNGLMUsage.parse(response.body)
            consecutiveRateLimits = 0; retryNoEarlierThan = nil
            return try CNSnapshotAdapter.snapshot(payload.windows, provider: .glm, sourceID: sourceID, at: now)
        } catch let error as CNUsageProviderError {
            if case .rateLimited(let hint) = error {
                let delay = Self.backoff(forAttempt: consecutiveRateLimits, retryAfter: hint)
                consecutiveRateLimits = min(consecutiveRateLimits + 1, 8); retryNoEarlierThan = now.addingTimeInterval(delay)
                throw AIQuotaReadFailure(.rateLimited, retryAfter: delay)
            }
            throw error.appError
        }
    }
    static func backoff(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let doubled = 60 * pow(2, Double(min(max(attempt, 0), 4)))
        let validHint = retryAfter.flatMap { $0.isFinite && (0...604800).contains($0) ? $0 : nil } ?? 0
        // Adaptation: do not truncate a valid Retry-After to the 15-minute cap.
        return max(min(15 * 60, doubled), validHint)
    }
}
