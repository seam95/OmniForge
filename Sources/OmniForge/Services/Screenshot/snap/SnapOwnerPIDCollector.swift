import CoreGraphics
import Foundation

/// 从 `CGWindowListCopyWindowInfo` 条目提取吸附 hit-test 用的 owner pid 集合。
///
/// 不做 `layer == 0` 硬过滤:Dock / 菜单栏 / 状态项等系统 UI 的 layer 非 0,
/// 过滤后会导致这些目标永远无法被 AX 命中。
enum SnapOwnerPIDCollector {
    /// - Parameters:
    ///   - entries: 窗口列表字典条目。
    ///   - excludingPID: 始终剔除的 pid(通常为本 app,避免命中 overlay)。
    /// - Returns: 去重后的 pid 列表(顺序不稳定,调用方应按集合语义使用)。
    static func collect(
        from entries: [[String: Any]],
        excludingPID: pid_t
    ) -> [pid_t] {
        var pids = Set<pid_t>()
        for entry in entries {
            guard let pid = ownerPID(from: entry), pid != excludingPID else { continue }
            pids.insert(pid)
        }
        return Array(pids)
    }

    private static func ownerPID(from entry: [String: Any]) -> pid_t? {
        if let pid = entry[kCGWindowOwnerPID as String] as? pid_t {
            return pid
        }
        if let number = entry[kCGWindowOwnerPID as String] as? NSNumber {
            return number.int32Value
        }
        return nil
    }
}
