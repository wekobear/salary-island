import Foundation
import Darwin

@main struct SalaryQuotaProcessChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("salary-process-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        var cases = 0
        func setup(_ mode: String, binary: String = "codex") throws -> URL {
            let dir = root.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let executable = dir.appendingPathComponent(binary)
            try FileManager.default.copyItem(at: fixture, to: executable)
            return executable
        }
        func noOrphan(_ url: URL) throws {
            let pidText = try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("pid.txt"), encoding: .utf8)
            let pid = Int32(pidText)!
            precondition(kill(pid, 0) == -1 && errno == ESRCH, "our child must have exited before await returns")
        }
        let policy = QuotaProcessPolicy(timeout: 0.5, terminationGrace: 0.1, stdoutLimit: 32768, stderrLimit: 16384)
        for mode in ["immediate-exit", "success-ignore-term"] {
            let url = try setup(mode)
            let data = try await QuotaCLIProcess.run(executableURL: url, command: .codex, policy: policy)
            let parsed = try CodexQuotaParser.parse(data, accountID: "fixture", updatedAt: Date())
            precondition(parsed.windows.first?.usedPercent == 42)
            try noOrphan(url); cases += 1
        }
        for (mode, expected) in [("timeout", AIQuotaError.timedOut), ("timeout-ignore-term", .timedOut), ("large-out", .outputTooLarge), ("large-err", .outputTooLarge), ("malformed", .malformed)] {
            let url = try setup(mode)
            do { _ = try await QuotaCLIProcess.run(executableURL: url, command: .codex, policy: policy); fatalError("expected \(mode) failure") }
            catch let error as AIQuotaError { precondition(error == expected, "\(mode): \(error)") }
            try noOrphan(url); cases += 1
        }
        let canceledURL = try setup("cancel-ignore-term")
        let request = Task { try await QuotaCLIProcess.run(executableURL: canceledURL, command: .codex, policy: policy) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: canceledURL.deletingLastPathComponent().appendingPathComponent("pid.txt").path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        do { _ = try await request.value; fatalError("cancellation ignored") } catch is CancellationError {}
        try noOrphan(canceledURL); cases += 1
        let agyURL = try setup("agy", binary: "agy")
        let agyData = try await QuotaCLIProcess.run(executableURL: agyURL, command: .agy, policy: policy)
        precondition(String(data: agyData, encoding: .utf8)?.hasPrefix("Quota:") == true)
        try noOrphan(agyURL); cases += 1
        let missingURL = root.appendingPathComponent("missing-launch").appendingPathComponent("codex")
        do { _ = try await QuotaCLIProcess.run(executableURL: missingURL, command: .codex, policy: policy); fatalError("expected launch failure") }
        catch let error as AIQuotaError { precondition(error == .launchFailed, "missing-launch: \(error)") }
        cases += 1
        // Sanitized categories with numeric exit/signal only. The epipe case is deterministic:
        // the fixture closes stdin before replying, so the parent's follow-up write must hit EPIPE.
        // Read-side pipe errors cannot be produced deterministically without a test seam.
        let classified: [(mode: String, binary: String, command: QuotaCLICommand, expected: AIQuotaError)] = [
            ("agy-empty-stdout", "agy", .agy, .emptyOutput),
            ("agy-exit37", "agy", .agy, .exitedNonzero(37)),
            ("agy-selfsignal", "agy", .agy, .terminatedBySignal(SIGTERM)),
            ("epipe", "codex", .codex, .pipeFailed),
        ]
        for scenario in classified {
            let url = try setup(scenario.mode, binary: scenario.binary)
            do { _ = try await QuotaCLIProcess.run(executableURL: url, command: scenario.command, policy: policy); fatalError("expected \(scenario.mode) failure") }
            catch let error as AIQuotaError { precondition(error == scenario.expected, "\(scenario.mode): \(error)") }
            try noOrphan(url); cases += 1
        }
        print("SalaryQuotaProcessChecks: \(cases) scenarios passed; every launched fake PID confirmed ESRCH before return")
    }
}
