// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted for Salary Island, 2026-10-27. Upstream: vinzdg/codenotch
// commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. See PORTING.md.
import Foundation

/// Normalizes the quota envelopes shared by Antigravity's local language server
/// and Cloud Code. Keeping this outside either transport prevents source-specific
/// window IDs, cadence inference, or ordering from leaking into the UI.
enum CNAntigravityQuotaParser {
    private struct Remaining: Decodable {
        let fraction: Double?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction
            case oneofCase = "case"
            case value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let fraction = try container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                self.fraction = fraction
            } else if try container.decodeIfPresent(String.self, forKey: .oneofCase) == "remainingFraction" {
                self.fraction = try container.decodeIfPresent(Double.self, forKey: .value)
            } else {
                self.fraction = nil
            }
        }
    }

    private struct Bucket: Decodable {
        let modelId: String?
        let bucketId: String?
        let name: String?
        let displayName: String?
        let remainingFraction: Double?
        let remaining: Remaining?
        let used: Double?
        let limit: Double?
        let resetTime: String?
        let window: String?
        let disabled: Bool?

        var fraction: Double? { self.remainingFraction ?? self.remaining?.fraction }
    }

    private struct Group: Decodable {
        let displayName: String?
        let buckets: [Bucket]?
    }

    private struct GroupBody: Decodable {
        let groups: [Group]?
    }

    private struct Response: Decodable {
        let buckets: [Bucket]?
        let groups: [Group]?
        let quotaGroups: [Group]?
        let response: GroupBody?
        let summary: GroupBody?
    }

    static func parse(_ data: Data, now: Date) throws -> [CNLimitWindow] {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["buckets", "groups", "quotaGroups", "response", "summary"].contains(where: { root.keys.contains($0) }),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { throw AIQuotaError.malformed }
        guard response.buckets != nil || response.groups != nil || response.quotaGroups != nil || response.response?.groups != nil || response.summary?.groups != nil else { throw AIQuotaError.malformed }
        let groups = response.response?.groups
            ?? response.summary?.groups
            ?? response.groups
            ?? response.quotaGroups
            ?? []
        if !groups.isEmpty { return self.groupedWindows(groups) }
        guard let buckets = response.buckets, !buckets.isEmpty else { return [] }
        if buckets.contains(where: { $0.limit != nil }) {
            return self.legacyWindows(buckets)
        }
        return self.modelWindows(buckets, now: now)
    }

    private static func groupedWindows(_ groups: [Group]) -> [CNLimitWindow] {
        let sortedGroups = groups.enumerated().sorted { lhs, rhs in
            let lhsRank = self.groupRank(lhs.element.displayName)
            let rhsRank = self.groupRank(rhs.element.displayName)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        var windows: [CNLimitWindow] = []
        for indexedGroup in sortedGroups {
            windows.append(contentsOf: self.bucketWindows(in: indexedGroup.element))
        }
        return windows
    }

    private static func bucketWindows(in group: Group) -> [CNLimitWindow] {
        let sortedBuckets = (group.buckets ?? []).enumerated().sorted { lhs, rhs in
            let lhsRank = self.cadence(lhs.element)
            let rhsRank = self.cadence(rhs.element)
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        return sortedBuckets.compactMap { indexedBucket in
            let bucket = indexedBucket.element
            guard bucket.disabled != true else { return nil }
            let groupName = group.displayName
            let rawID = self.id(for: bucket, group: groupName)
            let reset = bucket.resetTime.flatMap(CNAntigravityCredentials.parse)
            if let remaining = bucket.fraction, (0...1).contains(remaining) {
                return CNLimitWindow(
                    id: rawID,
                    group: self.groupName(groupName),
                    label: self.label(for: bucket, fallback: "Usage"),
                    usedFraction: 1 - remaining,
                    resetsAt: reset,
                    duration: self.duration(for: bucket))
            }
            guard let limit = bucket.limit, limit.isFinite, limit > 0,
                  let used = bucket.used, used.isFinite, used >= 0, used <= limit
            else { return nil }
            return CNLimitWindow(
                id: rawID,
                group: self.groupName(groupName),
                label: self.label(for: bucket, fallback: "Usage"),
                usedFraction: used / limit,
                resetsAt: reset,
                duration: self.duration(for: bucket))
        }
    }

    private static func legacyWindows(_ buckets: [Bucket]) -> [CNLimitWindow] {
        buckets.compactMap { bucket in
            guard let limit = bucket.limit, limit.isFinite, limit > 0,
                  let used = bucket.used, used.isFinite, used >= 0, used <= limit
            else { return nil }
            let rawID = self.id(for: bucket, group: nil)
            return CNLimitWindow(
                id: rawID,
                label: self.label(for: bucket, fallback: "Usage"),
                usedFraction: used / limit,
                resetsAt: bucket.resetTime.flatMap(CNAntigravityCredentials.parse),
                duration: self.duration(for: bucket))
        }
    }

    // Salary adaptation: preserve every model bucket. Never take a minimum
    // across different model denominators or infer a weekly window from reset age.
    private static func modelWindows(_ buckets: [Bucket], now: Date) -> [CNLimitWindow] {
        buckets.compactMap { bucket in
            guard bucket.disabled != true else { return nil }
            let id = self.id(for: bucket, group: nil)
            let model = bucket.modelId ?? bucket.name ?? bucket.bucketId ?? ""
            let group = normalized(model).contains("gemini") ? "Gemini Models" : nil
            return CNLimitWindow(id: id, group: group, label: bucket.displayName ?? bucket.modelId ?? "Usage",
                usedFraction: bucket.fraction.flatMap { $0.isFinite && (0...1).contains($0) ? 1 - $0 : nil },
                resetsAt: bucket.resetTime.flatMap(CNAntigravityCredentials.parse), duration: duration(for: bucket))
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func groupRank(_ value: String?) -> Int {
        let normalized = self.normalized(value ?? "")
        if normalized.contains("gemini") { return 0 }
        if normalized.contains("claude") || normalized.contains("gpt") { return 1 }
        return 2
    }

    private static func cadence(_ bucket: Bucket) -> Int {
        if let value = self.cadenceValue(bucket.window), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.bucketId), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.displayName), self.isWeeklyValue(value) { return 1 }
        if let value = self.cadenceValue(bucket.window), self.isSessionValue(value) { return 0 }
        if let value = self.cadenceValue(bucket.bucketId), self.isSessionValue(value) { return 0 }
        if let value = self.cadenceValue(bucket.displayName), self.isSessionValue(value) { return 0 }
        return 2
    }

    private static func cadenceValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = self.normalized(raw)
        guard !value.isEmpty else { return nil }
        return value.hasSuffix(" limit") ? String(value.dropLast(" limit".count)) : value
    }

    private static func isWeeklyValue(_ value: String) -> Bool {
        value == "weekly" || value.hasSuffix("-weekly") || value.hasSuffix(" weekly")
    }

    private static func isSessionValue(_ value: String) -> Bool {
        value == "session" || value == "5h" || value == "5-hour" ||
            value == "five hour" || value == "five-hour" || value == "hourly" ||
            value.hasSuffix("-session") || value.hasSuffix("-5h") ||
            value.hasSuffix("-5-hour") || value.hasSuffix("-five-hour") ||
            value.hasSuffix("-hourly")
    }

    private static func duration(for bucket: Bucket) -> TimeInterval? {
        let names = [bucket.window, bucket.bucketId, bucket.displayName].compactMap { $0 }.compactMap(cadenceValue)
        if names.contains(where: isWeeklyValue) { return 7 * 86400 }
        if names.contains(where: { ["5h", "5-hour", "five hour", "five-hour"].contains($0) || $0.hasSuffix("-5h") || $0.hasSuffix("-5-hour") || $0.hasSuffix("-five-hour") }) { return 5 * 3600 }
        if names.contains("hourly") { return 3600 }
        return nil // A generic session label does not define a duration.
    }

    /// The server names its windows in English whatever the app's language,
    /// so the ones it is known to send are looked up in the catalog. Any other
    /// name is shown as the server spelled it.
    private static func label(for bucket: Bucket, fallback: String) -> String {
        var value = bucket.displayName ?? fallback
        if value.hasSuffix(" Remaining") {
            value = String(value.dropLast(" Remaining".count))
        }
        switch value {
        case "Five Hour Limit", "5-hour Limit": return CNL10n.t("5-hour Limit")
        case "Weekly Limit": return CNL10n.t("Weekly Limit")
        default: return value
        }
    }

    /// The same for the groups the windows sit under.
    private static func groupName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        switch name {
        case "Gemini Models": return CNL10n.t("Gemini Models")
        case "Claude and GPT models": return CNL10n.t("Claude and GPT models")
        default: return name
        }
    }

    private static func id(for bucket: Bucket, group: String?) -> String {
        func clean(_ value: String?) -> String? {
            value.flatMap { text in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        // Include the group and stable bucket/model metadata. When server IDs
        // are absent, explicit window/display metadata distinguishes 5h/week.
        // Never use list position, remaining value or reset time as identity.
        let window = clean(bucket.window).flatMap(cadenceValue)
            ?? clean(bucket.displayName).flatMap(cadenceValue) ?? ""
        return "agy:" + CNSourceFingerprint.digest([clean(group) ?? "", clean(bucket.bucketId) ?? "",
                                                   clean(bucket.modelId) ?? "", clean(bucket.name) ?? "", window])
    }
}
