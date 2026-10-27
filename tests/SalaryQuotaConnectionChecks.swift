import Foundation

@main struct SalaryQuotaConnectionChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("salary-connection-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        func executable(_ name: String) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixture, to: url)
            return url
        }
        let manager = AIQuotaConnections()
        precondition(manager.selections.isEmpty && manager.automatic.isEmpty)
        await manager.refresh(.codex)
        precondition(!manager.store.state(for: .codex).isConnected)
        let codex = try executable("codex")
        try manager.select(.codex, url: codex)
        let pidFile = codex.deletingLastPathComponent().appendingPathComponent("pid.txt")
        precondition(!FileManager.default.fileExists(atPath: pidFile.path), "selection alone cannot launch")
        manager.setVisible(true)
        try await manager.connect(.codex)
        precondition(manager.store.state(for: .codex).snapshot?.windows.first?.usedPercent == 42)
        precondition(manager.automatic.isEmpty, "auto refresh defaults OFF")
        manager.setPaused(true)
        let firstPID = try String(contentsOf: pidFile, encoding: .utf8)
        await manager.refresh(.codex)
        let pausedPID = try String(contentsOf: pidFile, encoding: .utf8)
        precondition(pausedPID == firstPID)
        manager.disconnect(.codex)
        precondition(manager.selections[.codex] == nil && manager.store.state(for: .codex).snapshot == nil)
        manager.setPaused(false)
        let agy = try executable("agy")
        try manager.select(.gemini, url: agy)
        try await manager.connect(.gemini, group: "Gemini Models", periodically: true)
        precondition(manager.store.state(for: .gemini).snapshot?.windows.count == 2)
        precondition(manager.store.state(for: .gemini).snapshot?.windows.allSatisfy { $0.bucketID == "Gemini Models" } == true)
        precondition(manager.automatic == [.gemini])
        manager.setVisible(false)
        precondition(manager.store.isSuspended)
        manager.setVisible(true); manager.setLocked(true)
        precondition(manager.store.isSuspended)
        manager.setLocked(false); manager.setSleeping(true)
        precondition(manager.store.isSuspended)
        manager.setSleeping(false); manager.setPrivateOrDemo(true)
        precondition(manager.store.isSuspended)
        manager.setGeminiGroup("Argon Models")
        precondition(manager.geminiGroup == "Argon Models", "selection survives popover recreation")
        precondition(manager.automatic.isEmpty && manager.store.state(for: .gemini).snapshot == nil)
        manager.disconnect(.gemini)
        let chosen = try QuotaCLISelection(url: codex, provider: .codex)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: codex.path)
        do { try chosen.verifyUnchanged(); fatalError("changed source accepted") }
        catch let error as AIQuotaError { precondition(error == .sourceChanged) }
        do { _ = try QuotaCLISelection(url: URL(fileURLWithPath: "/bin/sh"), provider: .codex); fatalError("shell accepted") }
        catch let error as AIQuotaError { precondition(error == .unavailable) }
        print("SalaryQuotaConnectionChecks: 18 checks passed; default OFF, explicit fake CLI wiring, pause/lifecycle and source changes")
    }
}
