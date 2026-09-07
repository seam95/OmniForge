import Foundation

/// 指标格式化工具
/// 对不可用输入返回 nil，由调用者生成 MetricIssue；不得返回伪造数值
enum MetricFormat {
    // MARK: Memory

    /// Matches Activity Monitor's "Memory Used": physical RAM minus pages that
    /// are free, speculative, or file-backed cache.
    static func memoryUsed(totalBytes: UInt64,
                           pageSize: UInt64,
                           freePages: UInt64,
                           speculativePages: UInt64,
                           fileBackedPages: UInt64) -> UInt64 {
        guard totalBytes > 0, pageSize > 0 else { return 0 }
        let freeAndSpeculative = freePages.addingReportingOverflow(speculativePages)
        guard !freeAndSpeculative.overflow else { return 0 }
        let availablePages = freeAndSpeculative.partialValue.addingReportingOverflow(fileBackedPages)
        guard !availablePages.overflow else { return 0 }
        let availableBytes = availablePages.partialValue.multipliedReportingOverflow(by: pageSize)
        guard !availableBytes.overflow else { return 0 }
        return availableBytes.partialValue >= totalBytes ? 0 : totalBytes - availableBytes.partialValue
    }

    // MARK: GPU

    /// Smooths the GPU usage readout enough to hide one-sample compositor spikes
    /// without hiding sustained load.
    static func stabilizedGPUUsage(previous: Double?, current: Double) -> Double {
        let value = current.isFinite ? max(0, min(1, current)) : 0
        guard let previous, previous.isFinite else { return value }
        let baseline = max(0, min(1, previous))
        if value > baseline {
            return min(value, baseline + 0.20)
        }
        return baseline * 0.35 + value * 0.65
    }

    // MARK: Formatting

    static func percent(_ value: Double?) -> String? {
        guard let value else { return nil }
        return "\(Int((value * 100).rounded()))%"
    }

    /// Splits a byte count into a human value + unit, base-1024.
    static func scale(_ bytes: Double) -> (value: Double, unit: String) {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return (value, units[index])
    }

    /// Bytes (raw) → "0", "8" for B; one decimal under 10, none at or above.
    private static func number(_ value: Double, unit: String) -> String {
        if unit == "B" { return String(format: "%.0f", value) }
        return value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    static func bytes(_ value: UInt64) -> String {
        let (scaled, unit) = scale(Double(value))
        return "\(number(scaled, unit: unit)) \(unit)"
    }

    /// Optional wrapper for unavailable samples. Disfavored so non-optional
    /// call sites resolve to the `String` overload without ambiguity.
    @_disfavoredOverload
    static func bytes(_ value: UInt64?) -> String? {
        guard let value else { return nil }
        return bytes(value)
    }

    static func bytesPerSec(_ value: Double) -> String {
        let (scaled, unit) = scale(value)
        return "\(number(scaled, unit: unit)) \(unit)/s"
    }

    /// Optional wrapper for unavailable samples. Disfavored so non-optional
    /// call sites resolve to the `String` overload without ambiguity.
    @_disfavoredOverload
    static func bytesPerSec(_ value: Double?) -> String? {
        guard let value else { return nil }
        return bytesPerSec(value)
    }

    /// Disk capacity formatting, base-1000 (decimal SI units).
    static func diskBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, Double(bytes))
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if units[index] == "B" {
            return String(format: "%.0f B", value)
        }
        return value < 10 ? String(format: "%.1f %@", value, units[index])
            : String(format: "%.0f %@", value, units[index])
    }

    /// Disk capacity with extra precision for TB/PB.
    static func diskBytesPrecise(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = max(0, Double(bytes))
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let unit = units[index]
        if unit == "B" {
            return String(format: "%.0f B", value)
        }
        if unit == "TB" || unit == "PB" {
            return String(format: "%.2f %@", value, unit)
        }
        return value < 10 ? String(format: "%.1f %@", value, unit)
            : String(format: "%.0f %@", value, unit)
    }

    static func celsius(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.0f°", value)
    }

    static func fahrenheit(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.0f°F", value * 9 / 5 + 32)
    }

    static func batteryLevel(_ value: Double?) -> String? {
        guard let value else { return nil }
        return "\(Int((value * 100).rounded()))%"
    }

    // MARK: Fan

    /// 风扇转速 — 取整不加分隔符（菜单栏等宽字体下位数即宽度，无千分位最稳）
    static func rpm(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        return "\(Int(value.rounded()))"
    }

    /// 多风扇单行拼接（如 "3200/3400"）；与外设电池块同构，宽度受位数高水位约束
    static func rpmJoined(_ values: [Double]) -> String? {
        let parts = values.compactMap { rpm($0) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    static func memory(_ used: UInt64?, total: UInt64?) -> String? {
        guard let used, let total else { return nil }
        let pct = Double(used) / Double(total) * 100
        return String(format: "%.0f%%", pct)
    }

    static func shortMemory(_ used: UInt64?, total: UInt64?) -> String? {
        guard let used, let total else { return nil }
        return "\(bytes(used)) / \(bytes(total))"
    }

    /// 内存 caption：`"13.0 / 16 GB"` — used 仅数值（主值已带单位，caption 从简），total 带单位。base-1024。
    static func shortMemoryPair(used: UInt64?, total: UInt64?) -> String? {
        guard let used, let total else { return nil }
        let (usedValue, _) = scale(Double(used))
        return String(format: "%.1f / %@", usedValue, bytes(total))
    }

    /// 大数字旁的内存已用量短格式：`"13.3 GB"` — 始终一位小数带单位。
    /// 与 `bytes(_:)` 的区别：≥10 也保留小数，跟住设计稿次要文本的精度。
    static func memoryUsedShort(_ used: UInt64?) -> String? {
        guard let used else { return nil }
        let (value, unit) = scale(Double(used))
        return String(format: "%.1f %@", value, unit)
    }

    static func temperature(_ value: Double?, unit: TemperatureUnit) -> String? {
        switch unit {
        case .celsius: return celsius(value)
        case .fahrenheit: return fahrenheit(value)
        }
    }
}

// MARK: - 计数结构体

struct NetworkCounters: Equatable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
}

struct DiskIOCounters: Equatable {
    var read: UInt64 = 0
    var written: UInt64 = 0
}

// MARK: - 网络和磁盘速率

extension MetricFormat {
    static func netSpeed(previous: NetworkCounters,
                         current: NetworkCounters,
                         elapsed: Double) -> (down: Double, up: Double) {
        guard elapsed > 0 else { return (0, 0) }
        let down = current.received >= previous.received
            ? Double(current.received - previous.received) / elapsed : 0
        let up = current.sent >= previous.sent
            ? Double(current.sent - previous.sent) / elapsed : 0
        return (down, up)
    }

    static func diskSpeed(previous: DiskIOCounters,
                          current: DiskIOCounters,
                          elapsed: Double) -> (read: Double, write: Double) {
        guard elapsed > 0 else { return (0, 0) }
        let read = current.read >= previous.read
            ? Double(current.read - previous.read) / elapsed : 0
        let write = current.written >= previous.written
            ? Double(current.written - previous.written) / elapsed : 0
        return (read, write)
    }

    /// 物理网络接口过滤：排除 lo/gif/awdl/utun/bridge 等虚拟接口
    static func includeNetworkInterface(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let excluded = ["lo", "gif", "stf", "awdl", "llw", "nan",
                        "utun", "bridge", "ap", "anpi", "p2p",
                        "XHC", "vmenet", "tap", "tun"]
        return !excluded.contains { name.hasPrefix($0) }
    }
}
