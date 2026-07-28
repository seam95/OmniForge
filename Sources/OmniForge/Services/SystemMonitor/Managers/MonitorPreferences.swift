import Foundation
import Combine

// MARK: - 错误类型

enum MonitorPreferenceError: Error, Equatable, LocalizedError {
    case invalidRefreshInterval(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval(let value):
            return "Invalid refresh interval: \(value). Only 1, 2, or 5 seconds are allowed."
        }
    }
}

// MARK: - 告警配置

struct MonitorAlertConfiguration: Equatable, Codable {
    var cpuEnabled = false
    var cpuThreshold = 90
    var cpuTemperatureEnabled = false
    var cpuTemperatureThreshold = 90
    var memoryEnabled = false
    var diskEnabled = false
    var diskFreeThreshold = 10
    var batteryEnabled = false
    var batteryThreshold = 15
    var cooldownMinutes = 15
}

// MARK: - 完整监控配置

struct MonitorConfiguration: Equatable, Codable {
    var isEnabled = true
    var refreshInterval = 2
    var temperatureUnit = TemperatureUnit.celsius
    var visibleSections = Set(MonitorSection.allCases)
    /// 面板分区展示顺序（设置页可调）
    var panelSectionOrder: [MonitorSection] = Array(MonitorSection.allCases)
    var visiblePanelMetrics = Set(MonitorMetric.allCases)
    var enabledMenuBarMetrics = Set<MenuBarMetric>()
    var menuBarMetricOrder = MenuBarMetric.defaultOrder
    var menuBarPreset = MenuBarPreset.dense
    var menuBarSpacing = MenuBarMetricSpacing.compact
    var menuBarMemoryStyle = MemoryMenuBarStyle.percent
    var combineTemperatures = true
    /// false = 合并到主状态项（Vorssaint 默认路径）；true = 每指标独立 status item
    var separateStatusItems = false
    var hideMainIconWithMetrics = false
    var networkUploadFirst = false
    var alert = MonitorAlertConfiguration()

    init() {}

    // 兼容旧存储：缺失 panelSectionOrder 时回落默认顺序，不丢弃其余偏好
    enum CodingKeys: String, CodingKey {
        case isEnabled
        case refreshInterval
        case temperatureUnit
        case visibleSections
        case panelSectionOrder
        case visiblePanelMetrics
        case enabledMenuBarMetrics
        case menuBarMetricOrder
        case menuBarPreset
        case menuBarSpacing
        case menuBarMemoryStyle
        case combineTemperatures
        case separateStatusItems
        case hideMainIconWithMetrics
        case networkUploadFirst
        case alert
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        refreshInterval = try container.decodeIfPresent(Int.self, forKey: .refreshInterval) ?? 2
        temperatureUnit = try container.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? .celsius
        visibleSections = try container.decodeIfPresent(Set<MonitorSection>.self, forKey: .visibleSections)
            ?? Set(MonitorSection.allCases)
        panelSectionOrder = try container.decodeIfPresent([MonitorSection].self, forKey: .panelSectionOrder)
            ?? Array(MonitorSection.allCases)
        visiblePanelMetrics = try container.decodeIfPresent(Set<MonitorMetric>.self, forKey: .visiblePanelMetrics)
            ?? Set(MonitorMetric.allCases)
        enabledMenuBarMetrics = try container.decodeIfPresent(Set<MenuBarMetric>.self, forKey: .enabledMenuBarMetrics)
            ?? []
        menuBarMetricOrder = try container.decodeIfPresent([MenuBarMetric].self, forKey: .menuBarMetricOrder)
            ?? MenuBarMetric.defaultOrder
        menuBarPreset = try container.decodeIfPresent(MenuBarPreset.self, forKey: .menuBarPreset) ?? .dense
        menuBarSpacing = try container.decodeIfPresent(MenuBarMetricSpacing.self, forKey: .menuBarSpacing) ?? .compact
        menuBarMemoryStyle = try container.decodeIfPresent(MemoryMenuBarStyle.self, forKey: .menuBarMemoryStyle) ?? .percent
        combineTemperatures = try container.decodeIfPresent(Bool.self, forKey: .combineTemperatures) ?? true
        separateStatusItems = try container.decodeIfPresent(Bool.self, forKey: .separateStatusItems) ?? false
        hideMainIconWithMetrics = try container.decodeIfPresent(Bool.self, forKey: .hideMainIconWithMetrics) ?? false
        networkUploadFirst = try container.decodeIfPresent(Bool.self, forKey: .networkUploadFirst) ?? false
        alert = try container.decodeIfPresent(MonitorAlertConfiguration.self, forKey: .alert)
            ?? MonitorAlertConfiguration()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(temperatureUnit, forKey: .temperatureUnit)
        try container.encode(visibleSections, forKey: .visibleSections)
        try container.encode(panelSectionOrder, forKey: .panelSectionOrder)
        try container.encode(visiblePanelMetrics, forKey: .visiblePanelMetrics)
        try container.encode(enabledMenuBarMetrics, forKey: .enabledMenuBarMetrics)
        try container.encode(menuBarMetricOrder, forKey: .menuBarMetricOrder)
        try container.encode(menuBarPreset, forKey: .menuBarPreset)
        try container.encode(menuBarSpacing, forKey: .menuBarSpacing)
        try container.encode(menuBarMemoryStyle, forKey: .menuBarMemoryStyle)
        try container.encode(combineTemperatures, forKey: .combineTemperatures)
        try container.encode(separateStatusItems, forKey: .separateStatusItems)
        try container.encode(hideMainIconWithMetrics, forKey: .hideMainIconWithMetrics)
        try container.encode(networkUploadFirst, forKey: .networkUploadFirst)
        try container.encode(alert, forKey: .alert)
    }
}

// MARK: - 偏好管理器

final class MonitorPreferences: ObservableObject {
    @Published var configuration: MonitorConfiguration
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private static let storageKey = "OmniForge.monitorConfiguration"
    /// 改名前的历史 key；仅在读取时回退使用，写入一律走 `storageKey`。
    private static let legacyStorageKey = "InputLock.monitorConfiguration"

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.configuration = MonitorPreferences.load(from: userDefaults)

        $configuration
            .dropFirst()
            .sink { [weak self] config in
                self?.persist(config)
            }
            .store(in: &cancellables)
    }

    /// 设置刷新间隔，仅接受 1、2、5 秒
    func setRefreshInterval(_ seconds: Int) throws {
        guard [1, 2, 5].contains(seconds) else {
            throw MonitorPreferenceError.invalidRefreshInterval(seconds)
        }
        update { $0.refreshInterval = seconds }
    }

    /// 整包替换 `configuration`，确保 `@Published` 与持久化 sink 被触发
    func update(_ mutate: (inout MonitorConfiguration) -> Void) {
        var copy = configuration
        mutate(&copy)
        configuration = copy
    }

    // MARK: - 持久化

    private static func load(from defaults: UserDefaults) -> MonitorConfiguration {
        if let data = defaults.data(forKey: storageKey) {
            return (try? JSONDecoder().decode(MonitorConfiguration.self, from: data)) ?? MonitorConfiguration()
        }
        // 回退：读取改名前的历史 key，成功则迁移到新 key 后清除旧 key。
        if let legacy = defaults.data(forKey: legacyStorageKey),
           let decoded = try? JSONDecoder().decode(MonitorConfiguration.self, from: legacy) {
            defaults.set(legacy, forKey: storageKey)
            defaults.removeObject(forKey: legacyStorageKey)
            return decoded
        }
        return MonitorConfiguration()
    }

    private func persist(_ config: MonitorConfiguration) {
        if let data = try? JSONEncoder().encode(config) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }
}
