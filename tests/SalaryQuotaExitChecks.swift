import Foundation
import Darwin

@main struct SalaryQuotaExitChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("salary-exit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let helper = URL(fileURLWithPath: CommandLine.arguments[2])
        for mode in ["direct", "pause"] {
            let dir = root.appendingPathComponent("cancel-ignore-term-" + mode)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cli = dir.appendingPathComponent("codex")
            try FileManager.default.copyItem(at: fixture, to: cli)
            let parent = Process()
            parent.executableURL = helper
            parent.arguments = [cli.path, mode]
            try parent.run()
            parent.waitUntilExit()
            let pidFile = dir.appendingPathComponent("pid.txt")
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) else { fatalError("fixture did not launch") }
            let gone = kill(pid, 0) == -1 && errno == ESRCH
            if !gone { _ = kill(pid, SIGKILL) } // only the owned fixture PID
            precondition(parent.terminationStatus == 0 && gone, "owned fake CLI survived parent exit: \(mode)")
        }
        print("SalaryQuotaExitChecks: 2 parent-process exit scenarios passed (direct and pause-first); SIGTERM-ignoring fake child absent")
    }
}
