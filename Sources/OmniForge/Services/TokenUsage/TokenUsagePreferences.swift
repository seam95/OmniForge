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
    var sessionLimitAlertEnabled = true
    var paceOverrunAlertEnabled = true
    /// 趋势图默认周期（日/周/月/总计；仪表盘重设计后替代原「今日/本周/本月」用量周期）。
    /// 存储层可选：旧配置无此键 → 解码回 nil，走计算属性默认（对齐 deepSeekBalance 模式）。
    var trendPeriodDefaultStored: TokenTrendPeriod?
    /// DeepSeek 余额监控设置。可选字段：旧配置无此键 → 解码回 nil，走计算属性默认值。
    var deepSeekBalance: DeepSeekBalanceSettings?
    /// trae-cn 云端采集 opt-in（默认关；SPEC R1 / §4.2 C 类）。存储层可选，
    /// 旧配置无此键 → 解码回 nil，走计算属性默认值（Codable 对非可选字段解码严格）。
    var traeCnEnabledStored: Bool?
    /// 供应商自定义排序。存储层可选，旧配置无此键 → 解码回 nil，走计算属性默认值。
    var providerOrderStored: [TokenUsageProvider]?
    /// 额度重置时显示提示（toast）开关。存储层可选，旧配置无此键 → 解码回 nil，走计算属性默认（开）。
    var resetToastEnabledStored: Bool?
    /// 额度重置时撒花（全屏庆祝动画）开关。存储层可选，旧配置无此键 → 解码回 nil，走计算属性默认（开）。
    var resetConfettiEnabledStored: Bool?
    /// 限额区块隐藏的供应商集合（显隐开关）。存储层可选，旧配置无此键 → 解码回 nil，走计算属性默认（空）。
    var hiddenProvidersStored: Set<TokenUsageProvider>?

    /// 趋势图默认周期（缺省 .month，对齐 TokenTracker）。
    var trendPeriodDefault: TokenTrendPeriod {
        get { trendPeriodDefaultStored ?? .month }
        set { trendPeriodDefaultStored = newValue }
    }

    /// trae-cn 采集开关（缺省 false）。
    var traeCnEnabled: Bool {
        get { traeCnEnabledStored ?? false }
        set { traeCnEnabledStored = newValue }
    }

    /// 额度重置时显示提示（缺省 true，对齐 TokenTracker toastEnabledDefault）。
    var resetToastEnabled: Bool {
        get { resetToastEnabledStored ?? true }
        set { resetToastEnabledStored = newValue }
    }

    /// 额度重置时撒花（缺省 true，对齐 TokenTracker confettiEnabledDefault）。
    var resetConfettiEnabled: Bool {
        get { resetConfettiEnabledStored ?? true }
        set { resetConfettiEnabledStored = newValue }
    }

    /// 限额区块隐藏的供应商集合（缺省空 = 全部可见）。
    var hiddenProviders: Set<TokenUsageProvider> {
        get { hiddenProvidersStored ?? [] }
        set { hiddenProvidersStored = newValue }
    }

    /// 供应商展示顺序（包含全部已知供应商；未在自定义顺序中的供应商自动按默认顺序追加在末尾）。
    var providerOrder: [TokenUsageProvider] {
        get {
            guard let stored = providerOrderStored else {
                return TokenUsageProvider.allCases
            }
            var result: [TokenUsageProvider] = []
            var seen = Set<TokenUsageProvider>()
            for provider in stored {
                if !seen.contains(provider) {
                    result.append(provider)
                    seen.insert(provider)
                }
            }
            for provider in TokenUsageProvider.allCases {
                if !seen.contains(provider) {
                    result.append(provider)
                    seen.insert(provider)
                }
            }
            return result
        }
        set {
            providerOrderStored = newValue
        }
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

    /// 调整供应商位置（如上移 delta = -1，下移 delta = 1）。
    func moveProvider(_ provider: TokenUsageProvider, delta: Int) {
        update { config in
            var order = config.providerOrder
            guard let index = order.firstIndex(of: provider) else { return }
            let target = index + delta
            guard order.indices.contains(target) else { return }
            order.swapAt(index, target)
            config.providerOrder = order
        }
    }

    /// 设置新的供应商整体顺序。
    func setProviderOrder(_ newOrder: [TokenUsageProvider]) {
        update { config in
            config.providerOrder = newOrder
        }
    }

    /// 设置额度重置时显示提示开关。
    func setResetToastEnabled(_ enabled: Bool) {
        update { $0.resetToastEnabled = enabled }
    }

    /// 设置额度重置时撒花开关。
    func setResetConfettiEnabled(_ enabled: Bool) {
        update { $0.resetConfettiEnabled = enabled }
    }

    /// 设置某供应商在限额区块的显隐（hidden=true 隐藏卡片与胶囊）。
    func setProviderHidden(_ provider: TokenUsageProvider, hidden: Bool) {
        update { config in
            var hiddenSet = config.hiddenProviders
            if hidden {
                hiddenSet.insert(provider)
            } else {
                hiddenSet.remove(provider)
            }
            config.hiddenProviders = hiddenSet
        }
    }

    /// 按「已配置子集」的拖拽位移重排 providerOrder（未配置项保持原位）。
    /// 弹层只列已配置 provider，from/to 为该子集内的下标（SwiftUI move 语义）。
    func moveConfiguredProviders(from source: IndexSet, to destination: Int, configured: Set<TokenUsageProvider>) {
        update { config in
            config.providerOrder = TokenUsageProviderOrdering.moveConfigured(
                order: config.providerOrder,
                configured: configured,
                from: source,
                to: destination
            )
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

// MARK: - 供应商排序纯逻辑

/// 供应商排序纯函数 — 无状态，独立可测。
enum TokenUsageProviderOrdering {
    /// 把「已配置子集」内的拖拽位移映射回完整顺序：先对子集应用 SwiftUI move 语义，
    /// 再走原顺序，遇已配置槽位依次填回新子集顺序，未配置项保持原位。
    ///
    /// - Parameters:
    ///   - order: 完整 provider 顺序（含未配置项）。
    ///   - configured: 已配置 provider 集合（弹层展示的子集）。
    ///   - source / destination: 子集内的下标，遵循 SwiftUI `move(fromOffsets:toOffset:)` 语义。
    static func moveConfigured(
        order: [TokenUsageProvider],
        configured: Set<TokenUsageProvider>,
        from source: IndexSet,
        to destination: Int
    ) -> [TokenUsageProvider] {
        let configuredOrdered = order.filter { configured.contains($0) }
        let reorderedSubset = moveWithinSubset(configuredOrdered, from: source, to: destination)
        var iterator = reorderedSubset.makeIterator()
        return order.map { provider in
            configured.contains(provider) ? (iterator.next() ?? provider) : provider
        }
    }

    /// 子集内的标准 move（对齐 TokenTracker `reorderedProviderOrder` 语义）。
    /// `destination` 遵循 SwiftUI `move(fromOffsets:toOffset:)` 在原始数组上的语义。
    private static func moveWithinSubset(
        _ subset: [TokenUsageProvider],
        from source: IndexSet,
        to destination: Int
    ) -> [TokenUsageProvider] {
        var updated = subset
        let indexes = source.filter { $0 >= 0 && $0 < updated.count }
        guard !indexes.isEmpty else { return updated }

        let items = indexes.map { updated[$0] }
        for index in indexes.sorted().reversed() {
            updated.remove(at: index)
        }

        let removedBeforeDestination = indexes.filter { $0 < destination }.count
        let insertAt = max(0, min(destination - removedBeforeDestination, updated.count))
        updated.insert(contentsOf: items, at: insertAt)
        return updated
    }
}
