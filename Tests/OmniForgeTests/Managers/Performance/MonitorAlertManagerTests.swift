import XCTest
@testable import OmniForge

final class MonitorAlertManagerTests: XCTestCase {
    func test_cpuAlertRequiresTwelveContinuousSeconds() {
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(cpuEnabled: true, cpuThreshold: 90)
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = CPUUsageReading(total: 0.95, user: 0.5, system: 0.45)
        _ = manager.evaluate(snapshot, at: Date(timeIntervalSince1970: 0))
        _ = manager.evaluate(snapshot, at: Date(timeIntervalSince1970: 11))
        XCTAssertTrue(notifier.posts.isEmpty)
        _ = manager.evaluate(snapshot, at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func test_cpuAlertWindowResetsWhenDroppingBelowThreshold() {
        // 高 8s → 降到阈值下（重置）→ 再升高；需重新计满 12s 才触发
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(cpuEnabled: true, cpuThreshold: 90)
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)

        var high = SystemSnapshot()
        high.cpuUsage = CPUUsageReading(total: 0.95, user: 0.5, system: 0.45)
        var low = SystemSnapshot()
        low.cpuUsage = CPUUsageReading(total: 0.50, user: 0.3, system: 0.2)

        // t=0..8 连续高
        _ = manager.evaluate(high, at: Date(timeIntervalSince1970: 0))
        _ = manager.evaluate(high, at: Date(timeIntervalSince1970: 8))
        // t=9 下降 → 窗口重置
        _ = manager.evaluate(low, at: Date(timeIntervalSince1970: 9))
        // t=10 再升高，重新开始 12s 计时
        _ = manager.evaluate(high, at: Date(timeIntervalSince1970: 10))
        // t=20：距 t=10 仅 10s，不应触发
        _ = manager.evaluate(high, at: Date(timeIntervalSince1970: 20))
        XCTAssertTrue(notifier.posts.isEmpty, "重置后未满 12s 不应触发")
        // t=22：距 t=10 满 12s，应触发
        _ = manager.evaluate(high, at: Date(timeIntervalSince1970: 22))
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func test_invalidSampleNeverTriggersAlert() {
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(cpuEnabled: true, cpuThreshold: 90)
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)
        var snapshot = SystemSnapshot()
        snapshot.issues[.cpu] = .failed("host_statistics failed")
        _ = manager.evaluate(snapshot, at: Date())
        XCTAssertTrue(notifier.posts.isEmpty)
    }

    func test_cpuTemperatureAlertTriggersAboveThreshold() {
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(cpuTemperatureEnabled: true, cpuTemperatureThreshold: 85)
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)
        var snapshot = SystemSnapshot()
        snapshot.cpuTemperature = 90
        _ = manager.evaluate(snapshot, at: Date())
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func test_cpuTemperatureAlertDoesNotTriggerBelowThreshold() {
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(cpuTemperatureEnabled: true, cpuTemperatureThreshold: 85)
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)
        var snapshot = SystemSnapshot()
        snapshot.cpuTemperature = 70
        _ = manager.evaluate(snapshot, at: Date())
        XCTAssertTrue(notifier.posts.isEmpty)
    }

    func test_requiredMetricsMapsEnabledAlerts() {
        let empty = MonitorAlertConfiguration()
        XCTAssertTrue(MonitorAlertManager.requiredMetrics(from: empty).isEmpty)

        let allEnabled = MonitorAlertConfiguration(
            cpuEnabled: true,
            cpuTemperatureEnabled: true,
            memoryEnabled: true,
            diskEnabled: true,
            batteryEnabled: true
        )
        XCTAssertEqual(
            MonitorAlertManager.requiredMetrics(from: allEnabled),
            [.cpu, .cpuTemperature, .memory, .disk, .power]
        )
    }

    func test_notificationBodyUsesLocalizedTemplate() {
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(cpuEnabled: true, cpuThreshold: 90)
        let manager = MonitorAlertManager(
            notificationClient: notifier,
            configuration: config,
            stringsProvider: { .en }
        )
        var snapshot = SystemSnapshot()
        snapshot.cpuUsage = CPUUsageReading(total: 0.95, user: 0.5, system: 0.45)
        _ = manager.evaluate(snapshot, at: Date(timeIntervalSince1970: 0))
        _ = manager.evaluate(snapshot, at: Date(timeIntervalSince1970: 12))
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(notifier.posts[0].title, Strings.en.alertsNotificationTitle)
        XCTAssertTrue(notifier.posts[0].body.contains("CPU"))
        XCTAssertEqual(
            notifier.posts[0].body,
            String(format: Strings.en.alertsBodyCpu, config.cpuThreshold)
        )
    }

    func test_cooldownPreventsDuplicatePostsWithinWindow() {
        let notifier = FakeMonitorNotificationClient()
        var config = MonitorAlertConfiguration(cpuTemperatureEnabled: true, cpuTemperatureThreshold: 80)
        config.cooldownMinutes = 15
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)
        var snapshot = SystemSnapshot()
        snapshot.cpuTemperature = 90

        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = manager.evaluate(snapshot, at: t0)
        XCTAssertEqual(notifier.posts.count, 1)

        // still inside 15 minutes
        _ = manager.evaluate(snapshot, at: t0.addingTimeInterval(10 * 60))
        XCTAssertEqual(notifier.posts.count, 1)

        // past cooldown
        _ = manager.evaluate(snapshot, at: t0.addingTimeInterval(15 * 60))
        XCTAssertEqual(notifier.posts.count, 2)
    }

    func test_memoryAlertTriggersOnlyOnCritical() {
        let notifier = FakeMonitorNotificationClient()
        let config = MonitorAlertConfiguration(memoryEnabled: true)
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)

        var warning = SystemSnapshot()
        warning.memoryPressure = .warning
        _ = manager.evaluate(warning, at: Date())
        XCTAssertTrue(notifier.posts.isEmpty)

        var critical = SystemSnapshot()
        critical.memoryPressure = .critical
        _ = manager.evaluate(critical, at: Date())
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func test_diskAlertTriggersWhenFreePercentBelowThreshold() {
        let notifier = FakeMonitorNotificationClient()
        var config = MonitorAlertConfiguration(diskEnabled: true)
        config.diskFreeThreshold = 10
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)

        var snapshot = SystemSnapshot()
        snapshot.disk = DiskReading(
            devices: [],
            readBytesPerSec: 0,
            writeBytesPerSec: 0,
            totalRead: 0,
            totalWritten: 0,
            freeSpace: 5_000,
            totalSpace: 100_000
        )
        _ = manager.evaluate(snapshot, at: Date())
        XCTAssertEqual(notifier.posts.count, 1)
    }

    func test_batteryAlertTriggersOnlyWhileDischargingBelowThreshold() {
        let notifier = FakeMonitorNotificationClient()
        var config = MonitorAlertConfiguration(batteryEnabled: true)
        config.batteryThreshold = 15
        let manager = MonitorAlertManager(notificationClient: notifier, configuration: config)

        var charging = SystemSnapshot()
        var powerCharging = PowerReading()
        powerCharging.hasBattery = true
        powerCharging.isCharging = true
        powerCharging.chargePercent = 10
        charging.power = powerCharging
        _ = manager.evaluate(charging, at: Date())
        XCTAssertTrue(notifier.posts.isEmpty)

        var discharging = SystemSnapshot()
        var power = PowerReading()
        power.hasBattery = true
        power.isCharging = false
        power.chargePercent = 10
        discharging.power = power
        _ = manager.evaluate(discharging, at: Date())
        XCTAssertEqual(notifier.posts.count, 1)
    }
}

// MARK: - Test Helpers

final class FakeMonitorNotificationClient: MonitorNotificationClient {
    var posts: [(title: String, body: String)] = []

    func requestAuthorization(completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func post(title: String, body: String, completion: @escaping (Result<Void, Error>) -> Void) {
        posts.append((title, body))
        completion(.success(()))
    }
}
