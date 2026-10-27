import Foundation

/// Reads the CLI's own /usage report, never a prompt response/context-token count.
/// Group labels remain exact and separate; only the explicitly chosen group is shown.
struct AGYUsageClient {
    let executableURL: URL
    let group: String
    var policy = QuotaProcessPolicy(stdoutLimit: 65_536)
    func read(sourceID: String) async throws -> AIQuotaSnapshot {
        guard executableURL.isFileURL, executableURL.lastPathComponent == "agy", ["Gemini Models", "Argon Models"].contains(group) else { throw AIQuotaError.unavailable }
        let data = try await QuotaCLIProcess.run(executableURL: executableURL, command: .agy, policy: policy)
        return try AGYUsageTextParser.parse(data, group: group, sourceID: sourceID, updatedAt: Date())
    }
}

enum AGYUsageTextParser {
    static func parse(_ data: Data, group: String, sourceID: String, updatedAt: Date,
                      timeZone: TimeZone = .current) throws -> AIQuotaSnapshot {
        guard data.count <= 65_536, !sourceID.isEmpty, !group.isEmpty, group.count <= 80,
              let raw = String(data: data, encoding: .utf8) else { throw AIQuotaError.malformed }
        // Only SGR colour escapes are allowed; cursor movement/OSC are rejected.
        let text = raw.replacingOccurrences(of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.contains("\u{1b}"), !text.contains("\u{0}") else { throw AIQuotaError.malformed }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let header = lines.firstIndex(of: "Quota:") else { throw AIQuotaError.malformed }
        let expression = try NSRegularExpression(pattern: #"^(.+?) (.+?) Limit Remaining ([0-9]+(?:\.[0-9]+)?)% (.+)$"#)
        var windows: [AIQuotaWindow] = []
        var ids = Set<String>()
        for line in lines.dropFirst(header + 1) {
            guard line.contains("Limit Remaining") else { continue }
            // Match the exact requested family before deriving a window. Other
            // families are not aggregated or used as a fallback for this card.
            guard line.hasPrefix(group + " ") else { continue }
            let suffix = String(line.dropFirst(group.count + 1))
            let components = suffix.components(separatedBy: " Limit Remaining ")
            guard components.count == 2, !components[0].isEmpty,
                  let percentEnd = components[1].firstIndex(of: "%") else { throw AIQuotaError.malformed }
            let number = String(components[1][..<percentEnd])
            guard number.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let remaining = Double(number), remaining.isFinite, (0...100).contains(remaining),
                  expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { throw AIQuotaError.malformed }
            let resetText = String(components[1][components[1].index(after: percentEnd)...]).trimmingCharacters(in: .whitespaces)
            let reset = try QuotaResetDateParser.parse(resetText, timeZone: timeZone)
            let lane = components[0]
            guard ids.insert(lane).inserted else { throw AIQuotaError.malformed }
            let duration: Int? = lane == "Five Hour" ? 300 : (lane == "Weekly" ? 10080 : nil)
            windows.append(AIQuotaWindow(bucketID: group, bucketName: group, position: lane,
                usedPercent: 100 - remaining, durationMinutes: duration, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw AIQuotaError.malformed }
        windows.sort { ($0.durationMinutes ?? Int.max, $0.position) < ($1.durationMinutes ?? Int.max, $1.position) }
        return AIQuotaSnapshot(provider: "Gemini", accountID: sourceID, updatedAt: updatedAt, windows: windows)
    }
}

enum QuotaResetDateParser {
    static func parse(_ text: String, timeZone: TimeZone) throws -> Date? {
        if ["unknown", "—"].contains(text) { return nil }
        if let date = AIQuotaTimestamp.iso8601(text) { return date }
        let parts = text.split(separator: " ")
        guard parts.count == 3 else { throw AIQuotaError.malformed }
        let wall = String(parts[0]) + " " + String(parts[1]), zone = String(parts[2])
        guard wall.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression) != nil else { throw AIQuotaError.malformed }
        let resolved: TimeZone
        var requiresAbbreviation = false
        if ["UTC", "GMT", "Z"].contains(zone) { resolved = TimeZone(secondsFromGMT: 0)! }
        else if zone.range(of: #"^[+-]\d{2}(?:\d{2})?$"#, options: .regularExpression) != nil {
            let digits = String(zone.dropFirst()), hour = Int(digits.prefix(2))!, minute = digits.count == 4 ? Int(digits.suffix(2))! : 0
            guard hour <= 14, minute < 60, hour != 14 || minute == 0 else { throw AIQuotaError.malformed }
            resolved = TimeZone(secondsFromGMT: (zone.first == "-" ? -1 : 1) * (hour * 3600 + minute * 60))!
        } else {
            guard zone.range(of: #"^[A-Za-z]{1,8}$"#, options: .regularExpression) != nil else { throw AIQuotaError.malformed }
            resolved = timeZone; requiresAbbreviation = true
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = resolved; formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        guard let parsed = formatter.date(from: wall), let date = AIQuotaTimestamp.validated(parsed),
              formatter.string(from: date) == wall else { throw AIQuotaError.malformed }
        if requiresAbbreviation {
            guard resolved.abbreviation(for: date) == zone else { throw AIQuotaError.malformed }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = resolved
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let beforeDay = calendar.startOfDay(for: date).addingTimeInterval(-1)
            let first = calendar.nextDate(after: beforeDay, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
            let last = calendar.nextDate(after: beforeDay, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
            guard first == last, first == date else { throw AIQuotaError.malformed }
        }
        return date
    }
}
