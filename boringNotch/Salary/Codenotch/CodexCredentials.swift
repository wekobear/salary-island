// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted for Salary Island, 2026-10-27. Upstream: vinzdg/codenotch
// commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. See PORTING.md.
import Foundation

enum CNCodexCredentials {
    struct Credential { let accessToken: String; let accountID: String }
    /// Pure decoding of bytes provided by an explicitly authorized source.
    static func load(from data: Data, now: Date = Date()) throws -> Credential {
        struct Auth: Decodable {
            struct Tokens: Decodable {
                let access_token: String
                let account_id: String
            }
            let tokens: Tokens
        }
        guard data.count <= 1_048_576, let auth = try? JSONDecoder().decode(Auth.self, from: data),
              CNHeaderValue.valid(auth.tokens.access_token),
              CNHeaderValue.valid(auth.tokens.account_id)
        else { throw CNUsageProviderError.needsAuth }

        if let expiry = claims(inJWT: auth.tokens.access_token)?["exp"] as? Double,
           !expiry.isFinite || AIQuotaTimestamp.seconds(expiry) == nil || expiry <= now.timeIntervalSince1970 {
            throw CNUsageProviderError.credentialExpired
        }
        return Credential(accessToken: auth.tokens.access_token, accountID: auth.tokens.account_id)
    }

    /// Claims supply identity labels and a local expiry hint. The server validates the token.
    static func claims(inJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
