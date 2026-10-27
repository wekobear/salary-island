// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Minimal adaptation of Sources/Model/UsageModel.swift and UsageProvider.swift,
// codenotch commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
import Foundation
import CryptoKit

struct CNLimitWindow: Equatable {
    let id: String
    let group: String?
    let label: String
    let usedFraction: Double?
    let resetsAt: Date?
    let duration: TimeInterval?
    init(id: String, group: String? = nil, label: String, usedFraction: Double? = nil,
         resetsAt: Date? = nil, duration: TimeInterval? = nil) {
        self.id = id; self.group = group; self.label = label; self.usedFraction = usedFraction
        self.resetsAt = resetsAt; self.duration = duration
    }
}
enum CNUsageProviderError: Error {
    case needsAuth, credentialExpired, badResponse(status: Int), rateLimited(retryAfter: TimeInterval), nothingMetered(String)
    var appError: AIQuotaReadFailure {
        switch self {
        case .needsAuth, .credentialExpired: return .init(.unauthorized)
        case .rateLimited(let value): return .init(.rateLimited, retryAfter: value)
        case .nothingMetered: return .init(.unavailable)
        case .badResponse: return .init(.unavailable)
        }
    }
}
enum CNL10n { static func t(_ value: String) -> String { value } }
enum CNHeaderValue {
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16384 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}
enum CNSnapshotAdapter {
    static func snapshot(_ windows: [CNLimitWindow], provider: AIQuotaProvider, sourceID: String,
                         accountID: String? = nil, at now: Date) throws -> AIQuotaSnapshot {
        guard windows.count <= 128, windows.allSatisfy({ $0.id.utf8.count <= 256 && $0.label.utf8.count <= 256 && ($0.group?.utf8.count ?? 0) <= 256 }) else { throw AIQuotaError.outputTooLarge }
        guard windows.allSatisfy({ !$0.id.isEmpty }), Set(windows.map(\.id)).count == windows.count else {
            throw AIQuotaError.malformed // Ambiguous identities must not replace a valid cached snapshot.
        }
        let mapped = windows.map { value in
            AIQuotaWindow(bucketID: value.id, bucketName: value.group ?? value.label, position: value.id,
                usedPercent: value.usedFraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 * 100 : nil },
                durationMinutes: value.duration.flatMap { $0.isFinite && $0 >= 60 && $0 <= 315_576_000 ? Int($0 / 60) : nil },
                resetsAt: value.resetsAt.flatMap(AIQuotaTimestamp.validated))
        }
        return AIQuotaSnapshot(provider: provider.title, accountID: sourceID, updatedAt: now, windows: mapped, backendAccountID: accountID)
    }
}

// Source continuity only, not a claim of verified account identity. Memory-only.
enum CNSourceFingerprint {
    static func digest(_ parts: [String]) -> String {
        let bytes = parts.reduce(into: Data()) { data, part in
            data.append(contentsOf: String(part.utf8.count).utf8); data.append(0)
            data.append(contentsOf: part.utf8)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
