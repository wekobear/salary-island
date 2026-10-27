// Salary Island transport adaptation for the MIT Codenotch providers.
// Fixed original-service targets; no credential-bearing redirects or TLS exceptions.
import Foundation

struct CNHTTPResponse { let status: Int; let retryAfter: String?; let body: Data }
protocol CNHTTPTransport { func send(_ request: URLRequest) async throws -> CNHTTPResponse }
enum CNRequestPolicy {
    static let remoteURLs: Set<String> = [
        "https://chatgpt.com/backend-api/wham/usage",
        "https://api.z.ai/api/monitor/usage/quota/limit",
        "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"]
    static let localPath = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static func permits(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        if remoteURLs.contains(url.absoluteString) { return true }
        return url.host == "127.0.0.1" && url.path == localPath && url.port.map { (1...65535).contains($0) } == true
    }
}
final class CNRejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct CNURLSessionTransport: CNHTTPTransport {
    // Tests inject a URLProtocol-backed ephemeral configuration, never a live server.
    var configuration: () -> URLSessionConfiguration = { .ephemeral }
    func send(_ request: URLRequest) async throws -> CNHTTPResponse {
        guard CNRequestPolicy.permits(request.url), ["GET", "POST"].contains(request.httpMethod ?? "GET"),
              (request.httpBody?.count ?? 0) <= 4096 else { throw AIQuotaError.unavailable }
        let configuration = configuration()
        configuration.urlCache = nil; configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: CNRejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, response.url == request.url else { throw AIQuotaError.unavailable }
        let retry = response.value(forHTTPHeaderField: "Retry-After")
        guard (200..<300).contains(response.statusCode) else { return CNHTTPResponse(status: response.statusCode, retryAfter: retry, body: Data()) }
        guard response.expectedContentLength <= 1_048_576 else { throw AIQuotaError.outputTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw AIQuotaError.outputTooLarge }
            data.append(byte)
        }
        return CNHTTPResponse(status: response.statusCode, retryAfter: retry, body: data)
    }
}
