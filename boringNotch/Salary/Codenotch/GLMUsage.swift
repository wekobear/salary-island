// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted for Salary Island, 2026-10-27. Upstream: vinzdg/codenotch
// commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. See PORTING.md.
import Foundation

/// Parses the answer from Z.ai's own usage monitor,
/// `GET /api/monitor/usage/quota/limit`.
///
/// The Coding Plan does not meter tokens the way Anthropic meters prompts — it
/// reports three separate allowances in one response, and the window each
/// token limit belongs to is encoded rather than named:
///
/// ```json
/// { "code": 200, "success": true,
///   "data": { "level": "pro",
///     "limits": [
///       { "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
///         "percentage": 12.5, "currentValue": 1250000, "usage": 12000000,
///         "nextResetTime": 1788682200000 },
///       { "type": "TOKENS_LIMIT", "unit": 6, "number": 1,
///         "percentage": 8.1, "nextResetTime": 1789190400000 },
///       { "type": "TIME_LIMIT", "percentage": 4.0,
///         "currentValue": 40, "usage": 1000 } ] } }
/// ```
///
/// `unit`/`number` pair up as (hours, 5) for the rolling session and
/// (weeks, 1) for the weekly allowance; `TIME_LIMIT` is the monthly MCP call
/// budget. What is being metered inside a window varies by plan — token plans
/// answer `TOKENS_LIMIT`, credit plans `CREDIT_LIMIT` — and both pair the
/// window length with the same `unit`/`number`, so it is the length the
/// identity is built from, not the meter. The shape is pinned by tests,
/// including upstream credit-plan fixtures: the endpoint is not
/// a published API, and this is the first place a change would show.
///
/// Two things about this endpoint differ from the others here, and both are
/// load-bearing. Errors ride in under an HTTP 200 — `{ "code": 401, "success":
/// false }` is what an expired token looks like on the wire — so the envelope
/// is read before the payload is trusted. And the MCP row never carries a
/// reset time, so unlike Claude's windows a row is not dropped for lacking
/// one; a percentage with no countdown is still a reading.
enum CNGLMUsage {
    struct Payload {
        /// The plan's own name for itself, lowercase — "pro", "max". Nil when
        /// the response declines to say.
        let level: String?
        let windows: [CNLimitWindow]
    }

    /// The envelope plus payload shape.
    struct Response: Decodable {
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let percentage: Double?
            let currentValue: Double?
            let usage: Double?
            let total: Double?
            /// Milliseconds since the epoch, not seconds — the one unit this
            /// API shares with JavaScript rather than with Unix.
            let nextResetTime: Double?
        }
        struct Data: Decodable {
            let level: String?
            let limits: [Limit]?
        }

        let code: Int?
        let success: Bool?
        let msg: String?
        let data: Data?
    }

    static func parse(_ data: Data) throws -> Payload {
        guard data.count <= 1_048_576 else { throw AIQuotaError.malformed }
        struct Envelope: Decodable { let code: Int?; let success: Bool? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        if envelope.code == 401 || envelope.code == 403 { throw CNUsageProviderError.needsAuth }
        if envelope.code == 429 { throw CNUsageProviderError.rateLimited(retryAfter: 0) }
        guard envelope.code == 200, envelope.success == true else { throw AIQuotaError.unavailable }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.data?.limits != nil else { throw AIQuotaError.malformed }
        return Payload(level: response.data?.level,
                       windows: windows(in: response.data?.limits ?? []))
    }

    /// Turns the limits array into limit windows, session first.
    static func windows(in limits: [Response.Limit]) -> [CNLimitWindow] {
        limits.compactMap { window(for: $0) }.sorted(by: Self.displayOrder)
    }

    private static func window(for limit: Response.Limit) -> CNLimitWindow? {
        guard let kind = limit.type, ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(kind) else { return nil }
        // Missing or invalid percentages remain unknown, never zero.
        let percentage = limit.percentage.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }

        return CNLimitWindow(
            id: Self.id(for: limit),
            label: Self.meterLabel(for: limit),
            usedFraction: percentage.map { $0 / 100 },
            resetsAt: limit.nextResetTime.flatMap(AIQuotaTimestamp.milliseconds),
            duration: limit.number.flatMap { number in
                guard number > 0 else { return nil }
                switch limit.unit {
                case 3: return Double(number) * 3600
                case 6: return Double(number) * 7 * 86400
                default: return nil
                }
            }
        )
    }

    /// Meter type is part of identity: TOKEN and CREDIT windows must never merge.
    static func id(for limit: Response.Limit) -> String {
        (limit.type?.lowercased() ?? "unknown") + ":" + cadenceID(for: limit)
    }
    private static func cadenceID(for limit: Response.Limit) -> String {
        switch limit.type {
        case "TIME_LIMIT":
            return "mcp"
        default:
            switch (limit.unit, limit.number) {
            case (3?, 5?):    return "session"
            case (6?, 1?):    return "weekly"
            case (.some(let unit), .some(let number)):
                return "window-\(unit)x\(number)"
            default:
                return limit.type?.lowercased() ?? "unknown"
            }
        }
    }

    private static func meterLabel(for limit: Response.Limit) -> String {
        let cadence = label(for: limit)
        switch limit.type {
        case "CREDIT_LIMIT": return "Credits · " + cadence
        case "TOKENS_LIMIT": return "Tokens · " + cadence
        default: return cadence
        }
    }

    /// The frame's wording, for the windows it knows.
    static func label(for limit: Response.Limit) -> String {
        switch cadenceID(for: limit) {
        case "session": return CNL10n.t("Current session")
        case "weekly":  return CNL10n.t("Weekly")
        case "mcp":     return CNL10n.t("MCP (1 month)")
        case let id     where id.hasPrefix("window-"):
            switch (limit.unit, limit.number) {
            case (3?, .some(let number)): return CNL10n.t("Usage (\(number) h)")
            case (6?, .some(let number)): return CNL10n.t("Usage (\(number) wk)")
            default:                      return CNL10n.t("Usage")
            }
        default:        return CNL10n.t("Usage")
        }
    }

    /// Session first, then weekly, then MCP — the order the plan's own panel
    /// leads with.
    private static func displayOrder(_ a: CNLimitWindow, _ b: CNLimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            switch id.split(separator: ":").last.map(String.init) ?? id {
            case "session": return 0
            case "weekly":  return 1
            case "mcp":     return 2
            default:        return 3
            }
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }
}
