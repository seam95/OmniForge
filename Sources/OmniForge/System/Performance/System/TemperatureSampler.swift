import Foundation
import OmniForgeSMC

final class TemperatureSampler: TemperatureSampling {
    private let smc: SMCReading?
    private let hidReader: HIDTemperatureReading?
    private let platform: CPUTemperaturePlatform

    init(
        smc: SMCReading? = nil,
        hidReader: HIDTemperatureReading? = nil,
        platform: CPUTemperaturePlatform = TemperatureSensorSelector.currentPlatform()
    ) {
        self.smc = smc
        self.hidReader = hidReader
        self.platform = platform
    }

    func sampleCPU() throws -> Double? {
        if let hidReader, let value = hidReader.sampleCPU() {
            return value
        }
        guard smc != nil else { return nil }

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
        if let hidReader, let value = hidReader.sampleGPU() {
            return value
        }
        guard let smc else { return nil }
        return TemperatureSensorSelector.gpuTemperature(from: smc)
    }

    func sampleBattery() throws -> Double? {
        if let hidReader, let value = hidReader.sampleBattery() {
            return value
        }
        guard let smc else { return nil }
        return TemperatureSensorSelector.batteryTemperature(from: smc)
    }

    private func collectReadings(keys: [String]) -> [(key: String, value: Double)] {
        guard let smc else { return [] }
        return keys.compactMap { key -> (key: String, value: Double)? in
            guard let value = smc.value(forKey: key) else { return nil }
            return (key, value)
        }
    }
}
