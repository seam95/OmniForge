import XCTest
@testable import OmniForge

final class MonitorCardModelBuilderTests: XCTestCase {
    func test_cpuCard_formatsUsageAndTemp() {
        var snap = SystemSnapshot()
        snap.cpuUsage = 0.42
        snap.cpuTemperature = 48
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.zhHans,
            temperatureUnit: .celsius
        )
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.primaryText, "42%")
        XCTAssertNotNil(cpu?.secondaryText)
        XCTAssertEqual(cpu?.processMetricKind, .cpu)
    }

    func test_diskCard_mergesCapacityAndIO() {
        var snap = SystemSnapshot()
        snap.disk = DiskReading(
            devices: [],
            physicalDisks: [],
            readBytesPerSec: 1_000_000,
            writeBytesPerSec: 500_000,
            totalRead: 0,
            totalWritten: 0,
            freeSpace: 50_000_000_000,
            totalSpace: 100_000_000_000
        )
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let disk = models.first { $0.id == .disk }
        XCTAssertNotNil(disk)
        XCTAssertEqual(disk?.primaryText, MetricFormat.diskBytes(50_000_000_000))
        XCTAssertEqual(disk?.progress ?? -1, 0.5, accuracy: 0.0001)
        let sep = Strings.en.monitorSubtitleSeparator
        let read = MetricFormat.bytesPerSec(1_000_000 as Double) ?? "--"
        let write = MetricFormat.bytesPerSec(500_000 as Double) ?? "--"
        XCTAssertEqual(disk?.secondaryText, "↓ \(read) \(sep) ↑ \(write)")
        XCTAssertNil(disk?.processMetricKind)
        XCTAssertTrue(disk?.opensDiskDetail == true)
    }

    func test_diskCard_usesPlaceholderRatesWhenMissing() {
        var snap = SystemSnapshot()
        snap.disk = DiskReading(
            devices: [],
            physicalDisks: [],
            readBytesPerSec: 0,
            writeBytesPerSec: 0,
            totalRead: 0,
            totalWritten: 0,
            freeSpace: 50_000_000_000,
            totalSpace: nil
        )
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let disk = models.first { $0.id == .disk }
        XCTAssertEqual(disk?.primaryText, MetricFormat.diskBytes(50_000_000_000))
        let sep = Strings.en.monitorSubtitleSeparator
        // 0 / 缺失速率用 --
        XCTAssertEqual(disk?.secondaryText, "↓ -- \(sep) ↑ --")
        XCTAssertNil(disk?.progress)
        XCTAssertTrue(disk?.opensDiskDetail == true)
    }

    func test_batteryCard_emptyWhenNoPowerData() {
        var snap = SystemSnapshot()
        snap.power = nil
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.primaryText, Strings.en.monitorNoPowerData)
        XCTAssertNil(battery?.progress)
        XCTAssertNil(battery?.processMetricKind)
    }

    func test_batteryCard_emptyWhenNoBattery() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = false
        snap.power = power
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.primaryText, Strings.en.monitorNoPowerData)
    }

    func test_batteryCard_includesTimeRemainingInSecondary() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = true
        power.batteryLevel = 0.55
        power.isCharging = false
        power.timeRemaining = 90 * 60
        snap.power = power
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.primaryText, MetricFormat.batteryLevel(0.55))
        XCTAssertEqual(
            battery?.secondaryText,
            "\(Strings.en.monitorMetricRemaining) 90 min"
        )
    }

    func test_memoryPressureFallback_usesLocalizedStrings() {
        var snap = SystemSnapshot()
        // used/total missing so secondary falls back to pressure label
        snap.memoryUsed = nil
        snap.memoryTotal = nil
        snap.memoryPressure = .warning
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.zhHans,
            temperatureUnit: .celsius
        )
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, "--")
        XCTAssertEqual(memory?.secondaryText, Strings.zhHans.monitorPressureWarning)
    }

    func test_memoryCard_primaryShortMemory_secondaryPressure() {
        var snap = SystemSnapshot()
        snap.memoryUsed = 4_000_000_000
        snap.memoryTotal = 8_000_000_000
        snap.memoryPressure = .warning
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, MetricFormat.shortMemory(4_000_000_000, total: 8_000_000_000))
        XCTAssertEqual(memory?.secondaryText, Strings.en.monitorPressureWarning)
        XCTAssertEqual(memory?.progress ?? -1, 0.5, accuracy: 0.0001)
    }

    func test_memoryCard_unknownPressureOmitsSecondary() {
        var snap = SystemSnapshot()
        snap.memoryUsed = 1_000_000_000
        snap.memoryTotal = 8_000_000_000
        snap.memoryPressure = .unknown
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, MetricFormat.shortMemory(1_000_000_000, total: 8_000_000_000))
        XCTAssertNil(memory?.secondaryText)
    }

    func test_batteryCard_includesTemperatureInSecondary() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = true
        power.batteryLevel = 0.80
        power.isCharging = true
        power.batteryTemperature = 33.0
        snap.power = power
        snap.batteryTemperature = 34.0 // snapshot channel preferred when present
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.primaryText, MetricFormat.batteryLevel(0.80))
        XCTAssertTrue(battery?.secondaryText?.contains(Strings.en.monitorMetricCharging) == true)
        XCTAssertTrue(battery?.secondaryText?.contains(MetricFormat.temperature(34.0, unit: .celsius)!) == true)
    }

    func test_networkCard_ratesPrimaryAndCumulativeSecondary() {
        var snap = SystemSnapshot()
        snap.netDownBytesPerSec = 1_500
        snap.netUpBytesPerSec = 500
        snap.netTotalDown = 1_048_576
        snap.netTotalUp = 2_097_152
        let models = MonitorCardModelBuilder.models(
            snapshot: snap,
            configuration: MonitorConfiguration(),
            strings: Strings.en,
            temperatureUnit: .celsius
        )
        let network = models.first { $0.id == .network }
        let sep = Strings.en.monitorSubtitleSeparator
        let down = MetricFormat.bytesPerSec(1_500 as Double)
        let up = MetricFormat.bytesPerSec(500 as Double)
        XCTAssertEqual(network?.primaryText, "↓ \(down) \(sep) ↑ \(up)")
        // Σ 前缀区分累计，避免与 primary 速率行结构相同
        let totalDown = MetricFormat.bytes(1_048_576 as UInt64)
        let totalUp = MetricFormat.bytes(2_097_152 as UInt64)
        XCTAssertEqual(network?.secondaryText, "Σ ↓ \(totalDown) \(sep) ↑ \(totalUp)")
    }
}
