// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted for Salary Island, 2026-10-27. Upstream: vinzdg/codenotch
// commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. See PORTING.md.
import Foundation

enum CNGLMCredentials {
    struct Credential { let token: String; let baseURL: URL; let source: String }
    static func claudeCode(_ data: Data) -> Credential? {
        guard data.count <= 1_048_576, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let env = root["env"] as? [String: Any],
              let token = string(env["ANTHROPIC_AUTH_TOKEN"]) ?? string(env["ANTHROPIC_API_KEY"])
        else { return nil }

        // The base URL is what makes this a GLM key. Without it, or pointed
        // somewhere else, the token is not ours to claim.
        guard let base = string(env["ANTHROPIC_BASE_URL"]),
              let url = URL(string: base),
              let host = url.host,
              url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, isZaiHost(host)
        else { return nil }

        guard CNHeaderValue.valid(token) else { return nil }
        return Credential(token: token, baseURL: consoleBase(from: host), source: "Claude Code")
    }

    static func isZaiHost(_ host: String) -> Bool {
        host == "api.z.ai" || host == "open.bigmodel.cn"
    }

    static func consoleBase(from host: String) -> URL {
        host.hasSuffix("bigmodel.cn")
            ? URL(string: "https://open.bigmodel.cn")!
            : URL(string: "https://api.z.ai")!
    }

    /// Non-empty strings only: an empty key is worse than a missing one, it is
    /// a request that cannot succeed being sent all the same.
    private static func string(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
