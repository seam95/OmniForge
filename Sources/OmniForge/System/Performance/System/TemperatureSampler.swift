import Foundation

final class TemperatureSampler: TemperatureSampling {
    private let smc: SMCReading
    private let platform: CPUTemperaturePlatform

    init(smc: SMCReading, platform: CPUTemperaturePlatform = TemperatureSensorSelector.currentPlatform()) {
        self.smc = smc
        self.platform = platform
    }

    func sampleCPU() throws -> Double? {
        // Prefer platform core keys, then fall back to remaining known CPU keys.
        let preferred = TemperatureSensorSelector.knownCPUKeys.filter {
            TemperatureSensorSelector.isCPUCoreKey($0, platform: platform)
        }
        let preferredNames = Set(preferred)
        let fallback = TemperatureSensorSelector.knownCPUKeys.filter { !preferredNames.contains($0) }

        var readings = collectReadings(keys: preferred)
        if let value = TemperatureSensorSelector.displayedCPUTemperature(readings: readings, platform: platform) {
            return value
        }
        readings += collectReadings(keys: fallback)
        return TemperatureSensorSelector.displayedCPUTemperature(readings: readings, platform: platform)
    }

    func sampleGPU() throws -> Double? {
        TemperatureSensorSelector.gpuTemperature(from: smc)
    }

    func sampleBattery() throws -> Double? {
        TemperatureSensorSelector.batteryTemperature(from: smc)
    }

    private func collectReadings(keys: [String]) -> [(key: String, value: Double)] {
        keys.compactMap { key -> (key: String, value: Double)? in
            guard let value = smc.value(forKey: key) else { return nil }
            return (key, value)
        }
    }
}
