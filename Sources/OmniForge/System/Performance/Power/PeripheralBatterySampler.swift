import Foundation
import IOKit

final class PeripheralBatterySampler: PeripheralBatterySampling {
    init() {}

    func sample(now: TimeInterval) throws -> [PeripheralBatteryDevice] {
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess else {
            throw MetricSamplingError.systemCall("peripheral battery lookup failed")
        }
        defer { IOObjectRelease(iterator) }

        var devices: [PeripheralBatteryDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                let isCharging = (IORegistryEntryCreateCFProperty(service, "BatteryCharging" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) ?? false
                devices.append(PeripheralBatteryDevice(
                    id: "\(service)-\(name)",
                    name: name,
                    level: Double(percent) / 100.0,
                    isCharging: isCharging
                ))
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return devices
    }
}
