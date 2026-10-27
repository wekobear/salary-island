import Foundation

private final class OfflineProtocol: URLProtocol {
    enum Mode { case success, tooLarge, hold }
    static let lock = NSLock()
    static var mode = Mode.success
    static var starts = 0
    static var stops = 0
    static func reset(_ next: Mode) { lock.lock(); mode = next; starts = 0; stops = 0; lock.unlock() }
    static func counts() -> (Int,Int) { lock.lock(); defer { lock.unlock() }; return (starts,stops) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.starts += 1; let mode = Self.mode; Self.lock.unlock()
        if case .hold = mode { return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:[:])!,cacheStoragePolicy:.notAllowed)
        switch mode {
        case .success: client?.urlProtocol(self,didLoad:Data("{\"rate_limit\":{}}".utf8))
        case .tooLarge: client?.urlProtocol(self,didLoad:Data(repeating:65,count:1_048_577))
        case .hold: break
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
}
@main struct SalaryCodenotchHTTPChecks {
    static func main() async throws {
        let transport = CNURLSessionTransport(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OfflineProtocol.self]
            return config
        })
        let request = URLRequest(url:URL(string:"https://chatgpt.com/backend-api/wham/usage")!)
        OfflineProtocol.reset(.success)
        let response = try await transport.send(request)
        precondition(response.status == 200 && response.body == Data("{\"rate_limit\":{}}".utf8))
        OfflineProtocol.reset(.tooLarge)
        do { _ = try await transport.send(request); fatalError("unbounded body accepted") }
        catch let error as AIQuotaError { precondition(error == .outputTooLarge) }
        OfflineProtocol.reset(.hold)
        let task = Task { try await transport.send(request) }
        for _ in 0..<1000 {
            if OfflineProtocol.counts().0 > 0 { break }
            try await Task.sleep(for:.milliseconds(1))
        }
        precondition(OfflineProtocol.counts().0 == 1)
        task.cancel()
        do { _ = try await task.value; fatalError("cancelled request succeeded") }
        catch { precondition(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        for _ in 0..<1000 {
            if OfflineProtocol.counts().1 > 0 { break }
            try await Task.sleep(for:.milliseconds(1))
        }
        precondition(OfflineProtocol.counts().1 > 0, "underlying request must stop")
        OfflineProtocol.reset(.success)
        do { _ = try await transport.send(URLRequest(url:URL(string:"https://evil.invalid")!)); fatalError("target accepted") }
        catch let error as AIQuotaError { precondition(error == .unavailable) }
        precondition(OfflineProtocol.counts().0 == 0)
        print("SalaryCodenotchHTTPChecks: 7 executed assertions in 4 URLProtocol scenarios (success, streaming cap, cancellation+stop, rejected target); zero network")
    }
}
