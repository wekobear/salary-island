import Foundation

// Data only: no provider is connected and this module does not access credentials.
// Codex fields follow the documented account/rateLimits/read response.
struct AIQuotaWindow: Equatable {
    let bucketID: String
    let bucketName: String?
    let position: String
    let usedPercent: Double?
    let durationMinutes: Int?
    let resetsAt: Date?
}

struct AIQuotaSnapshot: Equatable {
    let provider: String
    let accountID: String
    let updatedAt: Date
    let windows: [AIQuotaWindow]
    // Backend identity is optional and never displayed or persisted.
    var backendAccountID: String? = nil
}

enum AIQuotaError: Error, Equatable {
    case unauthorized
    case rateLimited
    case offline
    case unavailable
    case malformed
    case timedOut
    case outputTooLarge
    case cleanupFailed
    case sourceChanged
    case rpcRejected
}

enum CodexQuotaParser {
    private struct Response: Decodable {
        let result: ResultBody?
        let error: RPCError?
    }
    private struct RPCError: Decodable { let code: Int? }
    private struct ResultBody: Decodable {
        let accountId: String?
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }
    private struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }
    private struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?
    }

    static func parse(_ data: Data, accountID: String, updatedAt: Date) throws -> AIQuotaSnapshot {
        guard !accountID.isEmpty else { throw AIQuotaError.malformed }
        struct ErrorEnvelope: Decodable { let error: RPCError? }
        guard data.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else { throw AIQuotaError.malformed }
        if let error = envelope.error {
            switch error.code {
            // JSON-RPC codes are not HTTP statuses. -32600 can mean invalid
            // request, unsupported auth or missing login; do not infer which.
            case -32600: throw AIQuotaError.rpcRejected
            default: throw AIQuotaError.unavailable
            }
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let result = response.result else { throw AIQuotaError.malformed }
        let buckets: [(String, Bucket)]
        if let byID = result.rateLimitsByLimitId, !byID.isEmpty {
            buckets = byID.keys.sorted().compactMap { key in byID[key].map { (key, $0) } }
        } else if let legacy = result.rateLimits {
            buckets = [(legacy.limitId ?? "codex", legacy)]
        } else {
            throw AIQuotaError.malformed
        }
        var windows: [AIQuotaWindow] = []
        for (key, bucket) in buckets {
            for (position, value) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let value else { continue }
                let percent = value.usedPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
                let duration = value.windowDurationMins.flatMap { $0 > 0 ? $0 : nil }
                let reset = value.resetsAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                windows.append(AIQuotaWindow(bucketID: bucket.limitId ?? key, bucketName: bucket.limitName,
                                             position: position, usedPercent: percent,
                                             durationMinutes: duration, resetsAt: reset))
            }
        }
        return AIQuotaSnapshot(provider: "Codex", accountID: accountID, updatedAt: updatedAt, windows: windows, backendAccountID: result.accountId)
    }
}

// Inspired by a GLM 5.3-generated pure parser, reviewed and revised for optional
// reset times, invalid values, and classification before decoding payload data.
struct GLMCodingPlanWindow: Equatable {
    let type: String
    let unitCode: Int?
    let number: Int?
    let usedPercent: Double?
    let resetsAt: Date?
}

struct GLMCodingPlanSnapshot: Equatable {
    let accountID: String
    let updatedAt: Date
    let windows: [GLMCodingPlanWindow]
}

enum GLMCodingPlanParser {
    private struct Envelope: Decodable {
        let code: Int?
        let success: Bool?
    }
    private struct Payload: Decodable {
        struct Body: Decodable { let limits: [Limit]? }
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let percentage: Double?
            let nextResetTime: Double?
        }
        let data: Body?
    }

    static func parse(_ data: Data, accountID: String, updatedAt: Date) throws -> GLMCodingPlanSnapshot {
        guard !accountID.isEmpty, data.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw AIQuotaError.malformed
        }
        switch envelope.code {
        case 401, 403: throw AIQuotaError.unauthorized
        case 429: throw AIQuotaError.rateLimited
        default: break
        }
        guard envelope.code == 200, envelope.success == true else { throw AIQuotaError.unavailable }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let limits = payload.data?.limits else { throw AIQuotaError.malformed }
        let windows = limits.map { limit in
            let percent = limit.percentage.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            let reset = limit.nextResetTime.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
            return GLMCodingPlanWindow(type: limit.type ?? "未知额度", unitCode: limit.unit,
                                       number: limit.number, usedPercent: percent, resetsAt: reset)
        }
        return GLMCodingPlanSnapshot(accountID: accountID, updatedAt: updatedAt, windows: windows)
    }
}

struct AGYQuotaWindow: Equatable {
    let bucketID: String
    let remainingFraction: Double?
    let remainingAmount: Double?
    let resetsAt: Date?
    let disabled: Bool
    var usedPercent: Double? { remainingFraction.map { (1 - $0) * 100 } }
}

/// Decodes only the official statusline quota whitelist; email, conversation,
/// transcript and workspace fields are not represented, retained, or logged.
/// This is not a statusline installer and never reads a local CLI session.
enum AGYQuotaParser {
    private struct Payload: Decodable {
        let quota: [String: Bucket]?
    }
    private struct Bucket: Decodable {
        let remaining_fraction: Double?
        let remaining_amount: Double?
        let reset_time: String?
        let reset_in_seconds: Double?
        let disabled: Bool?
    }
    static func parse(_ data: Data, updatedAt: Date) throws -> [AGYQuotaWindow] {
        guard data.count <= 1_048_576,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let buckets = payload.quota else { throw AIQuotaError.malformed }
        let iso = ISO8601DateFormatter()
        let fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return buckets.keys.sorted().compactMap { key in
            guard let value = buckets[key] else { return nil }
            let fraction = value.remaining_fraction.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
            let amount = value.remaining_amount.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let absolute = value.reset_time.flatMap { fractionalISO.date(from: $0) ?? iso.date(from: $0) }
            let relative = value.reset_in_seconds.flatMap { $0.isFinite && $0 >= 0 ? updatedAt.addingTimeInterval($0) : nil }
            return AGYQuotaWindow(bucketID: key, remainingFraction: fraction, remainingAmount: amount,
                                  resetsAt: absolute ?? relative, disabled: value.disabled ?? false)
        }
    }
    /// Exact user/source-confirmed IDs only. Never combine Gemini, Argon and
    /// Claude/GPT quota groups or infer membership from the selected model name.
    static func selected(_ windows: [AGYQuotaWindow], bucketIDs: Set<String>) -> [AGYQuotaWindow] {
        windows.filter { bucketIDs.contains($0.bucketID) }
    }
}

extension GLMCodingPlanWindow {
    var durationMinutes: Int? {
        guard let number, number > 0 else { return nil }
        let factor: Int
        switch unitCode {
        case 3: factor = 60
        case 6: factor = 10080
        default: return nil
        }
        let (value, overflow) = number.multipliedReportingOverflow(by: factor)
        return overflow ? nil : value
    }
}

/// Display rounding never mutates the stored usage value. Dates are absolute;
/// reaching reset time marks the previous reading stale, never fabricates 0%.
enum AIQuotaPresentation {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "已用 —" }
        return "已用 \(Int(value.rounded(.toNearestOrAwayFromZero)))%"
    }
    static func reset(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return "重置时间未知" }
        guard date > now else { return "已到重置时间 · 待刷新" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d HH:mm"
        return "重置 " + formatter.string(from: date)
    }
}
