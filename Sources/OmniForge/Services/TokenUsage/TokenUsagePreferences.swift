import Combine
import Foundation

// MARK: - 展示模式

/// 菜单栏显示模式。
enum TokenUsageMenuBarMode: String, Codable, CaseIterable, Identifiable {
    case todayTokens
    case sessionPercent
    case hidden

    var id: String { rawValue }
}

/// 限额数值显示口径（已用 / 剩余）。
enum TokenUsageLimitsDisplay: String, Codable, CaseIterable, Identifiable {
    case used
    case remaining

    var id: String { rawValue }
}

/// 用量统计周期见 `Models/TokenUsage/UsagePeriod.swift`（今日/本周/本月）。

// MARK: - 配置

struct TokenUsageConfiguration: Equatable, Codable {
    var menuBarMode: TokenUsageMenuBarMode = .todayTokens
    var limitRefreshMinutes = 5
    var limitsDisplayMode: TokenUsageLimitsDisplay = .used
    var usagePeriodDefault: TokenUsagePeriod = .today
    var sessionLimitAlertEnabled = true
    var paceOverrunAlertEnabled = true
    /// DeepSeek 余额监控设置。可选字段：旧配置无此键 → 解码回 nil，走计算属性默认值。
    var deepSeekBalance: DeepSeekBalanceSettings?
    /// trae-cn 云端采集 opt-in（默认关；SPEC R1 / §4.2 C 类）。存储层可选，
    /// 旧配置无此键 → 解码回 nil，走计算属性默认值（Codable 对非可选字段解码严格）。
    var traeCnEnabledStored: Bool?

    /// trae-cn 采集开关（缺省 false）。
    var traeCnEnabled: Bool {
        get { traeCnEnabledStored ?? false }
        set { traeCnEnabledStored = newValue }
    }

    /// 限额刷新间隔合法值。
    static let allowedRefreshIntervals = [1, 5, 15]

    init() {}
}

extension TokenUsageConfiguration {
    /// 余额设置兜底（未显式配置时返回默认：告警开 / ¥1 / 5 分钟）。
    var deepSeekBalanceSettings: DeepSeekBalanceSettings {
        deepSeekBalance ?? DeepSeekBalanceSettings()
    }
}

// MARK: - 偏好管理器

/// Token 用量偏好：Codable 整包持久化，对齐 MonitorPreferences 模式。
final class TokenUsagePreferences: ObservableObject {
    @Published var configuration: TokenUsageConfiguration
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    private static let storageKey = "OmniForge.tokenUsageConfiguration"

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        self.configuration = Self.load(from: userDefaults)

        $configuration
            .dropFirst()
            .sink { [weak self] config in
                self?.persist(config)
            }
            .store(in: &cancellables)
    }

    /// 设置限额刷新间隔（分钟），仅接受 1 / 5 / 15。
    func setLimitRefreshMinutes(_ minutes: Int) throws {
        guard TokenUsageConfiguration.allowedRefreshIntervals.contains(minutes) else {
            throw TokenUsagePreferenceError.invalidRefreshInterval(minutes)
        }
        update { $0.limitRefreshMinutes = minutes }
    }

    /// 设置 DeepSeek 低余额告警开关。
    func setDeepSeekLowBalanceAlertEnabled(_ enabled: Bool) {
        update { config in
            var settings = config.deepSeekBalance ?? DeepSeekBalanceSettings()
            settings.lowBalanceAlertEnabled = enabled
            config.deepSeekBalance = settings
        }
    }

    /// 设置 trae-cn 云端采集开关（opt-in，默认关）。
    func setTraeCnEnabled(_ enabled: Bool) {
        update { config in
            config.traeCnEnabled = enabled
        }
    }

    /// 设置 DeepSeek 低余额阈值（¥）。
    func setDeepSeekThreshold(_ threshold: Double) {
        update { config in
            var settings = config.deepSeekBalance ?? DeepSeekBalanceSettings()
            settings.lowBalanceThreshold = threshold
            config.deepSeekBalance = settings
        }
    }

    /// 设置 DeepSeek 余额刷新间隔（分钟），仅接受 1 / 5 / 15。
    func setDeepSeekRefreshMinutes(_ minutes: Int) throws {
        guard DeepSeekBalanceSettings.allowedRefreshIntervals.contains(minutes) else {
            throw TokenUsagePreferenceError.invalidRefreshInterval(minutes)
        }
        update { config in
            var settings = config.deepSeekBalance ?? DeepSeekBalanceSettings()
            settings.refreshMinutes = minutes
            config.deepSeekBalance = settings
        }
    }

    /// 整包替换 `configuration`，确保 `@Published` 与持久化 sink 被触发。
    func update(_ mutate: (inout TokenUsageConfiguration) -> Void) {
        var copy = configuration
        mutate(&copy)
        configuration = copy
    }

    // MARK: - 持久化

    private static func load(from defaults: UserDefaults) -> TokenUsageConfiguration {
        if let data = defaults.data(forKey: storageKey) {
            return (try? JSONDecoder().decode(TokenUsageConfiguration.self, from: data))
                ?? TokenUsageConfiguration()
        }
        return TokenUsageConfiguration()
    }

    private func persist(_ config: TokenUsageConfiguration) {
        if let data = try? JSONEncoder().encode(config) {
            userDefaults.set(data, forKey: Self.storageKey)
        }
    }
}

enum TokenUsagePreferenceError: Error, Equatable, LocalizedError {
    case invalidRefreshInterval(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRefreshInterval(let value):
            return "Invalid refresh interval: \(value). Only 1, 5, or 15 minutes are allowed."
        }
    }
}
