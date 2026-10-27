// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted for Salary Island, 2026-10-27. Upstream: vinzdg/codenotch
// commit 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. See PORTING.md.
import Foundation

struct CNAntigravityCredentials {
    let accessToken: String
    let expiresAt: Date?
    let authMethod: String
    var projectId: String? = nil
    private static let goKeyringPrefix = "go-keyring-base64:"
    static func parse(_ value: String) -> Date? { AIQuotaTimestamp.iso8601(value) }
    static func decode(_ data: Data) -> CNAntigravityCredentials? {
        guard data.count <= 1_048_576 else { return nil }
        if let acp = decodeACP(data) {
            return acp
        }

        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix(goKeyringPrefix) {
            text = String(text.dropFirst(goKeyringPrefix.count))
        }
        guard let payload = Data(base64Encoded: text) else { return nil }

        struct Stored: Decodable {
            struct Token: Decodable {
                let access_token: String
                /// RFC 3339 with fractional seconds *and an offset* —
                /// "2026-08-31T21:53:49.575961+07:00". Not UTC, and not
                /// milliseconds since the epoch like Claude's. Parsing it as
                /// either is how a token that is live reads as long expired.
                let expiry: String
            }
            let auth_method: String
            let token: Token
        }

        guard let stored = try? JSONDecoder().decode(Stored.self, from: payload),
              let expiry = parse(stored.token.expiry), CNHeaderValue.valid(stored.token.access_token)
        else { return nil }

        return CNAntigravityCredentials(accessToken: stored.token.access_token,
                                      expiresAt: expiry,
                                      authMethod: stored.auth_method)
    }

    /// Decodes raw JSON credentials, such as those stored by Antigravity ACP or oauth_creds.json.
    static func decodeACP(_ data: Data) -> CNAntigravityCredentials? {
        struct ACPPayload: Decodable {
            let access_token: String?
            let project_id: String?
            let projectId: String?
            let expiry_date: Double?
        }

        guard let payload = try? JSONDecoder().decode(ACPPayload.self, from: data) else {
            return nil
        }

        let token = payload.access_token ?? ""

        guard CNHeaderValue.valid(token) else { return nil }

        let expiry = payload.expiry_date.flatMap(AIQuotaTimestamp.milliseconds)
        guard payload.expiry_date == nil || expiry != nil else { return nil }
        let project = payload.projectId ?? payload.project_id
        guard project.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else { return nil }

        return CNAntigravityCredentials(
            accessToken: token,
            expiresAt: expiry,
            authMethod: "consumer",
            projectId: payload.projectId ?? payload.project_id
        )
    }

}
