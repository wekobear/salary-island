import Foundation
@main struct AGYDiagnosticCheck {
 static func main() throws {
  let tests = [
   "alice-personal@example.test /Users/secret-dir/token sk-supersecret-value",
   "Gemini Models Weekly Limit Remaining 62% 2028-03-14T09:30:00Z\nGemini 7 Argon Gemini 8 Argon Weekly Limit 34% 2028-03-14T09:30:00Z",
   "Quota:\nGemini Models Five Hour Limit Remaining 150% INVALID_DATE",
   "\u{1b}]0;sk-sensitive@example.test\u{7}"
  ]
  for value in tests {
   let diagnostic = AGYSafeDiagnostics.inspect(Data(value.utf8))
   let output = String(decoding: try JSONSerialization.data(withJSONObject:diagnostic, options:[.sortedKeys]),as:UTF8.self)
   for secret in ["alice-personal", "example.test", "secret-dir", "supersecret", "sk-sensitive", "62%", "34%"] { precondition(!output.contains(secret), "input leaked") }
  }
  let d = AGYSafeDiagnostics.inspect(Data(tests[1].utf8))
  let rows = d["lines"] as! [[String: Any]]
  precondition(rows[1]["versionsEqual"] as? Bool == false)
  precondition((d["fixture"] as! String).contains("Gemini 7 Argon Gemini 8 Argon"))
  let hidden = "privateTOKEN999\t/Users/privateNAME@example.test"
  let advanced = AGYSafeDiagnostics.inspect(Data(hidden.utf8))
  let encoded = String(decoding: try JSONSerialization.data(withJSONObject:advanced),as:UTF8.self)
  precondition(!encoded.contains("privateTOKEN") && !encoded.contains("privateNAME") && !encoded.contains("example"))
  let controls = advanced["rawControlPositions"] as! [[String:Int]]
  precondition(controls.contains { $0["codePoint"] == 9 && $0["line"] == 1 && $0["column"] == 16 })
  precondition((advanced["rawControlCounts"] as! [String:Int])["U+0009"] == 1)
  let entry = (advanced["lines"] as! [[String:Any]])[0]
  precondition((entry["structuralTemplate"] as! String).contains("<TAB>"))

  // Consistency probes: valid mixed-TAB row, SGR+CRLF wrapper, and a row with
  // an invalid unknown control byte. The parser and the diagnostic must agree.
  let tabRow = "Gemini Models\tFive Hour\tLimit Remaining 62%\t2028-03-14T09:30:00Z"
  let sgrRow = "\u{1b}[32mGemini Models Weekly Limit Remaining 62% 2028-03-14T09:30:00Z\u{1b}[0m\r\n"
  let controlRow = "Gemini Models Weekly Limit Remaining 62% 2028-03-14T09:30:00Z\u{1}"

  // Valid mixed-TAB row: the shared normalization lets the grammar see the
  // same line the production parser accepted, while the raw TAB code,
  // position and template are still reported from the original line.
  let valid = AGYSafeDiagnostics.inspect(Data(tabRow.utf8))
  precondition(valid["productParserAccepted"] as? Bool == true, "mixed-TAB row must parse")
  precondition((valid["counts"] as! [String: Int])["quotaRow"] == 1, "mixed-TAB row misreported")
  precondition((valid["rejectionReasons"] as! [String]).isEmpty, "valid mixed-TAB row flagged")
  let validLines = valid["lines"] as! [[String: Any]]
  precondition(validLines[0]["kind"] as? String == "quotaRow", "grammar/normalization drift")
  precondition((validLines[0]["structuralTemplate"] as! String).contains("<TAB>"), "raw TAB template lost")
  precondition((valid["rawControlCounts"] as! [String: Int])["U+0009"] == 3, "raw TAB count lost")
  precondition((valid["rawControlPositions"] as! [[String: Int]]).contains { $0["codePoint"] == 9 && $0["line"] == 1 && $0["column"] == 14 }, "raw TAB position lost")
  let validJSON = String(decoding: try JSONSerialization.data(withJSONObject: valid, options: [.sortedKeys]), as: UTF8.self)
  precondition(!validJSON.contains("62%"), "input leaked")

  // SGR + CRLF wrapper: both parser and diagnostic accept the same bytes.
  let sgr = AGYSafeDiagnostics.inspect(Data(sgrRow.utf8))
  precondition(sgr["productParserAccepted"] as? Bool == true, "SGR+CRLF row must parse")
  precondition(sgr["ansiStripped"] as? Bool == true, "SGR strip not detected")
  precondition((sgr["counts"] as! [String: Int])["quotaRow"] == 1, "SGR+CRLF row misreported")

  // Invalid unknown control: the line is unnormalizable, so the production
  // parser rejects it and the diagnostic reports a fixed reason without
  // leaking any of the line's content.
  let bad = AGYSafeDiagnostics.inspect(Data(controlRow.utf8))
  precondition(bad["productParserAccepted"] as? Bool == false, "unknown control must be rejected")
  precondition((bad["rejectionReasons"] as! [String]).contains("unnormalizableLine"), "unnormalizable line unreported")
  precondition((bad["rawControlCounts"] as! [String: Int])["U+0001"] == 1, "raw control count lost")
  let badJSON = String(decoding: try JSONSerialization.data(withJSONObject: bad), as: UTF8.self)
  precondition(!badJSON.contains("62%"), "input leaked")

  // Parser and diagnostic must agree on acceptance for every probe above.
  for (value, accepted) in [(tabRow, true), (sgrRow, true), (controlRow, false), (tests[1], false)] {
   let diagnostic = AGYSafeDiagnostics.inspect(Data(value.utf8))
   precondition((diagnostic["productParserAccepted"] as? Bool) == accepted, "parser/diagnostic disagreement")
   precondition((diagnostic["rejectionReasons"] as! [String]).isEmpty == accepted, "diagnostic reasons disagree")
  }

  // The normalized safe fixture must itself round-trip through the parser.
  let fixture = valid["fixture"] as! String
  precondition(fixture.contains("Gemini Models Five Hour Limit Remaining 50%"), "unexpected fixture")
  precondition((try? AGYUsageTextParser.parse(Data(fixture.utf8), group: "Gemini Models", sourceID: "synthetic-diagnostic", updatedAt: Date())) != nil, "safe fixture must parse")

  print("AGYDiagnosticCheck: synthetic whitelist, secret redaction, mismatch, exact control position and parser/diagnostic consistency checks passed")
 }
}
