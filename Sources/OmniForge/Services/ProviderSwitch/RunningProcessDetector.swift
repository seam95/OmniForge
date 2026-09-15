import Foundation

/// 对应 CLI 运行中检测（SPEC 2.7 增强：检测到运行中的 claude/codex 时，
/// 切换后多一句「需重启才生效」提醒）。
protocol RunningProcessDetecting: AnyObject {
    func isRunning(tool: ProviderTool) async -> Bool
}

/// 默认实现：`/bin/ps -axo comm=` 匹配进程名（claude / codex）。
/// 经有界进程边界异步执行：不再同步阻塞主线程，也不因输出超管道容量死锁。
final class RunningProcessDetector: RunningProcessDetecting {
    static func processName(for tool: ProviderTool) -> String {
        switch tool {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    func isRunning(tool: ProviderTool) async -> Bool {
        guard let result = try? await BoundedProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "comm="]
        ) else {
            return false
        }
        let name = Self.processName(for: tool)
        return result.stdout.split(separator: "\n").contains { line in
            let lastComponent = line.split(separator: "/").last.map(String.init) ?? ""
            return lastComponent == name
        }
    }
}
