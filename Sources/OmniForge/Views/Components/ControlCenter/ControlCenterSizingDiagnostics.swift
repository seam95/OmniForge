import Foundation

/// 控制中心尺寸管线诊断日志（临时，真机验收通过后移除）。
/// 双通道：stdout（终端启动可见）+ /tmp/omniforge-sizing.log（Finder/服务
/// 启动时可查）。查看：`tail -f /tmp/omniforge-sizing.log`。
enum ControlCenterSizingLog {
    private static let filePath = "/tmp/omniforge-sizing.log"

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "[\(formatter.string(from: Date()))] [cc-sizing] \(message)"
        print(line)
        let url = URL(fileURLWithPath: filePath)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }
}
