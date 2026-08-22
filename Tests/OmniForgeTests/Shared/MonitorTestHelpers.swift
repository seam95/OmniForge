import XCTest
import Combine
@testable import OmniForge

// MARK: - System Monitor Test Helpers

@MainActor
func makeFakeMonitor() -> SystemMonitorManager {
    SystemMonitorManager(
        scheduler: TestRepeatingScheduler(),
        cpuSampler: TestCPUSampler(),
        gpuSampler: TestGPUSampler(),
        memorySampler: TestMemorySampler(),
        temperatureSampler: TestTemperatureSampler(),
        networkSampler: TestNetworkSampler(),
        diskSampler: TestDiskSampler(),
        powerSampler: TestPowerSampler(),
        peripheralBatterySampler: TestPeripheralBatterySampler(),
        processSampler: TestProcessUsageSampler()
    )
}

final class TestRepeatingScheduler: RepeatingScheduling {
    func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable { AnyCancellable {} }
}

final class FakeAlertNotifier: MonitorNotificationClient {
    func requestAuthorization(completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
    func post(title: String, body: String, completion: @escaping (Result<Void, Error>) -> Void) { completion(.success(())) }
}

final class TestCPUSampler: CPUUsageSampling {
    func sample() throws -> CPUUsageReading? { nil }
}
final class TestGPUSampler: GPUUsageSampling {
    func sample() throws -> Double? { nil }
}
final class TestMemorySampler: MemorySampling {
    func sample() throws -> MemoryReading { MemoryReading(used: 0, total: 8_000_000_000, pressure: .normal) }
}
final class TestTemperatureSampler: TemperatureSampling {
    func sampleCPU() throws -> Double? { 25 }
    func sampleGPU() throws -> Double? { 25 }
    func sampleBattery() throws -> Double? { 25 }
}
final class TestNetworkSampler: NetworkSampling {
    func sample(now: TimeInterval) throws -> NetworkReading { NetworkReading(downBytesPerSec: 0, upBytesPerSec: 0, totalDown: 0, totalUp: 0) }
}
final class TestDiskSampler: DiskSampling {
    func sample(now: TimeInterval, refreshMetadata: Bool) throws -> DiskReading { DiskReading(readBytesPerSec: 0, writeBytesPerSec: 0, totalRead: 0, totalWritten: 0, freeSpace: nil, totalSpace: nil) }
}
final class TestPowerSampler: PowerSampling {
    func sample() throws -> PowerReading {
        PowerReading(
            isCharging: false,
            chargePercent: nil,
            batteryLevel: nil,
            cycleCount: nil,
            healthPercent: nil,
            timeRemaining: nil,
            batteryWatts: nil,
            adapterWatts: nil,
            adapterMaxWatts: nil,
            systemWatts: nil,
            externalConnected: false,
            hasBattery: false,
            batteryTemperature: nil
        )
    }
}
final class TestPeripheralBatterySampler: PeripheralBatterySampling {
    func sample(now: TimeInterval) throws -> [PeripheralBatteryDevice] { [] }
}
final class TestProcessUsageSampler: ProcessUsageSampling {
    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage] { [] }
    func stop(_ kind: ProcessMetricKind) {}
}
