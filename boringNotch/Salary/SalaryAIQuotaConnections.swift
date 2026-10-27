import Foundation
import AppKit
import Combine

/// User-selected executable only. No PATH/home scans, shell evaluation, auth file
/// access, or persisted bookmark. The exact source and file metadata are pinned
/// for this run. This is source continuity, not authenticated account identity.
enum QuotaCLISelectionFailure: Error {
    case metadataUnavailable, executionNotAllowed
    var explanation: String {
        switch self {
        case .metadataUnavailable: return "无法读取所选文件的必要属性。未扩大文件权限；未建立连接。"
        case .executionNotAllowed: return "系统未允许执行所选文件。当前沙盒权限保持不变；未启动 CLI。"
        }
    }
}

struct QuotaCLISelection {
    let url: URL
    let provider: AIQuotaProvider
    private let resolved: URL
    private let inode: UInt64
    private let device: UInt64
    private let size: UInt64
    private let modified: Date
    init(url: URL, provider: AIQuotaProvider) throws {
        let expected = provider == .codex ? "codex" : "agy"
        guard provider != .glm, url.isFileURL, url.path.hasPrefix("/"), url.lastPathComponent == expected else { throw AIQuotaError.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let actual = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: actual.path) else { throw QuotaCLISelectionFailure.metadataUnavailable }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw AIQuotaError.unavailable }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw QuotaCLISelectionFailure.executionNotAllowed }
        self.url = url; self.provider = provider; resolved = actual
        self.inode = inode.uint64Value; self.device = device.uint64Value
        self.size = size.uint64Value; self.modified = modified
    }
    func verifyUnchanged() throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL == resolved,
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == inode,
              (attributes[.systemNumber] as? NSNumber)?.uint64Value == device,
              (attributes[.size] as? NSNumber)?.uint64Value == size,
              attributes[.modificationDate] as? Date == modified,
              FileManager.default.isExecutableFile(atPath: url.path) else { throw AIQuotaError.sourceChanged }
    }
}

enum DefaultQuotaSourceError: Error {
    case missing
}

@MainActor
final class AIQuotaConnections: ObservableObject {
    static let shared = AIQuotaConnections()
    static let availableProviders: [AIQuotaProvider] = [.codex, .gemini]
    let store: AIQuotaStore
    @Published private(set) var selections: [AIQuotaProvider: QuotaCLISelection] = [:]
    @Published private(set) var selectionErrors: [AIQuotaProvider: String] = [:]
    @Published private(set) var automatic: Set<AIQuotaProvider> = []
    @Published private(set) var codenotchFiles: [AIQuotaProvider: URL] = [:]
    private var codenotchConsents: [AIQuotaProvider: CNSessionConsent] = [:]
    private var scopedSources: [AIQuotaProvider: URL] = [:]
    @Published private(set) var paused = false
    private(set) var isShuttingDown = false
    @Published private(set) var geminiGroup = "Gemini Models"
    private var visible = false
    private var connectionPanelVisible = false
    private var locked = false
    private var sleeping = false
    private var privateOrDemo = false
    private var timer: Task<Void, Never>?
    private var relay: AnyCancellable?
    private var termination: AnyCancellable?
    private let waitForRefreshCheck: () async throws -> Void

    init(store: AIQuotaStore? = nil,
         waitForRefreshCheck: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(30)) }) {
        self.waitForRefreshCheck = waitForRefreshCheck
        let store = store ?? AIQuotaStore()
        self.store = store
        relay = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.shutdown() }
    }
    deinit {
        timer?.cancel()
        codenotchConsents.values.forEach { $0.revokeAll() }
        scopedSources.values.forEach { $0.stopAccessingSecurityScopedResource() }
    }
    func select(_ provider: AIQuotaProvider, url: URL) throws {
        disconnect(provider)
        do {
            selections[provider] = try QuotaCLISelection(url: url, provider: provider)
            selectionErrors[provider] = nil
        } catch {
            selectionErrors[provider] = (error as? QuotaCLISelectionFailure)?.explanation ?? "所选文件不符合 CLI 名称或文件类型要求。未建立连接。"
            throw error
        }
    }
    /// Construct fixed paths only; this does not read, stat, launch, or grant access.
    static func defaultSourceURL(_ provider: AIQuotaProvider, home: URL) -> URL {
        switch provider {
        case .codex: return home.appendingPathComponent(".local/bin/codex")
        case .glm: return CNCredentialFileKind.claudeGLMSettings.defaultURL(home: home)
        case .gemini: return home.appendingPathComponent(".local/bin/agy")
        }
    }
    /// Called only after the user presses the explicit connection button.
    /// A manually selected source always wins; no source is read or launched here.
    func prepareDefaultSourceIfNeeded(_ provider: AIQuotaProvider, home: URL) throws {
        guard !isShuttingDown else { throw AIQuotaError.unavailable }
        if provider != .glm {
            guard selections[provider] == nil else { return }
        } else {
            guard codenotchFiles[provider] == nil else { return }
        }
        let url = Self.defaultSourceURL(provider, home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { throw DefaultQuotaSourceError.missing }
        if provider != .glm { try select(provider, url: url) }
        else { try selectCodenotch(provider, url: url) }
    }

    /// The UI calls this only from its explicit source-specific consent button.
    /// No selections, credentials, refresh grants or identity are persisted.
    func connect(_ provider: AIQuotaProvider, group: String = "Gemini Models", periodically: Bool = false) async throws {
        guard !isShuttingDown, let selection = selections[provider], provider != .glm,
              ["Gemini Models", "Argon Models"].contains(group) else { throw AIQuotaError.unavailable }
        let validationScope = selection.url.startAccessingSecurityScopedResource()
        defer { if validationScope { selection.url.stopAccessingSecurityScopedResource() } }
        try selection.verifyUnchanged()
        let sourceID = UUID().uuidString
        store.connect(provider, accountID: sourceID) {
            let access = selection.url.startAccessingSecurityScopedResource()
            defer { if access { selection.url.stopAccessingSecurityScopedResource() } }
            try selection.verifyUnchanged()
            let snapshot: AIQuotaSnapshot
            switch provider {
            case .codex: snapshot = try await CodexQuotaClient(executableURL: selection.url).read(sourceID: sourceID)
            case .gemini: snapshot = try await AGYUsageClient(executableURL: selection.url, group: group).read(sourceID: sourceID)
            case .glm: throw AIQuotaError.unavailable
            }
            try selection.verifyUnchanged()
            return snapshot
        }
        if periodically { automatic.insert(provider) } else { automatic.remove(provider) }
        reconcile()
        await refresh(provider)
    }
    // Explicit file/default-source consent is separate from selecting a source.
    // No read, network call, bookmark, keychain or source scan occurs on selection.
    func selectCodenotch(_ provider: AIQuotaProvider, url: URL) throws {
        guard Self.availableProviders.contains(provider), provider != .gemini else { throw AIQuotaError.unavailable }
        guard url.isFileURL else { throw AIQuotaError.unavailable }
        disconnect(provider); codenotchFiles[provider] = url
    }
    func selectDefaultCodenotch(_ provider: AIQuotaProvider, home: URL) throws {
        guard let kind = credentialKind(provider) else { throw AIQuotaError.unavailable }
        try selectCodenotch(provider, url: kind.defaultURL(home: home))
    }
    /// Gemini has no credential-file kind: quota must come from the selected
    /// AGY CLI executable run with its existing login, never an OAuth file.
    private func credentialKind(_ provider: AIQuotaProvider) -> CNCredentialFileKind? {
        switch provider { case .codex: return .codexAuth; case .glm: return .claudeGLMSettings; case .gemini: return nil }
    }
    func connectCodenotch(_ provider: AIQuotaProvider, periodically: Bool = false,
                          transport: any CNHTTPTransport = CNURLSessionTransport()) async throws {
        guard !isShuttingDown, Self.availableProviders.contains(provider), provider != .gemini else { throw AIQuotaError.unavailable }
        guard let kind = credentialKind(provider), let url = codenotchFiles[provider] else { throw AIQuotaError.unavailable }
        codenotchConsents[provider]?.revokeAll()
        if let previous = scopedSources.removeValue(forKey: provider) { previous.stopAccessingSecurityScopedResource() }
        let consent = CNSessionConsent(approved: [provider]); codenotchConsents[provider] = consent
        if url.startAccessingSecurityScopedResource() { scopedSources[provider] = url }
        let file = CNPermittedCredentialFile(kind: kind, url: url, consent: consent)
        let sourceID = UUID().uuidString
        let reader: AIQuotaStore.Reader
        switch provider {
        case .codex:
            let adapter = CNCodexLocalProvider(credentials: { try file.read() }, transport: transport, authorization: consent)
            reader = { try await adapter.fetchSnapshot(sourceID: sourceID) }
        case .glm:
            let adapter = CNGLMProvider(credentials: { try file.read() }, transport: transport, authorization: consent)
            reader = { try await adapter.fetchSnapshot(sourceID: sourceID) }
        case .gemini: throw AIQuotaError.unavailable
        }
        store.connect(provider, accountID: sourceID, reader: reader)
        if periodically { automatic.insert(provider) } else { automatic.remove(provider) }
        reconcile(); await refresh(provider)
    }
    func disconnect(_ provider: AIQuotaProvider) {
        codenotchConsents.removeValue(forKey: provider)?.revokeAll()
        if let url = scopedSources.removeValue(forKey: provider) { url.stopAccessingSecurityScopedResource() }
        codenotchFiles[provider] = nil
        store.disconnect(provider); automatic.remove(provider); selections[provider] = nil; selectionErrors[provider] = nil
        reconcile()
    }
    func setGeminiGroup(_ value: String) {
        guard ["Gemini Models", "Argon Models"].contains(value), value != geminiGroup else { return }
        geminiGroup = value; changeGroup()
    }
    func changeGroup() {
        disconnect(.gemini)
    }
    func setPaused(_ value: Bool) { paused = value; reconcile() }
    func setVisible(_ value: Bool) { visible = value; reconcile() }
    func setConnectionPanelVisible(_ value: Bool) { connectionPanelVisible = value; reconcile() }
    func setLocked(_ value: Bool) { locked = value; reconcile() }
    func setSleeping(_ value: Bool) { sleeping = value; reconcile() }
    func setPrivateOrDemo(_ value: Bool) { privateOrDemo = value; reconcile() }
    /// willTerminate fallback: cancels without awaiting; the normal quit
    /// path is shutdownAndWait driven by applicationShouldTerminate.
    func shutdown() {
        isShuttingDown = true
        paused = true; visible = false; connectionPanelVisible = false
        timer?.cancel(); timer = nil
        store.setSuspended(true)
        AIQuotaProvider.allCases.forEach { disconnect($0) }
    }

    /// Normal quit path. Stops new launches synchronously (before any await),
    /// then the store cancels and awaits every in-flight or still-draining
    /// read — including earlier cancelled tasks — and sources are disconnected
    /// only after those awaits complete. Suspends instead of blocking the main
    /// thread; owned child SIGTERM/SIGKILL and exit cleanup are done on return.
    func shutdownAndWait() async {
        isShuttingDown = true
        paused = true; visible = false; connectionPanelVisible = false
        timer?.cancel(); timer = nil
        await store.shutdownTasksAndWait()
        AIQuotaProvider.allCases.forEach { disconnect($0) }
    }
    func refresh(_ provider: AIQuotaProvider, manual: Bool = false) async {
        guard !isShuttingDown, Self.availableProviders.contains(provider) else { return }
        await store.refresh(provider, manual: manual)
        if !store.state(for: provider).isConnected {
            codenotchConsents.removeValue(forKey: provider)?.revokeAll()
            if let url = scopedSources.removeValue(forKey: provider) { url.stopAccessingSecurityScopedResource() }
            automatic.remove(provider); reconcile()
        }
    }
    static func canShow(_ state: AIQuotaCardState) -> Bool {
        state.isConnected && (state.snapshot?.windows.contains { $0.usedPercent != nil } ?? false)
    }
    var visibleProviders: [AIQuotaProvider] {
        Self.availableProviders.filter { Self.canShow(store.state(for: $0)) }
    }
    private func reconcile() {
        timer?.cancel(); timer = nil
        let suspended = isShuttingDown || !(visible || connectionPanelVisible) || locked || sleeping || privateOrDemo || paused
        store.setSuspended(suspended)
        guard !suspended, !automatic.isEmpty else { return }
        // Local clock check only; the store permits network reads every 300s,
        // on an explicit manual action, or once across a known reset boundary.
        let wait = waitForRefreshCheck
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await wait() } catch { return }
                guard let self, !Task.isCancelled else { return }
                for provider in self.automatic.sorted(by: { $0.rawValue < $1.rawValue }) {
                    guard !Task.isCancelled else { return }
                    guard Self.availableProviders.contains(provider), Self.canShow(self.store.state(for: provider)) else { continue }
                    await self.refresh(provider)
                }
            }
        }
    }
}
