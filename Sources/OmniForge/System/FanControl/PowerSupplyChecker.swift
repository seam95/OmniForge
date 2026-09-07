import Foundation
import IOKit.ps

/// 电源供应检查边界 — 协调器注入，测试用假实现
protocol PowerSupplyChecking: AnyObject {
    /// 电池供电且电量 ≤ threshold（percent 0-100）时为真；
    /// 接交流电或读不到电源信息时恒假（读不到不抑制）
    func isOnBatteryBelow(thresholdPercent threshold: Int) -> Bool
}

/// 生产实现 — IOKit 电源来源
final class PowerSupplyChecker: PowerSupplyChecking {
    func isOnBatteryBelow(thresholdPercent threshold: Int) -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let info = IOPSGetPowerSourceDescription(snapshot, first)?
                  .takeUnretainedValue() as? [String: Any] else {
            return false
        }
        let onAC = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        if onAC { return false }
        let charge = info[kIOPSCurrentCapacityKey] as? Int ?? 100
        return charge <= threshold
    }
}
