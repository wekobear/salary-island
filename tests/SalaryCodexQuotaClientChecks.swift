import Foundation

@main struct SalaryCodexQuotaClientChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("salary-quota-stub-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("codex")
        func install(_ script: String) throws {
            try Data(script.utf8).write(to: stub)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        }
        try install("""
        #!/bin/sh
        read -r init
        case "$init" in *'"method":"initialize"'*) ;; *) exit 10;; esac
        printf '%s\\n' '{"id":1,"result":{"userAgent":"fixture"}}'
        read -r initialized
        read -r limits
        case "$limits" in *'"method":"account/rateLimits/read"'*) ;; *) exit 11;; esac
        printf '%s\\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42,"windowDurationMins":300}}}}'
        read -r end
        """)
        let value = try await CodexQuotaClient(executableURL: stub).read(sourceID: "fixture-only")
        precondition(value.windows.first?.usedPercent == 42 && value.accountID == "fixture-only")
        try install("""
        #!/bin/sh
        read -r init
        printf '%s\\n' 'not json'
        read -r end
        """)
        do { _ = try await CodexQuotaClient(executableURL: stub).read(sourceID: "fixture"); fatalError("malformed accepted") }
        catch let error as AIQuotaError { precondition(error == .malformed) }
        try install("""
        #!/bin/sh
        read -r init
        read -r wait
        """)
        let pending = Task { try await CodexQuotaClient(executableURL: stub).read(sourceID: "fixture") }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do { _ = try await pending.value; fatalError("cancellation ignored") }
        catch is CancellationError {}
        print("SalaryCodexQuotaClientChecks: fake CLI handshake, quota, malformed output and cancellation passed; no real CLI/account used")
    }
}
