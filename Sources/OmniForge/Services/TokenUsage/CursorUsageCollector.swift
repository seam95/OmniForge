import Combine
import Foundation

/// Cursor 用量采集器（C 类云端 API）：云端账单 CSV 定时轮询 → 半小时桶快照 upsert。
///
/// 与本地 JSONL 采集器的差异：
/// - Cursor 无本地逐条日志，用量只有云端账单口径（非实时）→ **无目录监听、无增量游标、
///   无去重**；只做定时轮询（SPEC 4.2 / 参考 08）。
/// - CSV 每轮重新导出即「权威快照」：桶值按本轮导出内该桶的全部行重算，导出窗口外的
///   旧桶保持不动（绝不回零覆盖，对齐 TokenTracker windowed-export 防线）。
/// - 失败（凭证缺失/网络/改版）→ 静默跳过本轮：不写库、不通知、不报错，单家失败不连坐。
///
/// 隐私红线（SPEC 2.6）：只把行内 token 数字与时间写库；正文、Cost 等字段永不读取落盘。
final class CursorUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .cursor

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时轮询兜底间隔（云端账单非实时，30 分钟足够；参考 TokenTracker 同步节奏）。
    static let defaultPollInterval: TimeInterval = 30 * 60

    /// 轮询计数（测试断言）。
    private(set) var pollCount = 0

    private let store: UsageStoring
    private let credentials: CursorCredentialReading
    private let fetcher: CursorCSVFetching
    private let scheduler: RepeatingScheduling
    private let pollInterval: TimeInterval
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 轮询信号合并：polling = 正在执行；执行中收到的信号置 rescanRequested。
    private var polling = false
    private var rescanRequested = false
    private var backfillCompleted = false

    init(
        store: UsageStoring,
        credentials: CursorCredentialReading = CursorVSCDBCredentialReader(),
        fetcher: CursorCSVFetching = CursorWebAPIClient(),
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        pollInterval: TimeInterval = CursorUsageCollector.defaultPollInterval
    ) {
        self.store = store
        self.credentials = credentials
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.pollInterval = pollInterval
    }

    // MARK: - UsageCollecting

    /// 测试环境检测（仓库既有约定：与 Claude/Codex/Kimi 采集器一致）。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）凭证路径构造。
    private var usesRealCredentialPaths: Bool {
        (credentials as? CursorVSCDBCredentialReader)?.usesDefaultPaths ?? false
    }

    func start() {
        guard !started else { return }
        started = true
        guard !(isRunningUnitTests && usesRealCredentialPaths) else { return }
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
        guard let bundle = try? credentials.readBundle() else { return }
        let csv: String
        do {
            csv = try await fetcher.fetchUsageCSV(cookie: bundle.sessionCookie)
        } catch {
            return // 网络/改版/Cloudflare：静默降级自身（不写库、不通知、不报错）
        }
        let rows = CursorUsageProcessing.parseCSV(csv)
        // 空导出（0 行也是合法响应，如新账号）→ 无写入无通知：用量区块保持原有显隐。
        guard !rows.isEmpty else { return }
        let isBackfill = !backfillCompleted
        if isBackfill {
            notifyBackfill(true)
        }
        for state in CursorUsageProcessing.bucketStates(rows: rows, provider: provider) {
            store.upsertBucket(state)
        }
        if isBackfill {
            backfillCompleted = true
            notifyBackfill(false)
        }
        notifyUsageChanged()
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
