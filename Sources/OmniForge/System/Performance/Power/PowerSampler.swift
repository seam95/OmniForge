import Foundation
import OmniForgeSMC
import IOKit
import IOKit.ps

/// Samples power without elevated privileges. System and adapter draw come from
/// SMC (`PSTR` / `PDTR`); battery flow and charger rating come from
/// AppleSmartBattery. Anything the hardware does not expose stays nil.
final class PowerSampler: PowerSampling {
    private let smc: SMCReading?
    private let maxCapacityProbe: MaxCapacityProbing
    private var batteryService: io_service_t = 0

    /// `PSTR` = System Total Power. `PDTR` = DC-In (adapter) Total Power. When
    /// only PDTR is present it is a reasonable system-power stand-in.
    private static let systemPowerKeys = ["PSTR", "PDTR"]
    private static let adapterPowerKeys = ["PDTR"]

    init(smc: SMCReading?, maxCapacityProbe: MaxCapacityProbing = MaxCapacityProbe.shared) {
        self.smc = smc
        self.maxCapacityProbe = maxCapacityProbe
    }

    deinit {
        if batteryService != 0 { IOObjectRelease(batteryService) }
    }

    func sample() throws -> PowerReading {
        var reading = PowerReading()

        if let smc {
            reading.systemWatts = Self.firstPlausibleWatts(keys: Self.systemPowerKeys, smc: smc)
            reading.adapterWatts = Self.firstPlausibleWatts(keys: Self.adapterPowerKeys, smc: smc)
        }

        if let props = batteryProperties() {
            reading.hasBattery = true
            reading.externalConnected = (props["ExternalConnected"] as? Bool) ?? false
            reading.isCharging = (props["IsCharging"] as? Bool) ?? false

            if let capacity = props["CurrentCapacity"] as? Int,
               let maxCapacity = props["MaxCapacity"] as? Int, maxCapacity > 0 {
                reading.chargePercent = Int((Double(capacity) / Double(maxCapacity) * 100).rounded())
                reading.batteryLevel = Double(capacity) / Double(maxCapacity)
            }
            if let cycles = props["CycleCount"] as? Int {
                reading.cycleCount = UInt64(cycles)
            }

            let voltageMv = (props["Voltage"] as? Int) ?? 0
            let amperageMa = (props["Amperage"] as? Int) ?? (props["InstantAmperage"] as? Int) ?? 0
            if voltageMv > 0, amperageMa != 0 {
                // Power = V × I, signed by amperage (negative while discharging).
                reading.batteryWatts = (Double(voltageMv) / 1000.0) * (Double(amperageMa) / 1000.0)
            }

            if let adapter = props["AdapterDetails"] as? [String: Any],
               let rated = adapter["Watts"] as? Int, rated > 0 {
                reading.adapterMaxWatts = Double(rated)
            }

            // 主口径：满充容量 / 设计容量，与系统信息「最大容量」一致。
            reading.healthPercent = Self.healthPercent(fromBatteryProperties: props)
            if reading.healthPercent == nil {
                // 兜底：IOPS 的 "Max Capacity" 在部分机型恒报 100，仅在
                // IORegistry 容量属性缺失时采用。
                maxCapacityProbe.refreshIfStale()
                if let exact = maxCapacityProbe.percent {
                    reading.healthPercent = Double(exact)
                }
            }

            reading.timeRemaining = BatteryTimeSupport.remainingSeconds(
                timeToEmptyMinutes: timeToEmptyMinutes(),
                externalConnected: reading.externalConnected,
                isCharging: reading.isCharging)
            reading.batteryTemperature = batteryTemperature(from: props)
        }

        // Derive a system figure when no SMC key reports one (e.g. older chips).
        if reading.systemWatts == nil {
            if reading.externalConnected, let input = reading.adapterWatts {
                reading.systemWatts = input
            } else if let flow = reading.batteryWatts, flow < 0 {
                reading.systemWatts = -flow
            }
        }

        return reading
    }

    // MARK: - SMC

    private static func firstPlausibleWatts(keys: [String], smc: SMCReading) -> Double? {
        for key in keys {
            if let watts = plausibleWatts(smc.value(forKey: key)) {
                return watts
            }
        }
        return nil
    }

    private static func plausibleWatts(_ watts: Double?) -> Double? {
        guard let watts, watts > 0, watts < 1000 else { return nil }
        return watts
    }

    // MARK: - Health

    /// 由 AppleSmartBattery 属性推电池健康百分比（0...100）。
    /// 满充容量按 NominalChargeCapacity → FullChargeCapacity → AppleRawMaxCapacity
    /// 顺序取值，除以 DesignCapacity，封顶 100。
    static func healthPercent(fromBatteryProperties props: [String: Any]) -> Double? {
        guard let design = batteryInt("DesignCapacity", in: props), design > 0 else { return nil }
        let fullCharge = batteryInt("NominalChargeCapacity", in: props)
            ?? batteryInt("FullChargeCapacity", in: props)
            ?? batteryInt("AppleRawMaxCapacity", in: props)
        guard let fullCharge, fullCharge > 0 else { return nil }
        return min(100, Double(fullCharge) / Double(design) * 100)
    }

    // MARK: - Battery IORegistry

    private func batteryProperties() -> [String: Any]? {
        let service = resolvedBatteryService()
        guard service != 0 else { return nil }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dict = properties?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dict
    }

    private func resolvedBatteryService() -> io_service_t {
        if batteryService != 0 { return batteryService }
        batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        return batteryService
    }

    private func timeToEmptyMinutes() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let minutes = Self.intValue(description[kIOPSTimeToEmptyKey]) else { continue }
            return minutes
        }
        return nil
    }

    private static func batteryInt(_ key: String, in props: [String: Any]) -> Int? {
        if let value = intValue(props[key]) { return value }
        if let batteryData = props["BatteryData"] as? [String: Any] { return intValue(batteryData[key]) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as NSNumber:
            let i64 = v.int64Value
            guard i64 >= Int64(Int.min), i64 <= Int64(Int.max) else { return nil }
            return Int(i64)
        case let v as String: return Int(v)
        default: return nil
        }
    }

    private func batteryTemperature(from props: [String: Any]) -> Double? {
        if let temp = props["Temperature"] as? Int {
            return Double(temp) / 100.0
        }
        return nil
    }
}
