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
        let defaults = AIQuotaConnections()
        let fakeHome = root.appendingPathComponent("synthetic-home")
        precondition(AIQuotaConnections.defaultSourceURL(.codex, home: fakeHome).path == fakeHome.appendingPathComponent(".local/bin/codex").path)
        precondition(AIQuotaConnections.defaultSourceURL(.glm, home: fakeHome).path == fakeHome.appendingPathComponent(".claude/settings.json").path)
        precondition(AIQuotaConnections.defaultSourceURL(.gemini, home: fakeHome).path == fakeHome.appendingPathComponent(".local/bin/agy").path)
        precondition(!FileManager.default.fileExists(atPath: fakeHome.path), "path construction cannot create or read a source")
        for provider in AIQuotaProvider.allCases {
            do { try defaults.prepareDefaultSourceIfNeeded(provider, home: fakeHome); fatalError("missing default accepted") }
            catch DefaultQuotaSourceError.missing {}
        }
        precondition(defaults.selections.isEmpty && defaults.codenotchFiles.isEmpty && defaults.automatic.isEmpty)
        let agyDefault = AIQuotaConnections.defaultSourceURL(.gemini, home: fakeHome)
        try FileManager.default.createDirectory(at: agyDefault.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: agyDefault)
        try defaults.prepareDefaultSourceIfNeeded(.gemini, home: fakeHome)
        precondition(defaults.selections[.gemini]?.url == agyDefault && defaults.automatic.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: agyDefault.deletingLastPathComponent().appendingPathComponent("pid.txt").path), "preparing a default cannot run the CLI")
        let custom = try executable("codex")
        try defaults.select(.codex, url: custom)
        try defaults.prepareDefaultSourceIfNeeded(.codex, home: fakeHome)
        precondition(defaults.selections[.codex]?.url == custom, "explicit selection wins over default")
        defaults.disconnect(.gemini); defaults.disconnect(.codex)

        let manager = AIQuotaConnections()
        precondition(manager.selections.isEmpty && manager.automatic.isEmpty)
        manager.setConnectionPanelVisible(true)
        precondition(!manager.store.isSuspended, "connection panel permits an explicit first query")
        manager.setVisible(true); manager.setConnectionPanelVisible(false)
        precondition(!manager.store.isSuspended, "closing settings must not suspend an open notch")
        manager.setVisible(false)
        precondition(manager.store.isSuspended, "closing both surfaces suspends refresh")
        precondition(manager.visibleProviders.isEmpty, "unconnected providers stay hidden")
        precondition(!AIQuotaConnections.canShow(AIQuotaCardState(accountID: "fixture")), "connected without snapshot stays hidden")
        let unknown = AIQuotaSnapshot(provider: "fixture", accountID: "fixture", updatedAt: Date(), windows: [AIQuotaWindow(bucketID: "x", bucketName: nil, position: "x", usedPercent: nil, durationMinutes: nil, resetsAt: nil)])
        precondition(!AIQuotaConnections.canShow(AIQuotaCardState(accountID: "fixture", snapshot: unknown)), "unknown usage stays hidden")
        precondition(!AIQuotaConnections.canShow(AIQuotaCardState(snapshot: unknown)), "disconnected snapshot stays hidden")
        await manager.refresh(.codex)
        precondition(!manager.store.state(for: .codex).isConnected)
        let codex = custom
        try manager.select(.codex, url: codex)
        let pidFile = codex.deletingLastPathComponent().appendingPathComponent("pid.txt")
        precondition(!FileManager.default.fileExists(atPath: pidFile.path), "selection alone cannot launch")
        manager.setVisible(true)
        try await manager.connect(.codex)
        precondition(manager.store.state(for: .codex).snapshot?.windows.first?.usedPercent == 42)
        precondition(manager.visibleProviders == [.codex], "only connected source with real snapshot is visible")
        precondition(manager.automatic.isEmpty, "auto refresh defaults OFF")
        manager.setPaused(true)
        let firstPID = try String(contentsOf: pidFile, encoding: .utf8)
        await manager.refresh(.codex)
        let pausedPID = try String(contentsOf: pidFile, encoding: .utf8)
        precondition(pausedPID == firstPID)
        manager.disconnect(.codex)
        precondition(manager.selections[.codex] == nil && manager.store.state(for: .codex).snapshot == nil)
        precondition(manager.visibleProviders.isEmpty, "disconnect folds the AI area")
        manager.setPaused(false)
        let agy = try executable("agy")
        do { try manager.selectCodenotch(.gemini, url: agy); fatalError("gemini credential file accepted") }
        catch let error as AIQuotaError { precondition(error == .unavailable) }
        precondition(manager.codenotchFiles[.gemini] == nil, "gemini credential file never stored")
        do { try manager.selectDefaultCodenotch(.gemini, home: root); fatalError("gemini default credential source accepted") }
        catch let error as AIQuotaError { precondition(error == .unavailable) }
        do { try await manager.connectCodenotch(.gemini, periodically: true); fatalError("gemini codenotch connect accepted") }
        catch let error as AIQuotaError { precondition(error == .unavailable) }
        precondition(!manager.store.state(for: .gemini).isConnected && manager.store.state(for: .gemini).snapshot == nil, "no gemini connection via credential file")
        precondition(manager.automatic.isEmpty, "no gemini auto refresh via credential file")
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
        print("SalaryQuotaConnectionChecks: default-source fixtures and fake AGY CLI /usage only, gemini credential-file path blocked, pause/lifecycle and source changes")
    }
}
