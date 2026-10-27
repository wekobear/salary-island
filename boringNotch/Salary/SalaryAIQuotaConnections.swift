import Foundation
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

@MainActor
final class AIQuotaConnections: ObservableObject {
    static let shared = AIQuotaConnections()
    let store: AIQuotaStore
    @Published private(set) var selections: [AIQuotaProvider: QuotaCLISelection] = [:]
    @Published private(set) var selectionErrors: [AIQuotaProvider: String] = [:]
    @Published private(set) var automatic: Set<AIQuotaProvider> = []
    @Published private(set) var paused = false
    @Published private(set) var geminiGroup = "Gemini Models"
    private var visible = false
    private var locked = false
    private var sleeping = false
    private var privateOrDemo = false
    private var timer: Task<Void, Never>?
    private var relay: AnyCancellable?

    init(store: AIQuotaStore? = nil) {
        let store = store ?? AIQuotaStore()
        self.store = store
        relay = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    deinit { timer?.cancel() }
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
    /// The UI calls this only from its explicit source-specific consent button.
    /// No selections, credentials, refresh grants or identity are persisted.
    func connect(_ provider: AIQuotaProvider, group: String = "Gemini Models", periodically: Bool = false) async throws {
        guard let selection = selections[provider], provider != .glm,
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
    func disconnect(_ provider: AIQuotaProvider) {
        store.disconnect(provider); automatic.remove(provider); selections[provider] = nil; selectionErrors[provider] = nil
        reconcile()
    }
    func setGeminiGroup(_ value: String) {
        guard ["Gemini Models", "Argon Models"].contains(value), value != geminiGroup else { return }
        geminiGroup = value; changeGroup()
    }
    func changeGroup() {
        store.disconnect(.gemini); automatic.remove(.gemini); reconcile()
    }
    func setPaused(_ value: Bool) { paused = value; reconcile() }
    func setVisible(_ value: Bool) { visible = value; reconcile() }
    func setLocked(_ value: Bool) { locked = value; reconcile() }
    func setSleeping(_ value: Bool) { sleeping = value; reconcile() }
    func setPrivateOrDemo(_ value: Bool) { privateOrDemo = value; reconcile() }
    func refresh(_ provider: AIQuotaProvider) async {
        await store.refresh(provider)
        if !store.state(for: provider).isConnected, automatic.contains(provider) {
            automatic.remove(provider); reconcile()
        }
    }
    private func reconcile() {
        timer?.cancel(); timer = nil
        let suspended = !visible || locked || sleeping || privateOrDemo || paused
        store.setSuspended(suspended)
        guard !suspended, !automatic.isEmpty else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                for provider in self.automatic.sorted(by: { $0.rawValue < $1.rawValue }) {
                    guard !Task.isCancelled else { return }
                    await self.refresh(provider)
                }
            }
        }
    }
}
