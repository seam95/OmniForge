import Combine
import Foundation

/// trae-cn 用量采集器（C 类云端 API）：opt-in 轮询 → 30 天窗口拉取 → 会话级对账。
///
/// 参照 `CursorUsageCollector` 的 C 类模式（PLAN §4.1）：
/// - 30 分钟轮询（云端账单非实时）；凭证 = 设置页手动 JWT（钥匙串，SPEC R1）；
/// - 窗口拉取（近 30 天、半小时对齐、容量超限递归二分，见 `TraeCnWebAPIClient`）；
/// - 按 session_id 存 canonical 状态，变化时「减旧桶加新桶」对账；空快照不表断言。
/// - 所有失败（未启用/无凭证/网络/解析）静默降级本轮，不阻塞主线程。
///
/// 隐私红线（SPEC 2.6）：JWT 只进请求头，只把 token 数字/时间/模型/会话 id 落库。
final class TraeCnUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .traeCN

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时轮询兜底间隔（云端账单非实时，30 分钟足够）。
    static let defaultPollInterval: TimeInterval = 30 * 60
    /// 回填窗口：近 30 天。
    static let backfillWindowDays = 30

    private(set) var pollCount = 0

    private let store: UsageStoring
    private let preferences: TokenUsagePreferences
    private let keychain: TraeCnJWTAccessing
    private let fetcher: TraeCnUsageFetching
    private let scheduler: RepeatingScheduling
    private let pollInterval: TimeInterval
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    private var polling = false
    private var rescanRequested = false
    private var backfillCompleted = false

    /// 会话 canonical 状态（按 provider 隔离存在消息状态账本）。
    struct SessionState: Codable, Equatable {
        var model: String
        var bucketStart: Double
        var totals: TokenUsage
    }

    init(
        store: UsageStoring,
        preferences: TokenUsagePreferences,
        keychain: TraeCnJWTAccessing = TraeCnKeychainStore(),
        fetcher: TraeCnUsageFetching = TraeCnWebAPIClient(),
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        pollInterval: TimeInterval = TraeCnUsageCollector.defaultPollInterval
    ) {
        self.store = store
        self.preferences = preferences
        self.keychain = keychain
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.pollInterval = pollInterval
    }

    // MARK: - UsageCollecting

    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）凭证/网络构造（测试进程守护）。
    private var usesRealPaths: Bool {
        (keychain as? TraeCnKeychainStore) != nil
    }

    func start() {
        guard !started else { return }
        started = true
        guard !(isRunningUnitTests && usesRealPaths) else { return }
        timer = scheduler.schedule(every: pollInterval) { [weak self] in
            self?.triggerPoll()
        }
        triggerPoll()
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.cancel()
        timer = nil
    }

    // MARK: - 轮询调度（信号合并）

    private func triggerPoll() {
        triggerLock.lock()
        if polling {
            rescanRequested = true
            triggerLock.unlock()
            return
        }
        polling = true
        triggerLock.unlock()
        Task { [weak self] in
            await self?.performPollCycle()
        }
    }

    private func performPollCycle() async {
        defer {
            triggerLock.lock()
            polling = false
            let again = rescanRequested && started
            rescanRequested = false
            triggerLock.unlock()
            if again {
                triggerPoll()
            }
        }
        pollCount += 1
        // opt-in + 凭证守卫：未启用/无 JWT → 静默跳过本轮。
        guard preferences.configuration.traeCnEnabled else { return }
        guard let jwt = try? keychain.readJWT(), !jwt.isEmpty else { return }

        let now = Date()
        let windowEnd = TraeCnUsageProcessing.bucketStart(fromMilliseconds: now.timeIntervalSince1970 * 1000)
            .addingTimeInterval(1800)
        let windowStart = windowEnd.addingTimeInterval(
            -Double(Self.backfillWindowDays * 24 * 3600)
        )
        let rows: [TraeCnSessionRow]
        do {
            rows = try await fetcher.fetchSessions(
                jwt: jwt,
                startMs: windowStart.timeIntervalSince1970 * 1000,
                endMs: windowEnd.timeIntervalSince1970 * 1000
            )
        } catch {
            return // 网络/凭证/解析失败：静默降级自身（不写库、不通知、不报错）
        }
        // 空快照不表断言：无用量变更、无状态记录。
        guard !rows.isEmpty else { return }

        // 全量预校验：任一行不可解析 → 整轮 fail-closed（部分快照不作权威）。
        var contributions: [String: TraeCnUsageProcessing.Contribution] = [:]
        for row in rows {
            guard let sessionID = row.sessionId, !sessionID.isEmpty,
                  let contribution = TraeCnUsageProcessing.contribution(from: row) else {
                return
            }
            contributions[sessionID] = contribution
        }

        let isBackfill = !backfillCompleted
        if isBackfill {
            notifyBackfill(true)
        }
        reconcile(contributions: contributions, now: now)
        if isBackfill {
            backfillCompleted = true
            notifyBackfill(false)
        }
        notifyUsageChanged()
    }

    /// 会话级对账：状态账本（providerMessageState）→ 减旧桶加新桶。
    private func reconcile(contributions: [String: TraeCnUsageProcessing.Contribution], now: Date) {
        var state = store.loadProviderMessageState(provider)
        let aggregator = UsageAggregator { [store] key in
            store.loadBucket(key)
        }
        var changed = false
        for (sessionID, contribution) in contributions.sorted(by: { $0.key < $1.key }) {
            let currentState = SessionState(
                model: contribution.model,
                bucketStart: contribution.bucketStart.timeIntervalSince1970,
                totals: contribution.usage
            )
            let previous = SessionState.decode(state[sessionID])
            if previous == currentState {
                continue
            }
            // 减旧：上次入桶的贡献从旧桶扣回。
            if let previous {
                let oldKey = UsageBucketKey(
                    provider: provider,
                    model: previous.model,
                    bucketStart: Date(timeIntervalSince1970: previous.bucketStart)
                )
                aggregator.ingest(
                    usage: negated(previous.totals),
                    conversationDelta: -1,
                    key: oldKey
                )
            }
            // 加新：当前贡献入当前桶。
            aggregator.ingest(
                usage: contribution.usage,
                conversationDelta: 1,
                key: UsageBucketKey(
                    provider: provider,
                    model: contribution.model,
                    bucketStart: contribution.bucketStart
                )
            )
            state[sessionID] = currentState.encode()
            changed = true
        }
        guard changed else { return }
        for bucket in aggregator.drainTouched() {
            store.upsertBucket(bucket)
        }
        store.storeProviderMessageState(provider, entries: state)
    }

    private func negated(_ usage: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: -usage.inputTokens,
            cachedInputTokens: -usage.cachedInputTokens,
            cacheCreationInputTokens: -usage.cacheCreationInputTokens,
            outputTokens: -usage.outputTokens,
            reasoningOutputTokens: -usage.reasoningOutputTokens,
            totalTokens: -usage.totalTokens
        )
    }

    // MARK: - 通知

    private func notifyUsageChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onUsageDidChange?(self.provider)
        }
    }

    private func notifyBackfill(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onBackfillStateChange?(value)
        }
    }
}

// MARK: - 状态编解码

extension TraeCnUsageCollector.SessionState {
    static func decode(_ payload: String?) -> TraeCnUsageCollector.SessionState? {
        guard let payload, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TraeCnUsageCollector.SessionState.self, from: data)
    }

    func encode() -> String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}