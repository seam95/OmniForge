import Foundation

/// 对应 CLI 运行中检测（SPEC 2.7 增强：检测到运行中的 claude/codex 时，
/// 切换后多一句「需重启才生效」提醒）。
protocol RunningProcessDetecting: AnyObject {
    func isRunning(tool: ProviderTool) -> Bool
}

/// 默认实现：`/bin/ps -axo comm=` 匹配进程名（claude / codex）。
final class RunningProcessDetector: RunningProcessDetecting {
    static func processName(for tool: ProviderTool) -> String {
        switch tool {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    func isRunning(tool: ProviderTool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        let name = Self.processName(for: tool)
        return output.split(separator: "\n").contains { line in
            let lastComponent = line.split(separator: "/").last.map(String.init) ?? ""
            return lastComponent == name
        }
    }
}
