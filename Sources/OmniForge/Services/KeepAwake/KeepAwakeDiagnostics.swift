import Foundation
import os

/// 保持唤醒诊断日志。统一走 os.Logger + stdout，便于 Console.app 与终端抓取。
///
/// Console.app 过滤：
///   subsystem:com.omniforge.app category:KeepAwake
/// 或消息前缀：`[KeepAwake]`
enum KeepAwakeDiagnostics {
    static let logger = Logger(subsystem: "com.omniforge.app", category: "KeepAwake")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        print("[KeepAwake] \(message)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        print("[KeepAwake][WARN] \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        print("[KeepAwake][ERROR] \(message)")
    }

    /// 墙钟 + 系统 uptime 快照，用于对照睡眠是否冻结 DispatchTime。
    static func timeSnapshot(clockNow: Date? = nil) -> String {
        let wall = clockNow ?? Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wallText = formatter.string(from: wall)
        let uptime = ProcessInfo.processInfo.systemUptime
        return "wall=\(wallText) uptime=\(String(format: "%.3f", uptime))s"
    }

    static func describeSession(_ state: KeepAwakeSessionState, now: Date) -> String {
        switch state {
        case .inactive:
            return "inactive"
        case .activating:
            return "activating"
        case .active(let endDate):
            if let endDate {
                let remaining = endDate.timeIntervalSince(now)
                return "active(end=\(endDate.timeIntervalSince1970), remaining=\(String(format: "%.1f", remaining))s, expired=\(remaining <= 0))"
            }
            return "active(indefinite)"
        case .deactivating:
            return "deactivating"
        case .cleanupRequired(let residual, let error):
            return "cleanupRequired(residual=\(residual.rawValue), error=\(error))"
        }
    }
}
