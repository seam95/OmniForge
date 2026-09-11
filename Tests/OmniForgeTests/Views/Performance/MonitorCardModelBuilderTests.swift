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

    func test_cpuCard_formatsTotalWithoutSplitCaption() {
        var snap = SystemSnapshot()
        snap.cpuUsage = CPUUsageReading(total: 0.42, user: 0.30, system: 0.12)
        let models = build(snap, strings: .zhHans)
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.primaryText, "42%")
        XCTAssertNil(cpu?.secondaryText) // 系统/用户拆分已随新设计稿下线
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
        // 采样时刻随趋势注入（悬浮气泡显示时间用）
        XCTAssertEqual(cpu?.trendTimes?.count, 2)
    }

    func test_cpuCard_temperatureGoesToAccessory() {
        var snap = SystemSnapshot()
        snap.cpuUsage = CPUUsageReading(total: 0.42, user: 0.30, system: 0.12)
        snap.cpuTemperature = 45
        let models = build(snap, strings: .zhHans)
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.primaryText, "42%")
        XCTAssertEqual(cpu?.accessoryText, "45°")
    }

    func test_cpuCard_missingReadingShowsPlaceholders() {
        let models = build(SystemSnapshot(), strings: .en)
        let cpu = models.first { $0.id == .cpu }
        XCTAssertEqual(cpu?.primaryText, "--")
        XCTAssertNil(cpu?.secondaryText)
        XCTAssertNil(cpu?.accessoryText)
    }

    // MARK: - Memory

    func test_memoryCard_percentPrimaryAndUsedAccessory() {
        var snap = SystemSnapshot()
        snap.memoryUsed = 4_000_000_000
        snap.memoryTotal = 8_000_000_000
        snap.memoryPressure = .warning
        let models = build(snap, strings: .en)
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, "50%")
        // 大数字旁显示已用量（始终一位小数带单位）；压力文案已随新设计稿下线
        XCTAssertEqual(memory?.accessoryText, "3.7 GB")
        XCTAssertNil(memory?.secondaryText)
        XCTAssertEqual(memory?.progress ?? -1, 0.5, accuracy: 0.0001)
    }

    func test_memoryCard_missingValuesFallsBackToPlaceholders() {
        var snap = SystemSnapshot()
        snap.memoryUsed = nil
        snap.memoryTotal = nil
        snap.memoryPressure = .warning
        let models = build(snap, strings: .zhHans)
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.primaryText, "--")
        XCTAssertNil(memory?.accessoryText)
        XCTAssertNil(memory?.progress)
    }

    func test_memoryCard_injectsTrendFromHistory() {
        var snap = SystemSnapshot()
        snap.memoryUsed = 8_000_000_000
        snap.memoryTotal = 16_000_000_000
        var history = MetricHistory()
        history.append(snap)
        let models = build(snap, history: history)
        let memory = models.first { $0.id == .memory }
        XCTAssertEqual(memory?.trend?.count, 1)
        XCTAssertEqual(memory?.trend?.first ?? -1, 0.5, accuracy: 0.0001)
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

    func test_gpuCard_primaryIsPurePercentAndTemperatureAccessory() {
        var snap = SystemSnapshot()
        snap.gpuUsage = 0.46
        snap.gpuTemperature = 63
        let models = build(snap, strings: .zhHans)
        let gpu = models.first { $0.id == .gpu }
        XCTAssertEqual(gpu?.primaryText, "46%")
        XCTAssertEqual(gpu?.accessoryText, "63°")
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
        XCTAssertEqual(network?.chipTexts, [down, up])
        let sep = Strings.en.monitorSubtitleSeparator
        XCTAssertEqual(
            network?.secondaryText,
            "Total ↓ \(MetricFormat.bytes(1_048_576 as UInt64)) \(sep) ↑ \(MetricFormat.bytes(2_097_152 as UInt64))"
        )
        XCTAssertEqual(network?.badgeText, Strings.en.monitorLiveBadge)
        XCTAssertFalse(network?.showsLiveDot == true)
        XCTAssertEqual(network?.processMetricKind, .network)
    }

    func test_networkCard_injectsDualTrend() {
        var snap = SystemSnapshot()
        snap.netDownBytesPerSec = 100
        snap.netUpBytesPerSec = 50
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        snap.sampledAt = time
        var history = MetricHistory()
        history.append(snap)
        history.append(snap)
        let models = build(snap, history: history)
        let network = models.first { $0.id == .network }
        XCTAssertEqual(network?.trend, [100, 100])
        XCTAssertEqual(network?.secondaryTrend, [50, 50])
        // 双线悬浮以行序列时刻定位，注入下行序列时刻
        XCTAssertEqual(network?.trendTimes, [time, time])
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
        // 设计稿：标题行右侧显示已用量（带「已用」前缀），不再单独展示可用徽标
        XCTAssertEqual(disk?.primaryText, "已用 50 GB")
        XCTAssertNil(disk?.badgeText)
        XCTAssertNil(disk?.secondaryText)
        XCTAssertNil(disk?.progress)
        // 读/写速率带「读取/写入」前缀
        XCTAssertEqual(disk?.chipTexts, [
            "读取 \(MetricFormat.bytesPerSec(1_000_000 as Double))",
            "写入 \(MetricFormat.bytesPerSec(500_000 as Double))",
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
        XCTAssertEqual(disk?.primaryText, "--") // total 缺失 → 无已用量
        XCTAssertNil(disk?.badgeText) // 新设计稿不再展示可用徽标
        XCTAssertEqual(disk?.chipTexts, ["Read --", "Write --"])
        XCTAssertTrue(disk?.opensDiskDetail == true)
    }

    // MARK: - 布局

    func test_models_fixedSixCardOrderAndNoEnergy() {
        let models = build(SystemSnapshot())
        XCTAssertEqual(models.map(\.id), [.cpu, .gpu, .memory, .network, .fan, .disk, .battery])
    }

    // MARK: - 风扇卡

    func test_fanModel_dualFans_showsPeakRPMCaptionAndManualBadge() {
        var snapshot = SystemSnapshot()
        snapshot.fans = [
            FanReading(id: 0, currentRPM: 3200, minRPM: 1200, maxRPM: 5800, targetRPM: 3200, isManualMode: false),
            FanReading(id: 1, currentRPM: 3400, minRPM: 1200, maxRPM: 5900, targetRPM: 3500, isManualMode: true)
        ]
        let models = build(snapshot)
        guard let fan = models.first(where: { $0.id == .fan }) else {
            return XCTFail("缺少风扇卡")
        }
        XCTAssertEqual(fan.primaryText, "3400 RPM", "主值取最高转速")
        XCTAssertEqual(fan.secondaryText, "3200 RPM • 3400 RPM")
        XCTAssertEqual(fan.badgeText, Strings.en.fanModeManualBadge, "任一风扇手动即出徽章")
        XCTAssertTrue(fan.hasFanData)
        // 最高转速占比 = (3400-1200)/(5900-1200)
        XCTAssertEqual(fan.progress ?? 0, (3400 - 1200) / (5900 - 1200), accuracy: 0.001)
    }

    func test_fanModel_noFans_marksNoFanData() {
        let models = build(SystemSnapshot())
        let fan = models.first { $0.id == .fan }
        XCTAssertEqual(fan?.hasFanData, false, "无风扇读数时 Planner 据此不出分区")
        XCTAssertEqual(fan?.primaryText, "--")
    }
}
