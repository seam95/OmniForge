import Combine
import Foundation

// MARK: - 取数边界

/// DeepSeek 余额取数边界 — 签名与 `ProviderAPIClient.getJSON` 一致，便于测试替身。
protocol DeepSeekBalanceFetching: AnyObject {
    func getJSON(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> [String: Any]
}

/// 生产实现复用共享 HTTP 客户端（401/403 → reauth、429 → rateLimited、15s 超时）。
/// conformance 放在本文件：不改动 ProviderAPIClient 本体。
extension ProviderAPIClient: DeepSeekBalanceFetching {}

/// 余额保存/删除校验错误。
enum DeepSeekBalanceError: Error, Equatable {
    case emptyAPIKey
}

// MARK: - 管理器

/// DeepSeek 余额管理器：定时拉取 `/user/balance`，单飞合并，失败保留旧值标 stale，
/// 低余额跨阈值单次通知（恢复或设置变化后复位）。
@MainActor
final class DeepSeekBalanceManager: ObservableObject {
    static let endpoint = URL(string: "https://api.deepseek.com/user/balance")!

    @Published private(set) var snapshot: DeepSeekBalanceSnapshot?
    @Published private(set) var apiKeyConfigured = false

    /// 面板守卫：密钥已配置（或钥匙串可读出）才渲染余额卡。
    var showingBalanceCard: Bool { apiKeyConfigured }

    private let preferences: TokenUsagePreferences
    private let keyStore: DeepSeekAPIKeyStoring
    private let fetcher: any DeepSeekBalanceFetching
    private let scheduler: RepeatingScheduling
    private let notificationClient: UserNotificationPosting
    private let authorizationProvider: () -> Bool
    private let stringsProvider: () -> Strings
    private let now: () -> Date

    private var timer: AnyCancellable?
    private var preferencesCancellable: AnyCancellable?
    private var scheduledMinutes = -1
    private var isActive = false
    private var isFetching = false
    /// 低余额上报标志：跨阈值单次；恢复、save/delete 密钥或告警设置变化后复位。
    /// 内存维护不持久化——重启后若仍低于阈值会补发一次（见 SPEC 边界）。
    private var lowBalanceReported = false
    private var lastAlertEnabled = false
    private var lastThreshold = 0.0

    init(
        preferences: TokenUsagePreferences,
        keyStore: DeepSeekAPIKeyStoring = DeepSeekKeychainAPIKeyStore(),
        fetcher: any DeepSeekBalanceFetching = ProviderAPIClient(),
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        notificationClient: UserNotificationPosting,
        authorizationProvider: @escaping () -> Bool,
        stringsProvider: @escaping () -> Strings = { L10n().s },
        now: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.keyStore = keyStore
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.notificationClient = notificationClient
        self.authorizationProvider = authorizationProvider
        self.stringsProvider = stringsProvider
        self.now = now
    }

    // MARK: - 生命周期

    /// 启动：立即拉取一次 + 按配置间隔定时刷新（对齐 TokenUsageManager 惯例）。
    func start() {
        guard !isActive else { return }
        isActive = true
        let settings = preferences.configuration.deepSeekBalanceSettings
        lastAlertEnabled = settings.lowBalanceAlertEnabled
        lastThreshold = settings.lowBalanceThreshold
        observePreferences()
        rescheduleTimer()
        refresh()
    }

    func stop() {
        isActive = false
        timer?.cancel()
        preferencesCancellable?.cancel()
        lowBalanceReported = false
    }

    /// 手动刷新入口（面板/设置调用；单飞合并并发刷新）。
    func refreshNow() {
        refresh()
    }

    // MARK: - 设置入口

    /// 保存 API Key：写钥匙串 + 复位告警标志 + 立即刷新（空串拒绝）。
    func saveAPIKey(_ apiKey: String) throws {
        let sanitized = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { throw DeepSeekBalanceError.emptyAPIKey }
        try keyStore.writeAPIKey(sanitized)
        lowBalanceReported = false
        apiKeyConfigured = true
        refresh()
    }

    /// 删除 API Key（幂等）：清空快照与标志，卡隐藏。
    func deleteAPIKey() throws {
        try keyStore.deleteAPIKey()
        apiKeyConfigured = false
        snapshot = nil
        lowBalanceReported = false
    }

    // MARK: - 拉取

    private func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task { [weak self] in
            guard let self else { return }
            await self.fetchOnce()
            self.isFetching = false
        }
    }

    private func fetchOnce() async {
        let key: String?
        do {
            key = try keyStore.readAPIKey()
        } catch {
            key = nil // 钥匙串不可用 → 视为未配置
        }
        guard let key, !key.isEmpty else {
            applyNotConfigured()
            return
        }
        if !apiKeyConfigured {
            apiKeyConfigured = true
            lowBalanceReported = false
        }

        do {
            let object = try await fetcher.getJSON(
                url: Self.endpoint,
                headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
                timeout: ProviderAPIClient.defaultRequestTimeout
            )
            guard let response = DeepSeekBalanceResponseDecoder.decode(object) else {
                applyFailure(.decoding("balance_infos missing"))
                return
            }
            applySuccess(response)
        } catch let error as LimitError {
            applyFailure(error)
        } catch {
            applyFailure(.network(error.localizedDescription))
        }
    }

    /// 成功：新快照（新鲜、无 issue）→ 低余额判定。
    private func applySuccess(_ response: DeepSeekBalanceResponse) {
        snapshot = DeepSeekBalanceSnapshot(
            configured: true,
            isAvailable: response.isAvailable,
            infos: response.infos,
            capturedAt: now(),
            stale: false,
            issue: nil
        )
        evaluateLowBalance()
    }

    /// 失败降级：有旧值 → 保留数值 + stale + issue（capturedAt 不动）；
    /// 从未成功 → 空 infos + issue（卡只渲染错误行）。
    private func applyFailure(_ issue: LimitError) {
        if let current = snapshot, !current.infos.isEmpty {
            snapshot = DeepSeekBalanceSnapshot(
                configured: true,
                isAvailable: current.isAvailable,
                infos: current.infos,
                capturedAt: current.capturedAt,
                stale: true,
                issue: issue
            )
        } else {
            snapshot = DeepSeekBalanceSnapshot(
                configured: true,
                isAvailable: false,
                infos: [],
                capturedAt: now(),
                stale: false,
                issue: issue
            )
        }
    }

    /// 未配置（密钥缺失或钥匙串不可用）：零请求以外的状态复位，卡隐藏。
    private func applyNotConfigured() {
        if apiKeyConfigured {
            apiKeyConfigured = false
        }
        snapshot = nil
        lowBalanceReported = false
    }

    // MARK: - 低余额告警

    /// 仅新鲜快照参与判定；CNY 口径 ≤ 阈值触发。
    /// 跨阈值单次：`lowBalanceReported` 置位后不再重复；恢复（>阈值）或告警设置边沿复位。
    private func evaluateLowBalance() {
        guard let snapshot, snapshot.issue == nil, !snapshot.stale else { return }
        let settings = preferences.configuration.deepSeekBalanceSettings
        let response = DeepSeekBalanceResponse(isAvailable: snapshot.isAvailable, infos: snapshot.infos)
        guard DeepSeekLowBalanceEvaluator.crossedThreshold(in: response, threshold: settings.lowBalanceThreshold) else {
            lowBalanceReported = false // 恢复（或首次高于阈值）
            return
        }
        guard settings.lowBalanceAlertEnabled, !lowBalanceReported else { return }
        // 未授权（或非 .app 宿主）：静默且不置位——授权后下次刷新自动补发。
        guard authorizationProvider() else { return }
        lowBalanceReported = true
        postLowBalanceAlert(snapshot: snapshot, threshold: settings.lowBalanceThreshold)
    }

    private func postLowBalanceAlert(snapshot: DeepSeekBalanceSnapshot, threshold: Double) {
        let strings = stringsProvider()
        let amountText = DeepSeekBalanceFormat.amount(
            cnyInfo(in: snapshot)?.totalBalance,
            rawText: cnyInfo(in: snapshot)?.totalBalanceText,
            currency: "CNY"
        )
        let thresholdText = DeepSeekBalanceFormat.amount(Decimal(threshold), rawText: nil, currency: "CNY")
        let body = String(format: strings.deepSeekAlertBodyFormat, amountText, thresholdText)
        // 投递失败静默降级（对齐 TokenUsageAlertManager）。
        notificationClient.post(title: strings.deepSeekAlertTitle, body: body) { _ in }
    }

    private func cnyInfo(in snapshot: DeepSeekBalanceSnapshot) -> DeepSeekBalanceInfo? {
        snapshot.infos.first { $0.currency == "CNY" }
    }

    // MARK: - 定时与偏好

    private func observePreferences() {
        preferencesCancellable = preferences.$configuration
            .sink { [weak self] config in
                self?.handleConfigurationChange(config)
            }
    }

    /// 配置变化：告警开关/阈值边沿 → 复位上报标志；刷新间隔变化 → 重排定时器。
    /// 注意：@Published 在 willSet 阶段发值，此刻 `preferences.configuration` 仍是旧值，
    /// 因此这里用事件携带的新配置，不在 `rescheduleTimer` 内回读。
    private func handleConfigurationChange(_ config: TokenUsageConfiguration) {
        let settings = config.deepSeekBalanceSettings
        if settings.lowBalanceAlertEnabled != lastAlertEnabled || settings.lowBalanceThreshold != lastThreshold {
            lowBalanceReported = false
        }
        lastAlertEnabled = settings.lowBalanceAlertEnabled
        lastThreshold = settings.lowBalanceThreshold
        if settings.refreshMinutes != scheduledMinutes {
            rescheduleTimer(minutes: settings.refreshMinutes)
        }
    }

    private func rescheduleTimer() {
        rescheduleTimer(minutes: preferences.configuration.deepSeekBalanceSettings.refreshMinutes)
    }

    private func rescheduleTimer(minutes: Int) {
        guard isActive, minutes != scheduledMinutes else { return }
        scheduledMinutes = minutes
        timer?.cancel()
        timer = scheduler.schedule(every: TimeInterval(minutes * 60)) { [weak self] in
            self?.refresh()
        }
    }
}
