import Foundation

// MARK: - AGYSafeDiagnostics
//
// Safe, output-constrained diagnostics for the `AGYUsageTextParser` report grammar.
//
// Threat model: the input `Data` is fully untrusted CLI output. `inspect(_:)`
// NEVER copies any input byte into its result — no raw lines, tokens, account
// IDs, addresses, paths, cookies, secrets, original numbers or dates.
//
// The returned dictionary may contain ONLY:
//   * predefined constant labels (kinds, categories, reasons, grammar names),
//   * bounded numeric line indices (1...10_000),
//   * booleans describing field validity, version equality, character classes,
//   * counts of the whitelisted punctuation characters `% : - . / ( ) [ ]`,
//   * grammar rejection reasons from a fixed vocabulary,
//   * a fully synthetic fixture string built from whitelisted constants
//     (percent 50, ISO date 2028-03-14T09:30:00Z, fake model versions 7/8,
//     literal INVALID_DATE for rejected timestamps, literal
//     `<redacted-unknown-line>` for unknown rows).
//
// ANSI SGR escapes are stripped and remaining control characters are never
// emitted (only boolean class flags). All output sizes are explicitly capped.
// JSON dumps of the input are never decoded with JSONSerialization/JSONDecoder.

enum AGYSafeDiagnostics {

    // MARK: Hard budgets (independent of input)

    private static let maxInputBytes = 65_536          // mirrors AGYUsageTextParser
    private static let maxAnalyzedLines = 10_000       // bounded line index space
    private static let maxDetailedLines = 96           // per-line entries emitted
    private static let maxFixtureLines = 96            // fixture lines emitted
    private static let maxFixtureCharacters = 4_096    // fixture string length

    // MARK: Whitelisted output constants

    private static let schemaValue = "AGYSafeDiagnostics/1"
    private static let statusOK = "ok"
    private static let statusRejected = "rejected"

    private static let kindHeader = "header"
    private static let kindQuotaRow = "quotaRow"
    private static let kindModelRow = "modelRow"
    private static let kindUnknown = "unknown"

    private static let timestampISO = "iso"
    private static let timestampUTCWall = "utcWall"
    private static let timestampUnknown = "unknown"
    private static let timestampInvalid = "invalid"

    private static let reasonSizeLimit = "sizeLimit"
    private static let reasonEncoding = "encoding"
    private static let reasonControlCharacter = "controlCharacter"
    private static let reasonEmptyReport = "emptyReport"
    private static let reasonUnrecognizedLine = "unrecognizedLine"
    private static let reasonDuplicateQuotaKey = "duplicateQuotaKey"
    private static let reasonDuplicateModelVersion = "duplicateModelVersion"
    private static let reasonVersionMismatch = "versionMismatch"
    private static let reasonInvalidPercent = "invalidPercent"
    private static let reasonInvalidTimestamp = "invalidTimestamp"
    private static let reasonNoQuotaRows = "noQuotaRows"
    private static let reasonMalformedQuotaCandidate = "malformedQuotaCandidate"
    private static let reasonLineBudgetExceeded = "lineBudgetExceeded"
    private static let reasonUnnormalizableLine = "unnormalizableLine"

    private static let syntheticISODate = "2028-03-14T09:30:00Z"
    private static let syntheticWallDate = "2028-03-14 09:30 UTC"
    private static let syntheticPercent = "50"
    private static let syntheticInvalidPercent = "150"     // regex-shaped, out of range
    private static let syntheticUnknownReset = "unknown"
    private static let syntheticInvalidReset = "INVALID_DATE"
    private static let redactedUnknownLine = "<redacted-unknown-line>"
    private static let fixtureTruncationMarker = "<truncated>"
    private static let headerValue = "Quota:"
    private static let limitRemainingDelimiter = " Limit Remaining "

    private static let knownGroupPrefixes = [
        "Gemini Models ", "Argon Models ", "Claude and GPT models "
    ]

    // MARK: Grammar (exact copies of the live parser's patterns)

    private static let quotaRowRegex = try! NSRegularExpression(
        pattern: #"^(Gemini Models|Argon Models|Claude and GPT models) (Five Hour|Weekly) Limit Remaining ([0-9]+(?:\.[0-9]+)?)% (.+)$"#)
    private static let modelRowRegex = try! NSRegularExpression(
        pattern: #"^Gemini ([0-9]+) Argon Gemini ([0-9]+) Argon Weekly Limit ([0-9]+(?:\.[0-9]+)?)% (.+)$"#)
    private static let genericRowRegex = try! NSRegularExpression(
        pattern: #"^(.+?) (.+?) Limit Remaining ([0-9]+(?:\.[0-9]+)?)% (.+)$"#)
    private static let sgrPattern = "\u{1b}\\[[0-9;]*m"

    // MARK: Entry point

    static func inspect(_ data: Data) -> [String: Any] {
        var result: [String: Any] = ["schema": schemaValue, "status": statusRejected]

        // Same-byte cross-check with the production parser (fixed group and a
        // synthetic source ID). Only the boolean outcome is kept: snapshots,
        // raw input and parsed values are never printed, retained or emitted.
        result["productParserAccepted"] = (try? AGYUsageTextParser.parse(
            data, group: "Gemini Models", sourceID: "synthetic-diagnostic",
            updatedAt: Date())) != nil

        // The input is never persisted, echoed, or JSON-decoded; it is only
        // probed against the grammar replicated below.

        guard data.count <= maxInputBytes else {
            result["reason"] = reasonSizeLimit
            result["fixture"] = ""
            return result
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            result["reason"] = reasonEncoding
            result["fixture"] = ""
            return result
        }

        // Record only control code points and scalar positions, never text.
        let controlStats = rawControlStats(raw)
        result["rawControlCounts"] = controlStats
        result["rawControlPositions"] = controlPositions(raw)
        result["controlPositionsCap"] = 256

        // ANSI/control handling, mirroring the parser: strip SGR colour
        // escapes, normalise CRLF, then reject any residual escape or NUL.
        // Control characters are never emitted — only boolean flags below.
        let sgrStripped = raw.replacingOccurrences(of: sgrPattern, with: "", options: .regularExpression)
        let text = sgrStripped.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.contains("\u{1b}"), !text.contains("\u{0}") else {
            result["reason"] = reasonControlCharacter
            result["fixture"] = ""
            return result
        }
        let ansiStripped = sgrStripped != raw

        // Share the production normalization so per-line ASCII space/TAB runs
        // collapse exactly as the live parser sees them. The ORIGINAL
        // unnormalized line is retained only to derive control flags, the raw
        // structuralTemplate, knownPrefix and rejection details — never for
        // grammar or fixture classification.
        var allLines: [String] = []
        var originalLines: [String] = []
        var failedLines: [Bool] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            do {
                allLines.append(try AGYUsageTextParser.normalizedHorizontalSpaces(in: rawLine))
                failedLines.append(false)
            } catch {
                // Unnormalizable line: safely reject without echoing any of
                // its content; grammar below only ever sees an empty line.
                allLines.append("")
                failedLines.append(true)
            }
            originalLines.append(String(rawLine))
        }
        let normalizationFailed = failedLines.contains(true)

        guard !allLines.isEmpty else {
            result["reason"] = reasonEmptyReport
            result["fixture"] = ""
            return result
        }

        let analyzed = Array(allLines.prefix(maxAnalyzedLines))
        let analyzedOriginals = Array(originalLines.prefix(maxAnalyzedLines))
        let analyzedFailures = Array(failedLines.prefix(maxAnalyzedLines))
        let moreLines = allLines.count > maxAnalyzedLines

        let headerIndex = analyzed.firstIndex(of: headerValue)
        let headerPresent = headerIndex != nil

        var reasons: [String] = []
        func addReason(_ reason: String) {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        if moreLines { addReason(reasonLineBudgetExceeded) }
        if normalizationFailed { addReason(reasonUnnormalizableLine) }

        var lineEntries: [[String: Any]] = []
        var quotaRowCount = 0
        var modelRowCount = 0
        var unknownCount = 0
        var quotaKeys = Set<String>()     // group + lane (headerless mirror)
        var modelVersions = Set<String>() // first version (headerless mirror)
        var fixtureLines: [String] = []
        var fixtureTruncated = moreLines
        var containsControlCharacters = false

        for (offset, line) in analyzed.enumerated() {
            let lineNumber = offset + 1 // bounded: 1...maxAnalyzedLines
            // `line` is the shared-normalization view used for grammar and
            // fixtures; `original` feeds controls, raw template, knownPrefix
            // and other rejection details only.
            let original = analyzedOriginals[offset]

            if offset == headerIndex {
                if lineEntries.count < maxDetailedLines {
                    lineEntries.append(["line": lineNumber, "kind": kindHeader, "structuralTemplate": structuralTemplate(original)])
                }
                if fixtureLines.count < maxFixtureLines {
                    fixtureLines.append(headerValue)
                } else { fixtureTruncated = true }
                continue
            }

            if !containsControlCharacters,
               original.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                containsControlCharacters = true
            }

            let range = NSRange(line.startIndex..., in: line)

            if let match = quotaRowRegex.firstMatch(in: line, range: range),
               let gGroup = Range(match.range(at: 1), in: line),
               let gLane = Range(match.range(at: 2), in: line),
               let gPercent = Range(match.range(at: 3), in: line),
               let gReset = Range(match.range(at: 4), in: line) {
                // Exact known group/lane quota row. Only grammar labels and
                // booleans are emitted — never the captured values.
                let groupName = String(line[gGroup])  // constrained enumeration
                let lane = String(line[gLane])        // constrained enumeration
                let percentValid = percentIsValid(String(line[gPercent]))
                let (category, resetValid) = classifyReset(String(line[gReset]))
                quotaRowCount += 1
                let duplicate = !quotaKeys.insert(groupName + " " + lane).inserted
                if duplicate { addReason(reasonDuplicateQuotaKey) }
                if !percentValid { addReason(reasonInvalidPercent) }
                if !resetValid { addReason(reasonInvalidTimestamp) }
                if lineEntries.count < maxDetailedLines {
                    lineEntries.append([
                        "line": lineNumber,
                        "kind": kindQuotaRow,
                        "structuralTemplate": structuralTemplate(original),
                        "group": groupName,
                        "lane": lane,
                        "percentValid": percentValid,
                        "resetValid": resetValid,
                        "rejectionReason": duplicate ? reasonDuplicateQuotaKey : (!percentValid ? reasonInvalidPercent : (!resetValid ? reasonInvalidTimestamp : "none")),
                        "timestampCategory": category
                    ])
                }
                if fixtureLines.count < maxFixtureLines {
                    fixtureLines.append(fixtureQuotaRow(
                        group: groupName, lane: lane,
                        percentValid: percentValid, category: category))
                } else { fixtureTruncated = true }
                continue
            }

            if let match = modelRowRegex.firstMatch(in: line, range: range),
               let gVersion1 = Range(match.range(at: 1), in: line),
               let gVersion2 = Range(match.range(at: 2), in: line),
               let gPercent = Range(match.range(at: 3), in: line),
               let gReset = Range(match.range(at: 4), in: line) {
                // Model row: version equality as a boolean only; the versions
                // themselves are never emitted (fixture fakes 7/8).
                let version1 = String(line[gVersion1])
                let versionsEqual = version1 == String(line[gVersion2])
                let percentValid = percentIsValid(String(line[gPercent]))
                let (category, resetValid) = classifyReset(String(line[gReset]))
                modelRowCount += 1
                let duplicate = !modelVersions.insert(version1).inserted
                if duplicate { addReason(reasonDuplicateModelVersion) }
                if !versionsEqual { addReason(reasonVersionMismatch) }
                if !percentValid { addReason(reasonInvalidPercent) }
                if !resetValid { addReason(reasonInvalidTimestamp) }
                if lineEntries.count < maxDetailedLines {
                    lineEntries.append([
                        "line": lineNumber,
                        "kind": kindModelRow,
                        "structuralTemplate": structuralTemplate(original),
                        "versionsEqual": versionsEqual,
                        "percentValid": percentValid,
                        "resetValid": resetValid,
                        "rejectionReason": duplicate ? reasonDuplicateModelVersion : (!versionsEqual ? reasonVersionMismatch : (!percentValid ? reasonInvalidPercent : (!resetValid ? reasonInvalidTimestamp : "none"))),
                        "timestampCategory": category
                    ])
                }
                if fixtureLines.count < maxFixtureLines {
                    fixtureLines.append(fixtureModelRow(
                        versionsEqual: versionsEqual,
                        percentValid: percentValid, category: category))
                } else { fixtureTruncated = true }
                continue
            }

            // Unknown line: character-class flags and whitelisted punctuation
            // counts only — no characters, words, lengths or content. All raw
            // details derive from the ORIGINAL unnormalized line.
            unknownCount += 1
            if !headerPresent { addReason(reasonUnrecognizedLine) }
            let description = describeUnknownLine(original)
            var entry: [String: Any] = [
                "line": lineNumber,
                "kind": kindUnknown,
                "punctuationCounts": description.counts,
                "structuralTemplate": structuralTemplate(original),
                "rejectionReason": headerPresent ? "ignoredOrMalformed" : "unrecognizedLine"
            ]
            for (key, value) in description.flags { entry[key] = value }
            // These booleans expose only fixed grammar markers, never unknown text.
            let fixedGroups = ["Gemini Models", "Argon Models", "Claude and GPT models", "Gemini"]
            entry["knownPrefix"] = fixedGroups.first(where: { original.hasPrefix($0 + " ") }) ?? "none"
            entry["hasFiveHour"] = original.contains(" Five Hour ")
            entry["hasWeekly"] = original.contains(" Weekly ")
            entry["hasRemaining"] = original.contains(" Limit Remaining ")
            entry["hasLimit"] = original.contains(" Limit ")
            entry["hasTab"] = original.unicodeScalars.contains(where: { $0.value == 9 })
            entry["hasCarriageReturn"] = original.unicodeScalars.contains(where: { $0.value == 13 })
            entry["hasOtherControl"] = original.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0.value != 9 && $0.value != 13 })
            if analyzedFailures[offset] { entry["unnormalizable"] = true }
            if headerPresent {
                probeHeaderModeCandidate(line, into: &entry, addReason: addReason)
            }
            if lineEntries.count < maxDetailedLines {
                lineEntries.append(entry)
            }
            if fixtureLines.count < maxFixtureLines {
                fixtureLines.append(redactedUnknownLine)
            } else { fixtureTruncated = true }
        }

        if quotaRowCount == 0 { addReason(reasonNoQuotaRows) }

        var fixture = fixtureLines.joined(separator: "\n")
        if fixtureTruncated { fixture += "\n" + fixtureTruncationMarker }
        if fixture.count > maxFixtureCharacters {
            let boundary = fixture.index(fixture.startIndex, offsetBy: maxFixtureCharacters)
            let head = fixture[..<boundary]
            let cut = head.lastIndex(of: "\n") ?? head.startIndex
            fixture = String(head[..<cut]) + "\n" + fixtureTruncationMarker
        }

        result["status"] = statusOK
        result["headerPresent"] = headerPresent
        if let header = headerIndex { result["headerLineNumber"] = header + 1 }
        result["lineCount"] = analyzed.count
        result["moreLinesThanBudget"] = moreLines
        result["ansiStripped"] = ansiStripped
        result["containsControlCharacters"] = containsControlCharacters
        result["counts"] = [
            "quotaRow": quotaRowCount,
            "modelRow": modelRowCount,
            "unknown": unknownCount
        ]
        result["detailedTruncated"] = analyzed.count > maxDetailedLines
        result["lines"] = lineEntries
        result["rejectionReasons"] = reasons
        result["fixture"] = fixture
        return result
    }

    private static func rawControlStats(_ raw: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || (0x7F...0x9F).contains(value) {
                let key = String(format: "U+%04X", value)
                counts[key, default: 0] += 1
            }
        }
        return counts
    }

    /// Only code points from ASCII/C1 control ranges, plus bounded line and
    /// scalar offsets. No other character from the input is returned.
    private static func controlPositions(_ raw: String) -> [[String: Int]] {
        var positions: [[String: Int]] = []
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        for (line, value) in lines.prefix(maxDetailedLines).enumerated() {
            for (offset, scalar) in value.unicodeScalars.enumerated() {
                if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                    if positions.count == 256 { return positions }
                    positions.append(["line": line + 1, "column": offset + 1, "codePoint": Int(scalar.value)])
                }
            }
        }
        return positions
    }

    /// Shapes only: every alphabetic or numeric run is a placeholder. No input
    /// word or number can appear, even if it resembles a known provider label.
    private static func structuralTemplate(_ line: String) -> String {
        var parts: [String] = []
        var prior = ""
        for scalar in line.unicodeScalars {
            let code = scalar.value
            let part: String
            if (65...90).contains(code) || (97...122).contains(code) { part = "<word>" }
            else if (48...57).contains(code) { part = "<digits>" }
            else if code == 32 { part = "<space>" }
            else if code == 9 { part = "<TAB>" }
            else if code == 13 { part = "<CR>" }
            else if code < 0x20 || (0x7F...0x9F).contains(code) { part = "<control>" }
            else {
                switch code {
                case 37: part = "%"; case 58: part = ":"; case 45: part = "-"
                case 46: part = "."; case 47: part = "/"; case 40: part = "("
                case 41: part = ")"; case 91: part = "["; case 93: part = "]"
                default: part = "<other>"
                }
            }
            if part != prior || !["<word>", "<digits>", "<space>"].contains(part) { parts.append(part) }
            prior = part
            if parts.count >= 200 { parts.append("<truncated>"); break }
        }
        return parts.joined()
    }

    // MARK: Unknown-line description (classes + safe punctuation counts)

    private static func describeUnknownLine(_ line: String) -> (flags: [String: Bool], counts: [String: Int]) {
        var asciiLetters = false, asciiDigits = false, whitespace = false, punctuation = false
        var nonASCII = false, control = false
        var percent = 0, colon = 0, hyphen = 0, period = 0, slash = 0
        var openParen = 0, closeParen = 0, openBracket = 0, closeBracket = 0

        for scalar in line.unicodeScalars {
            switch scalar {
            case "%": percent &+= 1
            case ":": colon &+= 1
            case "-": hyphen &+= 1
            case ".": period &+= 1
            case "/": slash &+= 1
            case "(": openParen &+= 1
            case ")": closeParen &+= 1
            case "[": openBracket &+= 1
            case "]": closeBracket &+= 1
            default: break
            }
            if ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) {
                asciiLetters = true
            } else if ("0"..."9").contains(scalar) {
                asciiDigits = true
            } else if scalar.properties.isWhitespace {
                whitespace = true
            }
            if isPunctuation(scalar) { punctuation = true }
            if scalar.value > 0x7F { nonASCII = true }
            if scalar.properties.generalCategory == .control { control = true }
        }

        let flags: [String: Bool] = [
            "asciiLetters": asciiLetters,
            "asciiDigits": asciiDigits,
            "whitespace": whitespace,
            "punctuation": punctuation,
            "nonASCII": nonASCII,
            "control": control,
            "blankAfterTrim": line.isEmpty
        ]
        let counts: [String: Int] = [
            "%": percent, ":": colon, "-": hyphen, ".": period, "/": slash,
            "(": openParen, ")": closeParen, "[": openBracket, "]": closeBracket
        ]
        return (flags, counts)
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if (0x21...0x2F).contains(scalar.value) || (0x3A...0x40).contains(scalar.value)
            || (0x5B...0x60).contains(scalar.value) || (0x7B...0x7E).contains(scalar.value) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Header-mode candidate probe for unknown lines that the live parser would
    /// still inspect (known group prefix + "Limit Remaining"). Booleans only.
    private static func probeHeaderModeCandidate(_ line: String,
                                                 into entry: inout [String: Any],
                                                 addReason: (String) -> Void) {
        guard line.contains(limitRemainingDelimiter),
              knownGroupPrefixes.contains(where: line.hasPrefix) else { return }
        entry["groupPrefixedLimitRow"] = true
        let components = line.components(separatedBy: limitRemainingDelimiter)
        guard components.count == 2, !components[0].isEmpty,
              let percentEnd = components[1].firstIndex(of: "%") else {
            addReason(reasonMalformedQuotaCandidate)
            return
        }
        let number = String(components[1][..<percentEnd])
        guard number.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            entry["percentValid"] = false
            addReason(reasonMalformedQuotaCandidate)
            return
        }
        let percentValid = percentIsValid(number)
        entry["percentValid"] = percentValid
        if !percentValid { addReason(reasonInvalidPercent) }
        let resetText = String(components[1][components[1].index(after: percentEnd)...])
            .trimmingCharacters(in: .whitespaces)
        let (category, resetValid) = classifyReset(resetText)
        entry["timestampCategory"] = category
        entry["resetValid"] = resetValid
        if !resetValid { addReason(reasonInvalidTimestamp) }
        if genericRowRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil {
            addReason(reasonMalformedQuotaCandidate)
        }
    }

    // Use the production parser itself to prevent diagnostic drift.
    private static func classifyReset(_ text: String) -> (category: String, valid: Bool) {
        do {
            let value = try QuotaResetDateParser.parse(text, timeZone: .current)
            if value == nil { return (timestampUnknown, true) }
            if AIQuotaTimestamp.iso8601(text) != nil { return (timestampISO, true) }
            return (timestampUTCWall, true)
        } catch { return (timestampInvalid, false) }
    }

    // MARK: Percent validity

    private static func percentIsValid(_ text: String) -> Bool {
        guard let value = Double(text), value.isFinite, (0...100).contains(value) else { return false }
        return true
    }

    // MARK: Synthetic fixture builders (constants only)

    private static func fixtureQuotaRow(group: String, lane: String,
                                        percentValid: Bool, category: String) -> String {
        let percent = percentValid ? syntheticPercent : syntheticInvalidPercent
        return group + " " + lane + limitRemainingDelimiter + percent + "% " + resetToken(for: category)
    }

    private static func fixtureModelRow(versionsEqual: Bool,
                                        percentValid: Bool, category: String) -> String {
        let percent = percentValid ? syntheticPercent : syntheticInvalidPercent
        let versions = versionsEqual
            ? "Gemini 7 Argon Gemini 7 Argon Weekly Limit"
            : "Gemini 7 Argon Gemini 8 Argon Weekly Limit"
        return versions + " " + percent + "% " + resetToken(for: category)
    }

    private static func resetToken(for category: String) -> String {
        switch category {
        case timestampISO: return syntheticISODate
        case timestampUTCWall: return syntheticWallDate
        case timestampUnknown: return syntheticUnknownReset
        default: return syntheticInvalidReset
        }
    }
}
