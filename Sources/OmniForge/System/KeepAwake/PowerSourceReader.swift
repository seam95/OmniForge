import Foundation
import IOKit.ps

/// 轻量电源快照；不依赖 System Monitor / SMC。
struct KeepAwakePowerSnapshot: Equatable {
    let hasBattery: Bool
    let isOnBattery: Bool
    let percentage: Int?
}

/// 可注入的 IOPowerSources 读取边界。
protocol KeepAwakePowerSourceProviding: AnyObject {
    /// 返回原始电源信息字典列表；系统 API 失败时返回 nil。
    func copyPowerSourceDictionaries() -> [[String: Any]]?
}

final class LiveKeepAwakePowerSourceProvider: KeepAwakePowerSourceProviding {
    func copyPowerSourceDictionaries() -> [[String: Any]]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return nil
        }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return []
        }
        var result: [[String: Any]] = []
        for source in list {
            if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] {
                result.append(desc)
            }
        }
        return result
    }
}

protocol KeepAwakePowerSourceReading: AnyObject {
    func read() throws -> KeepAwakePowerSnapshot
}

/// 独立轻量电源读取器。
final class PowerSourceReader: KeepAwakePowerSourceReading {
    private let provider: KeepAwakePowerSourceProviding

    init(provider: KeepAwakePowerSourceProviding = LiveKeepAwakePowerSourceProvider()) {
        self.provider = provider
    }

    func read() throws -> KeepAwakePowerSnapshot {
        guard let sources = provider.copyPowerSourceDictionaries() else {
            throw KeepAwakeError.batteryReadFailed("IOPSCopyPowerSourcesInfo failed")
        }

        // 无电源描述：视为无电池设备（如台式）。
        guard let battery = sources.first(where: { isBatterySource($0) }) else {
            return KeepAwakePowerSnapshot(hasBattery: false, isOnBattery: false, percentage: nil)
        }

        let percentage = try parsePercentage(battery)
        let powerSourceState = battery[kIOPSPowerSourceStateKey as String] as? String
        let isOnBattery = powerSourceState == (kIOPSBatteryPowerValue as String)
        return KeepAwakePowerSnapshot(
            hasBattery: true,
            isOnBattery: isOnBattery,
            percentage: percentage
        )
    }

    /// 低电量触发判定：有电池 + 在用电池 + 阈值非 0 + 电量 ≤ 阈值。
    static func shouldEndForLowBattery(
        snapshot: KeepAwakePowerSnapshot,
        limit: KeepAwakeBatteryLimit
    ) -> Bool {
        guard !limit.isDisabled else { return false }
        guard snapshot.hasBattery, snapshot.isOnBattery else { return false }
        guard let percentage = snapshot.percentage else { return false }
        return percentage <= limit.percent
    }

    private func isBatterySource(_ dict: [String: Any]) -> Bool {
        if let type = dict[kIOPSTypeKey as String] as? String {
            return type == (kIOPSInternalBatteryType as String)
        }
        // 部分系统描述缺少 Type，但带 Current Capacity。
        return dict[kIOPSCurrentCapacityKey as String] != nil
            && dict[kIOPSMaxCapacityKey as String] != nil
    }

    private func parsePercentage(_ dict: [String: Any]) throws -> Int {
        // 优先使用 0–100 的 Current Capacity（现代 macOS 常见）。
        if let current = intValue(dict[kIOPSCurrentCapacityKey as String]),
           let max = intValue(dict[kIOPSMaxCapacityKey as String]) {
            if max == 100, (0...100).contains(current) {
                return current
            }
            if max > 0 {
                let percent = Int((Double(current) / Double(max) * 100).rounded())
                guard (0...100).contains(percent) else {
                    throw KeepAwakeError.batteryReadFailed("percentage out of range: \(percent)")
                }
                return percent
            }
        }
        throw KeepAwakeError.batteryReadFailed("missing or invalid capacity fields")
    }

    private func intValue(_ any: Any?) -> Int? {
        switch any {
        case let v as Int: return v
        case let v as NSNumber: return v.intValue
        default: return nil
        }
    }
}
