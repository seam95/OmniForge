import Foundation
import Combine

enum MonitorAlertKind: String, CaseIterable {
    case cpu, cpuTemperature, memory, disk, battery
}

final class MonitorAlertManager: ObservableObject {
    private let notificationClient: MonitorNotificationClient
    private var configuration: MonitorAlertConfiguration
    private let stringsProvider: () -> Strings
    @Published var lastError: String?
    private var highCPUSince: Date?
    private var lastSent: [MonitorAlertKind: Date] = [:]
    private var cancellables = Set<AnyCancellable>()

    init(
        notificationClient: MonitorNotificationClient,
        configuration: MonitorAlertConfiguration,
        stringsProvider: @escaping () -> Strings = { L10n().s }
    ) {
        self.notificationClient = notificationClient
        self.configuration = configuration
        self.stringsProvider = stringsProvider
    }

    func updateConfiguration(_ config: MonitorAlertConfiguration) {
        configuration = config
    }

    /// 将告警配置映射为采样需求；仅开启告警时也应保持 isSampling
    static func requiredMetrics(from config: MonitorAlertConfiguration) -> Set<MonitorMetric> {
        var set = Set<MonitorMetric>()
        if config.cpuEnabled { set.insert(.cpu) }
        if config.cpuTemperatureEnabled { set.insert(.cpuTemperature) }
        if config.memoryEnabled { set.insert(.memory) }
        if config.diskEnabled { set.insert(.disk) }
        if config.batteryEnabled { set.insert(.power) }
        return set
    }

    func requestAuthorization() {
        notificationClient.requestAuthorization { [weak self] result in
            if case .failure(let error) = result {
                DispatchQueue.main.async { self?.lastError = error.localizedDescription }
            }
        }
    }

    func evaluate(_ snapshot: SystemSnapshot, at now: Date) -> Set<MonitorAlertKind> {
        var triggered = Set<MonitorAlertKind>()

        // CPU 告警 — 需要连续 12 秒超过阈值
        if configuration.cpuEnabled, let cpu = snapshot.cpuUsage?.total {
            if cpu > Double(configuration.cpuThreshold) / 100.0 {
                if highCPUSince == nil { highCPUSince = now }
                if let since = highCPUSince, now.timeIntervalSince(since) >= 12 {
                    triggered.insert(.cpu)
                }
            } else {
                highCPUSince = nil
            }
        } else {
            highCPUSince = nil
        }

        // 内存告警
        if configuration.memoryEnabled, snapshot.memoryPressure == .critical {
            triggered.insert(.memory)
        }

        // 磁盘告警
        if configuration.diskEnabled, let free = snapshot.disk?.freeSpace {
            let total = snapshot.disk?.totalSpace ?? 1
            let freePct = Double(free) / Double(total) * 100
            if freePct < Double(configuration.diskFreeThreshold) {
                triggered.insert(.disk)
            }
        }

        // 电池告警
        if configuration.batteryEnabled, let power = snapshot.power, power.hasBattery, !power.isCharging {
            if let charge = power.chargePercent, charge <= configuration.batteryThreshold {
                triggered.insert(.battery)
            }
        }
        // CPU 温度告警
        if configuration.cpuTemperatureEnabled, let temp = snapshot.cpuTemperature {
            if temp >= Double(configuration.cpuTemperatureThreshold) {
                triggered.insert(.cpuTemperature)
            }
        }

        // 发送通知（冷却期内同类不重复发）
        for kind in triggered {
            sendNotification(for: kind, at: now)
        }
        return triggered
    }

    private func sendNotification(for kind: MonitorAlertKind, at now: Date) {
        let cooldown = TimeInterval(configuration.cooldownMinutes * 60)
        if let previous = lastSent[kind], now.timeIntervalSince(previous) < cooldown { return }
        lastSent[kind] = now
        let s = stringsProvider()
        let title = s.alertsNotificationTitle
        let body: String
        switch kind {
        case .cpu:
            body = String(format: s.alertsBodyCpu, configuration.cpuThreshold)
        case .cpuTemperature:
            body = String(format: s.alertsBodyCpuTemperature, configuration.cpuTemperatureThreshold)
        case .memory:
            body = s.alertsBodyMemory
        case .disk:
            body = String(format: s.alertsBodyDisk, configuration.diskFreeThreshold)
        case .battery:
            body = String(format: s.alertsBodyBattery, configuration.batteryThreshold)
        }
        notificationClient.post(title: title, body: body) { result in
            if case .failure(let error) = result {
                DispatchQueue.main.async { self.lastError = error.localizedDescription }
            }
        }
    }
}
