// Salary Island consent and bounded read adapter for the MIT Codenotch loaders.
// No default grant, keychain operation, file discovery, credential writes or logs.
import Foundation
import Darwin

final class CNSessionConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var approved: Set<AIQuotaProvider>
    init(approved: Set<AIQuotaProvider> = []) { self.approved = approved }
    func require(_ provider: AIQuotaProvider) throws {
        lock.lock(); defer { lock.unlock() }
        guard approved.contains(provider) else { throw AIQuotaError.unauthorized }
    }
    func revoke(_ provider: AIQuotaProvider) { lock.lock(); approved.remove(provider); lock.unlock() }
    func revokeAll() { lock.lock(); approved.removeAll(); lock.unlock() }
}
enum CNCredentialFileKind {
    case codexAuth, claudeGLMSettings, antigravityCLI
    var provider: AIQuotaProvider { switch self { case .codexAuth: return .codex; case .claudeGLMSettings: return .glm; case .antigravityCLI: return .gemini } }
    /// Constructs only the documented default path; does not stat/read/scan it.
    func defaultURL(home: URL) -> URL {
        switch self {
        case .codexAuth: return home.appendingPathComponent(".codex/auth.json")
        case .claudeGLMSettings: return home.appendingPathComponent(".claude/settings.json")
        case .antigravityCLI: return home.appendingPathComponent(".gemini/antigravity-cli/oauth_creds.json")
        }
    }
}
struct CNPermittedCredentialFile {
    let kind: CNCredentialFileKind
    let url: URL
    let consent: CNSessionConsent
    func read() throws -> Data {
        try consent.require(kind.provider)
        guard url.isFileURL else { throw AIQuotaError.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw AIQuotaError.unauthorized }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), info.st_size >= 0, info.st_size <= 1_048_576 else { throw AIQuotaError.malformed }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            try consent.require(kind.provider)
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw AIQuotaError.unavailable }
            guard data.count + count <= 1_048_576 else { throw AIQuotaError.outputTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
