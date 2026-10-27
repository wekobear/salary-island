import Foundation
import Combine

/// A provider is a display/source category, not an independent account or model quota.
enum AIQuotaProvider: String, CaseIterable, Identifiable {
    case codex, gemini, glm
    var id: String { rawValue }
    var title: String {
        switch self { case .codex: return "Codex"; case .gemini: return "Gemini"; case .glm: return "GLM 5.3" }
    }
    var scope: String {
        switch self {
        case .codex: return "账户额度"
        case .gemini: return "Antigravity · CLI 额度组"
        case .glm: return "Coding Plan · 套餐共享"
        }
    }
}

struct AIQuotaReadFailure: Error {
    let error: AIQuotaError
    let retryAfter: TimeInterval?
    init(_ error: AIQuotaError, retryAfter: TimeInterval? = nil) {
        self.error = error
        self.retryAfter = retryAfter
    }
}

struct AIQuotaCardState: Equatable {
    var accountID: String?
    var snapshot: AIQuotaSnapshot?
    var error: AIQuotaError?
    var accountChanged = false
    var isRefreshing = false
    var nextRefreshAt: Date?
    var isConnected: Bool { accountID != nil }
    func isStale(at date: Date) -> Bool {
        guard let snapshot else { return false }
        return error != nil || date.timeIntervalSince(snapshot.updatedAt) >= 900
            || snapshot.windows.contains { $0.resetsAt.map { $0 <= date } ?? false }
    }
}

/// In-memory only. Production starts with no readers: no credentials, processes,
/// requests, timers, or persistent grants. An authorized connection supplies a reader.
/// Visibility/lock suspension and disconnect invalidate outstanding responses.
@MainActor
final class AIQuotaStore: ObservableObject {
    typealias Reader = () async throws -> AIQuotaSnapshot
    @Published private(set) var cards: [AIQuotaProvider: AIQuotaCardState] = [:]
    private var readers: [AIQuotaProvider: Reader] = [:]
    private var tasks: [AIQuotaProvider: Task<Void, Never>] = [:]
    private var generations: [AIQuotaProvider: UUID] = [:]
    private var failures: [AIQuotaProvider: Int] = [:]
    private let now: () -> Date
    private(set) var isSuspended = true
    private let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval = 300, now: @escaping () -> Date = Date.init) {
        self.refreshInterval = max(300, refreshInterval)
        self.now = now
    }
    func state(for provider: AIQuotaProvider) -> AIQuotaCardState { cards[provider] ?? AIQuotaCardState() }

    /// Called only after the application has obtained explicit source-specific consent.
    /// It does not save credentials and does not itself initiate a request.
    func connect(_ provider: AIQuotaProvider, accountID: String, reader: @escaping Reader) {
        disconnect(provider)
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        readers[provider] = reader
        cards[provider] = AIQuotaCardState(accountID: accountID)
    }
    func disconnect(_ provider: AIQuotaProvider) {
        cancel(provider)
        readers[provider] = nil
        failures[provider] = nil
        cards[provider] = AIQuotaCardState()
    }
    private func cancel(_ provider: AIQuotaProvider) {
        generations[provider] = UUID()
        tasks.removeValue(forKey: provider)?.cancel()
        if cards[provider] != nil { cards[provider]?.isRefreshing = false }
    }
    func setSuspended(_ suspended: Bool) {
        isSuspended = suspended
        if suspended { AIQuotaProvider.allCases.forEach { cancel($0) } }
    }
    func refresh(_ provider: AIQuotaProvider) async {
        guard !isSuspended, let reader = readers[provider], let account = cards[provider]?.accountID else { return }
        if let existing = tasks[provider] { await existing.value; return }
        if let next = cards[provider]?.nextRefreshAt, now() < next { return }
        let generation = UUID()
        generations[provider] = generation
        cards[provider]?.isRefreshing = true
        let task = Task { [weak self] in
            do {
                let snapshot = try await reader()
                guard let self, self.generations[provider] == generation, !Task.isCancelled else { return }
                guard snapshot.accountID == account, snapshot.provider == provider.title,
                      snapshot.updatedAt <= self.now().addingTimeInterval(60) else { throw AIQuotaError.malformed }
                if let previous = self.cards[provider]?.snapshot?.backendAccountID,
                   let current = snapshot.backendAccountID, previous != current {
                    self.cards[provider]?.snapshot = nil
                    self.cards[provider]?.accountChanged = true
                }
                self.cards[provider]?.snapshot = snapshot
                self.cards[provider]?.error = nil
                self.cards[provider]?.nextRefreshAt = self.now().addingTimeInterval(self.refreshInterval)
                self.failures[provider] = 0
            } catch {
                guard let self, self.generations[provider] == generation, !Task.isCancelled else { return }
                if error is CancellationError {
                    // Cancellation is not an offline/error state and does not discard valid data.
                } else {
                    let failure: AIQuotaReadFailure
                    if let value = error as? AIQuotaReadFailure { failure = value }
                    else if let value = error as? AIQuotaError { failure = AIQuotaReadFailure(value) }
                    else if let value = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(value.code) {
                        failure = AIQuotaReadFailure(.offline)
                    } else { failure = AIQuotaReadFailure(.unavailable) }
                    self.cards[provider]?.error = failure.error
                    let count = min((self.failures[provider] ?? 0) + 1, 6)
                    self.failures[provider] = count
                    let base = failure.error == .rateLimited ? 900.0 : 300.0
                    let backoff = min(3600, base * pow(2, Double(count - 1)))
                    let requested = failure.retryAfter.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
                    self.cards[provider]?.nextRefreshAt = self.now().addingTimeInterval(max(backoff, requested))
                    if [.unauthorized, .cleanupFailed, .sourceChanged, .rpcRejected, .outputTooLarge].contains(failure.error) {
                        // Reauthorization must explicitly replace the reader; no retry loop with expired credentials.
                        self.readers[provider] = nil
                        self.cards[provider]?.accountID = nil
                        self.cards[provider]?.snapshot = nil
                    }
                }
            }
            guard let self, self.generations[provider] == generation else { return }
            self.cards[provider]?.isRefreshing = false
            self.tasks[provider] = nil
        }
        tasks[provider] = task
        await task.value
    }
}
