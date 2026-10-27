// Copyright (c) 2026 Vinz — MIT, see docs/licenses/codenotch-MIT.txt.
// Adapted from AntigravityBridge discovery and quota request methods, commit
// 6522e9f3ee0fe35d46e428b441e6e80b586eacbb. No owned server, process launch,
// broad process scan or LocalhostTrust certificate exception is included.
import Foundation

enum CNAntigravityBridge {
    struct Endpoint: Equatable { let ports: [Int]; let csrfToken: String? }
    static let csrfHeader = "x-codeium-csrf-token"
    static func discover(processTable: String, allowIDE: Bool = false, listeningPorts: (Int) -> [Int]) -> Endpoint? {
        guard processTable.utf8.count <= 262144 else { return nil }
        let lines = processTable.split(separator: "\n")
        if allowIDE, let line = lines.first(where: { $0.contains("language_server") && $0.contains("--csrf_token") }),
           let token = value(of: "--csrf_token", in: String(line)), CNHeaderValue.valid(token),
           let endpoint = endpoint(for: line, token: token, ports: listeningPorts) { return endpoint }
        if let line = lines.first(where: isCLI), let endpoint = endpoint(for: line, token: nil, ports: listeningPorts) { return endpoint }
        return nil
    }
    static func isCLI(_ line: Substring) -> Bool {
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard fields.count >= 2 else { return false }
        return URL(fileURLWithPath: String(fields[1])).lastPathComponent == "agy"
    }
    private static func endpoint(for line: Substring, token: String?, ports: (Int) -> [Int]) -> Endpoint? {
        guard let pid = Int(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""), pid > 0 else { return nil }
        let values = Array(Set(ports(pid).filter { (1...65535).contains($0) })).sorted()
        guard !values.isEmpty, values.count <= 8 else { return nil }
        return Endpoint(ports: values, csrfToken: token)
    }
    static func value(of flag: String, in line: String) -> String? {
        let parts = line.split(separator: " ")
        guard let index = parts.firstIndex(of: Substring(flag)), index + 1 < parts.count else { return nil }
        return String(parts[index + 1])
    }
    static func listeningPorts(in output: String) -> [Int] {
        guard output.utf8.count <= 65536 else { return [] }
        return output.split(separator: "\n").compactMap { line in
            guard let address = line.split(separator: " ").last(where: { $0.contains(":") }),
                  let port = Int(address.split(separator: ":").last ?? ""), (1...65535).contains(port) else { return nil }
            return port
        }
    }
    static func quota(from endpoint: Endpoint, transport: any CNHTTPTransport, consent: CNSessionConsent, now: Date) async throws -> [CNLimitWindow] {
        try consent.require(.gemini)
        guard !endpoint.ports.isEmpty, endpoint.ports.count <= 8,
              endpoint.ports.allSatisfy({ (1...65535).contains($0) }),
              endpoint.csrfToken.map(CNHeaderValue.valid) ?? true else { throw AIQuotaError.malformed }
        var lastError: Error = AIQuotaError.unavailable
        for port in endpoint.ports {
            do {
                try Task.checkCancellation(); try consent.require(.gemini)
                var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)\(CNRequestPolicy.localPath)")!)
                request.httpMethod = "POST"; request.timeoutInterval = 10
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let token = endpoint.csrfToken { request.setValue(token, forHTTPHeaderField: csrfHeader) }
                request.httpBody = Data(#"{"forceRefresh":true}"#.utf8)
                let response = try await transport.send(request)
                try Task.checkCancellation(); try consent.require(.gemini)
                if response.status == 429 { throw AIQuotaReadFailure(.rateLimited, retryAfter: max(300, CNUsagePolicy.retryAfter(response.retryAfter, now: now) ?? 0)) }
                guard response.status == 200 else { throw CNUsageProviderError.badResponse(status: response.status) }
                let windows = try CNAntigravityQuotaParser.parse(response.body, now: now)
                if !windows.isEmpty { return windows }
            } catch is CancellationError { throw CancellationError() }
            catch let failure as AIQuotaReadFailure { throw failure }
            catch { lastError = error }
        }
        throw lastError
    }
}
