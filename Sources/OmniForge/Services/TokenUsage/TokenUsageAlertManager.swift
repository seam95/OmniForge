import Foundation

/// Token 用量告警触发器 — 会话窗阈值（`TokenUsageConfiguration.sessionAlertThresholdPercent`，缺省 90）与步速超前（LimitPace.paceOver）。
/// 随 `TokenUsageManager` 限额刷新同频调用 `evaluate`；未授权通知静默降级（失败不报错，对齐 MonitorAlertManager）。
final class TokenUsageAlertManager {
    enum AlertKind: Hashable {
        /// 会话窗用量 ≥ 配置阈值（缺省 90%）。
        case sessionThreshold
        /// LimitPace 判定按当前步速将提前用尽。
        case paceOverrun
    }

    /// 防抖键：provider + 告警类型 + 窗口 resetAt。
    /// 同一窗口的同一告警在 reset 前不重复推送；window reset 后 resetAt 变化，可再次触发。
    /// 内存维护即可（重启后窗口 resetAt 通常已过，重新判定合理）。
    private struct ReportedKey: Hashable {
        let provider: TokenUsageProvider
        let kind: AlertKind
        let resetAt: Date?
    }

    private let notificationClient: UserNotificationPosting
    private let configurationProvider: () -> TokenUsageConfiguration
    private let stringsProvider: () -> Strings
    /// 通知权限状态（真实注入 `Permissions.shared.notifications`）：未授权时静默降级。
    /// 顺带规避非 .app 宿主（XCTest/SPM 运行器）调用 UNUserNotificationCenter 崩溃。
    private let authorizationProvider: () -> Bool
    private let now: () -> Date
    /// 已投递的告警键（按窗口 resetAt 判定同窗防抖）。
    private var reportedKeys = Set<ReportedKey>()

    init(
        notificationClient: UserNotificationPosting,
        configuration: @escaping () -> TokenUsageConfiguration,
        stringsProvider: @escaping () -> Strings = { L10n().s },
        authorizationProvider: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationClient = notificationClient
        self.configurationProvider = configuration
        self.stringsProvider = stringsProvider
        self.authorizationProvider = authorizationProvider
        self.now = now
    }

    /// 消费单个 provider 限额快照（随 TokenUsageManager 限额刷新同频调用）。
    func evaluate(_ limits: ProviderUsageLimits) {
        evaluate(limits, at: now())
    }

    /// 显式时间判定（防抖 / reset 边界测试可控）。
    func evaluate(_ limits: ProviderUsageLimits, at now: Date) {
        // 仅对新鲜、无错误、已配置的快照告警；过期回退不打扰。
        guard limits.configured, limits.issue == nil, !limits.stale else { return }
        guard let window = limits.windows[.session] else { return }
        let configuration = configurationProvider()

        if configuration.sessionLimitAlertEnabled,
           window.usedPercent >= configuration.sessionAlertThresholdPercent {
            report(kind: .sessionThreshold, provider: limits.provider, window: window)
        }

        if configuration.paceOverrunAlertEnabled,
           let resetAt = window.resetAt,
           let windowSeconds = window.windowSeconds {
            // 复用 LimitPace.compute 的 paceOver（含 3pp 容差），与面板刻度判据一致。
            let pace = LimitPace.compute(
                usedFraction: window.usedPercent / 100,
                windowSeconds: windowSeconds,
                secondsUntilReset: resetAt.timeIntervalSince(now),
                remainingMode: false
            )
            if pace.paceOver {
                report(kind: .paceOverrun, provider: limits.provider, window: window)
            }
        }
    }

    // MARK: - 投递

    private func report(kind: AlertKind, provider: TokenUsageProvider, window: UsageWindow) {
        // 未授权（或非 .app 宿主）：静默降级不投递、不记防抖，授权后同窗可补发。
        guard authorizationProvider() else { return }
        // 防抖：同窗同告警已投递则不重复（Window reset 后才可再次触发）。
        let key = ReportedKey(provider: provider, kind: kind, resetAt: window.resetAt)
        guard reportedKeys.insert(key).inserted else { return }

        let strings = stringsProvider()
        let title: String
        let body: String
        switch kind {
        case .sessionThreshold:
            title = strings.tokenAlertSessionTitle
            body = String(
                format: strings.tokenAlertSessionBodyFormat,
                provider.displayName,
                Int(window.usedPercent.rounded())
            )
        case .paceOverrun:
            title = strings.tokenAlertPaceTitle
            body = String(format: strings.tokenAlertPaceBodyFormat, provider.displayName)
        }
        // 投递失败（如授权被系统回收）静默降级：不抛错、不上浮。
        notificationClient.post(title: title, body: body) { _ in }
    }
}
