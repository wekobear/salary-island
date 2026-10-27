import Foundation
import Darwin

/// The only protocol messages emitted by the quota client. No login, thread,
/// turn, credential file access, shell, or listening port is supported.
struct CodexQuotaRPC {
    enum Phase { case initialize, limits, finished }
    private(set) var phase: Phase = .initialize
    static let initialize = Data(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"salary-island-quota","version":"0.1"}}}"#.utf8) + Data([10])
    static let limits = Data(#"{"method":"initialized"}"#.utf8) + Data([10])
        + Data(#"{"id":2,"method":"account/rateLimits/read","params":{}}"#.utf8) + Data([10])

    /// Returns the next allowed write and/or the final quota response.
    mutating func receive(_ line: Data) throws -> (write: Data?, response: Data?) {
        guard line.count <= 262_144,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            throw AIQuotaError.malformed
        }
        guard let id = object["id"] as? Int else { return (nil, nil) } // notifications are never acted upon
        switch phase {
        case .initialize:
            guard id == 1 else { return (nil, nil) }
            guard object["error"] == nil, object["result"] != nil else { throw AIQuotaError.unavailable }
            phase = .limits
            return (Self.limits, nil)
        case .limits:
            guard id == 2 else { return (nil, nil) }
            phase = .finished
            return (nil, line)
        case .finished: return (nil, nil)
        }
    }
}

struct QuotaProcessPolicy {
    var timeout: TimeInterval = 20
    var terminationGrace: TimeInterval = 0.5
    var stdoutLimit = 1_048_576
    var stderrLimit = 65_536
}

enum QuotaCLICommand {
    case codex, agy
    var arguments: [String] {
        switch self {
        case .codex: return ["app-server"]
        case .agy: return ["--sandbox", "--print-timeout", "20s", "--print", "/usage"]
        }
    }
}

struct CodexQuotaClient {
    let executableURL: URL
    var policy = QuotaProcessPolicy()
    func read(sourceID: String, updatedAt: @escaping () -> Date = Date.init) async throws -> AIQuotaSnapshot {
        guard executableURL.isFileURL, executableURL.lastPathComponent == "codex", !sourceID.isEmpty else {
            throw AIQuotaError.unavailable
        }
        let data = try await QuotaCLIProcess.run(executableURL: executableURL, command: .codex, policy: policy)
        return try CodexQuotaParser.parse(data, accountID: sourceID, updatedAt: updatedAt())
    }
}

/// One-shot stdio only. EOF and child termination are coordinated, so a final
/// response is drained even if the child exits immediately. Await completes only
/// after our child exits (or a distinct cleanupFailed error prevents new requests).
/// Signals only target this Process instance; no name search or process-group kill.
final class QuotaCLIProcess: @unchecked Sendable {
    private static let quarantineLock = NSLock()
    private static var quarantinedSources: Set<String> = []
    private static func isQuarantined(_ url: URL) -> Bool {
        quarantineLock.lock(); defer { quarantineLock.unlock() }
        return quarantinedSources.contains(url.resolvingSymlinksInPath().path)
    }
    private static func quarantine(_ url: URL) {
        quarantineLock.lock(); defer { quarantineLock.unlock() }
        quarantinedSources.insert(url.resolvingSymlinksInPath().path)
    }
    private let queue = DispatchQueue(label: "salary.quota.cli.stdio")
    private let executableURL: URL
    private let command: QuotaCLICommand
    private let policy: QuotaProcessPolicy
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private var pendingCancel = false
    private var launched = false
    private var exited = false
    private var stdoutEOF = false
    private var completed = false
    private var outcome: Result<Data, Error>?
    private var protocolState = CodexQuotaRPC()
    private var buffer = Data()
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var deadline: DispatchWorkItem?
    private var killDeadline: DispatchWorkItem?
    private var cleanupDeadline: DispatchWorkItem?
    private var workingDirectory: URL?

    init(executableURL: URL, command: QuotaCLICommand, policy: QuotaProcessPolicy) {
        self.executableURL = executableURL; self.command = command; self.policy = policy
    }
    static func run(executableURL: URL, command: QuotaCLICommand, policy: QuotaProcessPolicy = .init()) async throws -> Data {
        guard !isQuarantined(executableURL) else { throw AIQuotaError.cleanupFailed }
        let worker = QuotaCLIProcess(executableURL: executableURL, command: command, policy: policy)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { worker.start($0) }
        } onCancel: { worker.cancel() }
    }
    func start(_ continuation: CheckedContinuation<Data, Error>) {
        queue.async {
            self.continuation = continuation
            if self.pendingCancel { self.requestFinish(.failure(CancellationError())); return }
            do {
                let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("SalaryQuota-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
                self.workingDirectory = cwd
                self.process.currentDirectoryURL = cwd
                self.process.executableURL = self.executableURL
                self.process.arguments = self.command.arguments
                self.process.standardInput = self.input
                self.process.standardOutput = self.output
                self.process.standardError = self.errors
                // Prevent EPIPE from terminating the parent if a CLI exits before a write.
                _ = fcntl(self.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                self.process.terminationHandler = { [weak self] _ in
                    self?.queue.async { [weak self] in
                        guard let self else { return }
                        self.exited = true
                        self.resolveExit()
                    }
                }
                do { try self.process.run() }
                catch { self.requestFinish(.failure(AIQuotaError.launchFailed)); return }
                self.launched = true
                try? self.output.fileHandleForWriting.close()
                try? self.errors.fileHandleForWriting.close()
                self.stdoutSource = self.makeReader(self.output.fileHandleForReading, stderr: false)
                self.stderrSource = self.makeReader(self.errors.fileHandleForReading, stderr: true)
                if self.command == .codex { try self.write(CodexQuotaRPC.initialize) }
                else { try? self.input.fileHandleForWriting.close() }
                let timeout = DispatchWorkItem { [weak self] in self?.requestFinish(.failure(AIQuotaError.timedOut)) }
                self.deadline = timeout
                self.queue.asyncAfter(deadline: .now() + self.policy.timeout, execute: timeout)
            } catch { self.requestFinish(.failure((error as? AIQuotaError) ?? .unavailable)) }
        }
    }
    private func makeReader(_ handle: FileHandle, stderr: Bool) -> DispatchSourceRead {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain(fd, stderr: stderr) }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }
    private func drain(_ fd: Int32, stderr: Bool) {
        guard !completed else { return }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        // Yield after bounded work so a flooding child cannot starve deadlines.
        for _ in 0..<16 {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 {
                if stderr { stderrSource?.cancel() }
                else { stdoutEOF = true; stdoutSource?.cancel(); resolveExit() }
                return
            }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return }
                requestFinish(.failure(AIQuotaError.pipeFailed)); return
            }
            if stderr {
                stderrBytes += count
                if stderrBytes > policy.stderrLimit { requestFinish(.failure(AIQuotaError.outputTooLarge)); return }
                // Never retain stderr or display its contents.
            } else {
                stdoutBytes += count
                if stdoutBytes > policy.stdoutLimit { requestFinish(.failure(AIQuotaError.outputTooLarge)); return }
                guard outcome == nil else { continue }
                buffer.append(contentsOf: bytes.prefix(count))
                if command == .codex { consumeRPC() }
                if outcome != nil { return }
            }
        }
    }
    private func write(_ data: Data) throws {
        let written = try data.withUnsafeBytes { raw -> Int in
            let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, raw.baseAddress, raw.count)
            if count < 0 { throw AIQuotaError.pipeFailed }
            return count
        }
        guard written == data.count else { throw AIQuotaError.pipeFailed }
    }
    private func consumeRPC() {
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            do {
                let result = try protocolState.receive(line)
                if let message = result.write { try write(message) }
                if let response = result.response { requestFinish(.success(response)); return }
            } catch { requestFinish(.failure(error)); return }
        }
        if buffer.count > 262_144 { requestFinish(.failure(AIQuotaError.outputTooLarge)) }
    }
    private func resolveExit() {
        guard exited else { return }
        if outcome != nil { complete(); return }
        // Do not race the last stdout event with terminationHandler.
        guard stdoutEOF else { return }
        if command == .codex && !buffer.isEmpty {
            buffer.append(10); consumeRPC()
            if outcome != nil { return }
        }
        if command == .agy, !buffer.isEmpty, process.terminationReason == .exit, process.terminationStatus == 0 {
            requestFinish(.success(buffer))
        } else if process.terminationReason == .uncaughtSignal {
            requestFinish(.failure(AIQuotaError.terminatedBySignal(process.terminationStatus)))
        } else if process.terminationStatus != 0 {
            requestFinish(.failure(AIQuotaError.exitedNonzero(process.terminationStatus)))
        } else if stdoutBytes == 0 {
            requestFinish(.failure(AIQuotaError.emptyOutput))
        } else { requestFinish(.failure(AIQuotaError.unavailable)) }
    }
    func cancel() {
        queue.async {
            self.pendingCancel = true
            if self.continuation != nil { self.requestFinish(.failure(CancellationError())) }
        }
    }
    private func requestFinish(_ result: Result<Data, Error>) {
        guard !completed, outcome == nil else { return }
        outcome = result
        deadline?.cancel()
        try? input.fileHandleForWriting.close()
        if !launched || exited { complete(); return }
        if process.isRunning { process.terminate() }
        let killTask = DispatchWorkItem { [self] in
            guard !completed, !exited, process.isRunning else { return }
            if Darwin.kill(process.processIdentifier, SIGKILL) != 0 && errno != ESRCH {
                outcome = .failure(AIQuotaError.cleanupFailed); complete(); return
            }
        }
        killDeadline = killTask
        queue.asyncAfter(deadline: .now() + policy.terminationGrace, execute: killTask)
        let cleanup = DispatchWorkItem { [self] in
            guard !completed else { return }
            // A kernel/process cleanup failure is distinct and disables the reader.
            outcome = .failure(AIQuotaError.cleanupFailed)
            complete()
        }
        cleanupDeadline = cleanup
        queue.asyncAfter(deadline: .now() + policy.terminationGrace + 3, execute: cleanup)
    }
    private func complete() {
        guard !completed, let outcome else { return }
        completed = true
        if case .failure(let error) = outcome, error as? AIQuotaError == .cleanupFailed {
            Self.quarantine(executableURL)
        }
        deadline?.cancel(); killDeadline?.cancel(); cleanupDeadline?.cancel()
        deadline = nil; killDeadline = nil; cleanupDeadline = nil
        stdoutSource?.cancel(); stderrSource?.cancel()
        process.terminationHandler = nil
        continuation?.resume(with: outcome); continuation = nil
        buffer.removeAll(keepingCapacity: false)
        if let workingDirectory { try? FileManager.default.removeItem(at: workingDirectory) }
    }
}
