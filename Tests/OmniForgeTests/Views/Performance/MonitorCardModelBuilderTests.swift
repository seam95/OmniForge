import XCTest
@testable import OmniForge

final class MonitorCardModelBuilderTests: XCTestCase {
    private func build(
        _ snapshot: SystemSnapshot,
        strings: Strings = .en,
        history: MetricHistory = MetricHistory()
    ) -> [MonitorCardModel] {
        MonitorCardModelBuilder.models(
            snapshot: snapshot,
            configuration: MonitorConfiguration(),
            strings: strings,
            temperatureUnit: .celsius,
            history: history
        )
    }

    // MARK: - CPU

    func test_cpuCard_formatsTotalAndSplitCaption() {
        var snap = SystemSnapshot()
        snap.cpuUsage = CPUUsageReading(total: 0.42, user: 0.30, system: 0.12)
        let models = build(snap, strings: .zhHans)
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.primaryText, "42%")
        XCTAssertEqual(cpu?.secondaryText, "系统 12% • 用户 30%")
        XCTAssertEqual(cpu?.processMetricKind, .cpu)
    }

    func test_cpuCard_injectsTrendFromHistory() {
        var snap = SystemSnapshot()
        snap.cpuUsage = CPUUsageReading(total: 0.5, user: 0.3, system: 0.2)
        var history = MetricHistory()
        history.append(snap)
        history.append(snap)
        let models = build(snap, history: history)
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.trend, [0.5, 0.5])
    }

    func test_cpuCard_missingReadingShowsPlaceholders() {
        let models = build(SystemSnapshot(), strings: .en)
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.primaryText, "--")
        XCTAssertNil(cpu?.secondaryText)
    }

    // MARK: - Memory

    func test_memoryCard_percentPrimaryAndPairCaption() {
        var snap = SystemSnapshot()
        snap.memoryUsed = 4_000_000_000
        snap.memoryTotal = 8_000_000_000
        snap.memoryPressure = .warning
        let models = build(snap, strings: .en)
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, "50%")
        let sep = Strings.en.monitorSubtitleSeparator
        XCTAssertEqual(
            memory?.secondaryText,
            "\(MetricFormat.shortMemoryPair(used: 4_000_000_000, total: 8_000_000_000)!) \(sep) \(Strings.en.monitorPressureWarning)"
        )
        XCTAssertEqual(memory?.progress ?? -1, 0.5, accuracy: 0.0001)
    }

    func test_memoryCard_unknownPressureOmitsSuffix() {
        var snap = SystemSnapshot()
        snap.memoryUsed = 4_000_000_000
        snap.memoryTotal = 8_000_000_000
        snap.memoryPressure = .unknown
        let models = build(snap, strings: .en)
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(
            memory?.secondaryText,
            MetricFormat.shortMemoryPair(used: 4_000_000_000, total: 8_000_000_000)
        )
    }

    func test_memoryCard_missingValuesFallsBackToPlaceholders() {
        var snap = SystemSnapshot()
        snap.memoryUsed = nil
        snap.memoryTotal = nil
        snap.memoryPressure = .warning
        let models = build(snap, strings: .zhHans)
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, "--")
        XCTAssertEqual(memory?.secondaryText, Strings.zhHans.monitorPressureWarning)
        XCTAssertNil(memory?.progress)
    }

    // MARK: - Battery

    func test_batteryCard_emptyWhenNoBattery() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = false
        snap.power = power
        let models = build(snap, strings: .en)
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.primaryText, Strings.en.monitorNoPowerData)
        XCTAssertNil(battery?.progress)
        XCTAssertNil(battery?.processMetricKind)
    }

    func test_batteryCard_primaryLevelAndTemperature() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = true
        power.batteryLevel = 1.0
        power.batteryTemperature = 34.0
        snap.power = power
        snap.batteryTemperature = 34.0
        let models = build(snap, strings: .en)
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.primaryText, "100% • 34°")
    }

    func test_batteryCard_captionPowerSourceHealthWatts() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = true
        power.batteryLevel = 0.55
        power.isCharging = true
        power.healthPercent = 90
        power.batteryWatts = 12.4
        snap.power = power
        let models = build(snap, strings: .en)
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.secondaryText, "Power Adapter • Health 90% • 12.4 W")
        XCTAssertEqual(battery?.processMetricKind, nil)
    }

    func test_batteryCard_onBatteryCaptionWhenDischarging() {
        var snap = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = true
        power.batteryLevel = 0.5
        power.isCharging = false
        power.externalConnected = false
        snap.power = power
        let models = build(snap, strings: .zhHans)
        let battery = models.first { $0.id == .battery }
        XCTAssertEqual(battery?.secondaryText, "使用电池")
    }

    // MARK: - GPU

    func test_gpuCard_primaryPercentAndTemperature() {
        var snap = SystemSnapshot()
        snap.gpuUsage = 0.46
        snap.gpuTemperature = 63
        let models = build(snap, strings: .zhHans)
        let gpu = models.first { $0.id == .gpu }
        XCTAssertEqual(gpu?.primaryText, "46% • 63°")
        XCTAssertNil(gpu?.secondaryText)
        XCTAssertEqual(gpu?.processMetricKind, .gpu)
    }

    func test_gpuCard_injectsTrendFromHistory() {
        var snap = SystemSnapshot()
        snap.gpuUsage = 0.4
        var history = MetricHistory()
        history.append(snap)
        let models = build(snap, history: history)
        let gpu = models.first { $0.id == .gpu }
        XCTAssertEqual(gpu?.trend, [0.4])
    }

    // MARK: - Network

    func test_networkCard_ratesChipsAndCumulativeCaption() {
        var snap = SystemSnapshot()
        snap.netDownBytesPerSec = 1_500
        snap.netUpBytesPerSec = 500
        snap.netTotalDown = 1_048_576
        snap.netTotalUp = 2_097_152
        let models = build(snap, strings: .en)
        let network = models.first { $0.id == .network }
        let down = MetricFormat.bytesPerSec(1_500 as Double) ?? "--"
        let up = MetricFormat.bytesPerSec(500 as Double) ?? "--"
        XCTAssertEqual(network?.chipTexts, ["↓ \(down)", "↑ \(up)"])
        let sep = Strings.en.monitorSubtitleSeparator
        XCTAssertEqual(
            network?.secondaryText,
            "Total ↓ \(MetricFormat.bytes(1_048_576 as UInt64)) \(sep) ↑ \(MetricFormat.bytes(2_097_152 as UInt64))"
        )
        XCTAssertEqual(network?.badgeText, Strings.en.monitorLiveBadge)
        XCTAssertTrue(network?.showsLiveDot == true)
        XCTAssertEqual(network?.processMetricKind, .network)
    }

    func test_networkCard_injectsDualTrend() {
        var snap = SystemSnapshot()
        snap.netDownBytesPerSec = 100
        snap.netUpBytesPerSec = 50
        var history = MetricHistory()
        history.append(snap)
        history.append(snap)
        let models = build(snap, history: history)
        let network = models.first { $0.id == .network }
        XCTAssertEqual(network?.trend, [100, 100])
        XCTAssertEqual(network?.secondaryTrend, [50, 50])
    }

    // MARK: - Disk

    func test_diskCard_badgeAndChips() {
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
        let models = build(snap, strings: .zhHans)
        let disk = models.first { $0.id == .disk }
        XCTAssertEqual(disk?.badgeText, "已用 50 GB")
        XCTAssertNil(disk?.secondaryText)
        XCTAssertNil(disk?.progress)
        XCTAssertEqual(disk?.chipTexts, [
            "读取 ↓ \(MetricFormat.bytesPerSec(1_000_000 as Double) ?? "--")",
            "写入 ↑ \(MetricFormat.bytesPerSec(500_000 as Double) ?? "--")",
        ])
        XCTAssertNil(disk?.processMetricKind)
        XCTAssertTrue(disk?.opensDiskDetail == true)
    }

    func test_diskCard_placeholderRatesWhenMissing() {
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
        let models = build(snap, strings: .en)
        let disk = models.first { $0.id == .disk }
        XCTAssertNil(disk?.badgeText) // total 缺失 → 无"已用"
        XCTAssertEqual(disk?.chipTexts, ["Read ↓ --", "Write ↑ --"])
        XCTAssertTrue(disk?.opensDiskDetail == true)
    }

    // MARK: - 布局

    func test_models_fixedSixCardOrderAndNoEnergy() {
        let models = build(SystemSnapshot())
        XCTAssertEqual(models.map(\.id), [.cpu, .memory, .network, .battery, .gpu, .disk])
    }
}
