import Foundation
import AppKit

@main struct SalaryQuotaExitHelper {
    @MainActor static func main() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let pauseFirst = CommandLine.arguments[2] == "pause"
        let manager = AIQuotaConnections()
        try manager.select(.codex, url: executable)
        manager.setVisible(true)
        let request = Task { try await manager.connect(.codex) }
        let pid = executable.deletingLastPathComponent().appendingPathComponent("pid.txt")
        for _ in 0..<400 {
            if FileManager.default.fileExists(atPath: pid.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard FileManager.default.fileExists(atPath: pid.path) else { throw AIQuotaError.timedOut }
        // Let the owned fixture install its SIGTERM-ignore handler.
        try await Task.sleep(for: .milliseconds(100))
        if pauseFirst { manager.setPaused(true) }
        await manager.shutdownAndWait()
        // Do not await the original request here: shutdown itself must drain it.
        _ = request
    }
}
