import Combine
import Foundation
import GRDB

/// Antigravity（CLI + IDE 扩展）用量采集器。
///
/// 数据源：两个目录下的会话库 `<uuid>.db`（SQLite，同 schema）：
/// - CLI：`~/.gemini/antigravity-cli/conversations`；
/// - IDE：`~/.gemini/antigravity/conversations`。
///
/// 采集语义：
/// - 每轮枚举两个目录的 `*.db`，用内存 `(size, mtime)` 指纹跳过未变化库；
/// - 只读打开（`Configuration.readonly = true`），解析 `gen_metadata` / `steps` /
///   `trajectory_metadata_blob` 的 protobuf blob，按字段号取 token/时间/模型/responseId；
/// - 每库解析结果先在内存聚合，本轮全部库解析完后用 `store.commitScan` **一次事务**提交；
/// - 去重 key 持久化在 `message_seen`：同一 responseId 跨扫描只计一次；
/// - 任何库解析失败（坏库/缺表/坏列/坏 blob）静默跳过：不写库、不报错、不打印内容。
///
/// 隐私红线（SPEC 2.6）：生成 blob 含对话正文；本采集器只按字段号读取数值字段，
/// blob 永不落库、永不打印。
final class AntigravityUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .antigravity

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（与本地采集器一致：5 分钟）。
    static let defaultScanInterval: TimeInterval = 5 * 60

    /// CLI 会话库默认目录。
    static var defaultCLIConversationsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
    }

    /// IDE 扩展会话库默认目录。
    static var defaultIDEConversationsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/conversations", isDirectory: true)
    }

    /// 扫描轮次计数（测试断言）。
    private(set) var scanCount = 0
    /// 实际打开解析的库文件数（指纹未变的库被跳过；测试断言）。
    private(set) var parsedFileCount = 0

    private let store: UsageStoring
    private let cliConversationsDirectory: URL
    private let ideConversationsDirectory: URL
    private let scheduler: RepeatingScheduling
    private let scanInterval: TimeInterval
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let triggerLock = NSLock()
    private var timer: AnyCancellable?
    private var started = false
    /// 扫描信号合并：scanning = 已排队/正在执行的扫描；扫描中收到的信号置 rescanRequested。
    private var scanning = false
    private var rescanRequested = false
    private var backfillCompleted = false
    /// 库文件 → (size, mtime) 指纹；未变化则跳过解析（首次全部解析）。
    private var fileSignatures: [String: FileSignature] = [:]

    /// 单个库文件的版本指纹。
    struct FileSignature: Equatable {
        var size: UInt64
        var modificationDate: Date
    }

    init(
        store: UsageStoring,
        cliConversationsDirectory: URL = AntigravityUsageCollector.defaultCLIConversationsDirectory,
        ideConversationsDirectory: URL = AntigravityUsageCollector.defaultIDEConversationsDirectory,
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        scanInterval: TimeInterval = AntigravityUsageCollector.defaultScanInterval,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.cliConversationsDirectory = cliConversationsDirectory
        self.ideConversationsDirectory = ideConversationsDirectory
        self.scheduler = scheduler
        self.scanInterval = scanInterval
        self.fileManager = fileManager
        self.queue = DispatchQueue(
            label: "omniForge.tokenUsage.antigravityCollector",
            qos: .utility
        )
    }

    // MARK: - UsageCollecting

    /// 测试进程检测（仓库既有约定：与 Cursor/Claude/Codex 采集器一致）。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）目录构造。
    private var usesRealDirectories: Bool {
        cliConversationsDirectory.standardizedFileURL == Self.defaultCLIConversationsDirectory.standardizedFileURL
            || ideConversationsDirectory.standardizedFileURL == Self.defaultIDEConversationsDirectory.standardizedFileURL
    }

    /// 启动：立即返回；首次扫描即后台回填（首尾回填标记）。
    func start() {
        guard !started else { return }
        started = true
        // 测试进程用真实目录构造时不得扫描：避免测试读用户真实会话库。
        guard !(isRunningUnitTests && usesRealDirectories) else { return }
        timer = scheduler.schedule(every: scanInterval) { [weak self] in
            self?.triggerScan()
        }
        triggerScan()
    }

    func stop() {
        guard started else { return }
        started = false
        timer?.cancel()
        timer = nil
    }

    /// 线程安全：等待串行队列排空（测试用）。
    func waitForIdle() {
        queue.sync {}
    }

    // MARK: - 扫描调度（信号合并）

    /// 触发一次扫描：扫描中到达的多个信号只追加一次「重新扫描」。
    private func triggerScan() {
        triggerLock.lock()
        if scanning {
            rescanRequested = true
            triggerLock.unlock()
            return
        }
        scanning = true
        triggerLock.unlock()
        queue.async { [weak self] in
            self?.performScanCycle()
        }
    }

    /// 串行队列上执行完整一轮扫描（含回填状态与回调通知）。
    private func performScanCycle() {
        scanCount += 1
        let isBackfill = !backfillCompleted
        if isBackfill {
            notifyBackfill(true)
        }

        performScan()

        if isBackfill {
            backfillCompleted = true
            notifyBackfill(false)
        }
        notifyUsageChanged()

        // 锁内直接续跑 rescan：避免 scanning=false 到再次触发之间的空隙产生双触发竞态。
        triggerLock.lock()
        scanning = false
        let again = rescanRequested && started
        rescanRequested = false
        if again {
            scanning = true
        }
        triggerLock.unlock()
        if again {
            queue.async { [weak self] in
                self?.performScanCycle()
            }
        }
    }

    // MARK: - 扫描

    /// 全量一轮：枚举 → 指纹跳过未变库 → 只读解析 → 内存聚合 → 单事务提交。
    private func performScan() {
        let files = enumerateDatabaseFiles()
        guard !files.isEmpty else { return }

        let accumulator = ScanAccumulator(provider: provider, store: store)
        var pendingSignatures: [String: FileSignature] = [:]

        for file in files {
            let signature = fileSignature(for: file.url)
            if let signature, fileSignatures[file.url.path] == signature {
                continue // 未变化：跳过解析（回填后的常态路径）
            }
            parsedFileCount += 1
            guard let generations = loadGenerations(from: file) else {
                continue // 坏库/缺表/被锁：静默跳过，不缓存指纹 → 下轮重试
            }
            for generation in generations {
                accumulator.ingest(generation)
            }
            if let signature {
                pendingSignatures[file.url.path] = signature
            }
        }

        let buckets = accumulator.drainBuckets()
        guard !buckets.isEmpty else {
            // 解析成功但无新增（重复扫描/空库）：只推进文件指纹，不写事务。
            fileSignatures.merge(pendingSignatures) { _, latest in latest }
            return
        }

        var commit = ScanCommit()
        commit.buckets = buckets
        commit.newSeenKeys = accumulator.drainNewSeen()
        commit.seenAt = Date()
        do {
            try store.commitScan(commit)
            fileSignatures.merge(pendingSignatures) { _, latest in latest }
        } catch {
            // 提交失败：不推进指纹与去重进度，下一轮重扫重算（桶累计快照幂等）。
            print("[AntigravityUsageCollector] commitScan failed, will retry next scan: \(error)")
        }
    }

    // MARK: - 文件枚举

    /// 单个待扫描库文件及其来源客户端。
    private struct DatabaseFile {
        let url: URL
        let client: AntigravityClientKind
    }

    /// 枚举两个目录下的 `*.db`（跳过 -wal/-shm、目录、隐藏文件），按路径稳定排序。
    private func enumerateDatabaseFiles() -> [DatabaseFile] {
        let directories: [(URL, AntigravityClientKind)] = [
            (cliConversationsDirectory, .cli),
            (ideConversationsDirectory, .ide),
        ]
        var files: [DatabaseFile] = []
        for (directory, client) in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue // 目录不存在/不可读：静默跳过（该客户端未安装）
            }
            for url in entries where url.pathExtension.lowercased() == "db" {
                let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues?.isRegularFile ?? false else { continue }
                files.append(DatabaseFile(url: url.standardizedFileURL, client: client))
            }
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    /// 读取 (size, mtime) 指纹；属性缺失 → nil（不参与跳过缓存，每轮都尝试解析）。
    private func fileSignature(for url: URL) -> FileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileSignature(size: size, modificationDate: modificationDate)
    }

    // MARK: - 只读解析

    /// 只读打开一个会话库并组装生成列表。
    ///
    /// - 表缺失 / 列缺失 / 坏库 → nil（跳过该文件，下轮重试）；
    /// - steps / trajectory 解析失败只降级为空（时间回退链继续走下一级）。
    private func loadGenerations(from file: DatabaseFile) -> [AntigravityGeneration]? {
        let attributes = try? fileManager.attributesOfItem(atPath: file.url.path)
        let sessionID = file.url.deletingPathExtension().lastPathComponent
        let fileModificationDate = attributes?[.modificationDate] as? Date

        if let databaseQueue = Self.readOnlyQueue(at: file.url) {
            if let inputs = try? readInputs(from: databaseQueue) {
                return AntigravityUsageProcessing.makeGenerations(
                    generationRows: inputs.generationRows,
                    stepRows: inputs.stepRows,
                    trajectoryData: inputs.trajectoryData,
                    client: file.client,
                    sessionID: sessionID,
                    fileModificationDate: fileModificationDate
                )
            }
        }
        // Antigravity 退出后 SQLite 会清理 -shm，WAL 库的只读打开随之失败；
        // 用 immutable 快照读取主库，覆盖「应用未运行」这一常态。
        guard let snapshot = AntigravityReadOnlyDatabase(url: file.url),
              let generationRows = snapshot.generationRows() else {
            return nil
        }
        return AntigravityUsageProcessing.makeGenerations(
            generationRows: generationRows,
            stepRows: snapshot.stepRows(),
            trajectoryData: snapshot.trajectoryData(),
            client: file.client,
            sessionID: sessionID,
            fileModificationDate: fileModificationDate
        )
    }

    /// GRDB 只读路径的三段查询（steps / trajectory 失败只降级为空，时间链继续）。
    private func readInputs(
        from databaseQueue: DatabaseQueue
    ) throws -> (generationRows: [(sequence: Int, data: Data)], stepRows: [Data], trajectoryData: Data?) {
        let generationRows: [(sequence: Int, data: Data)] = try databaseQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx"
            ).compactMap { row in
                guard let data = row["data"] as? Data else { return nil }
                return (sequence: Int(row["idx"] as Int64), data: data)
            }
        }
        let stepRows: [Data] = (try? databaseQueue.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT metadata FROM steps WHERE step_type = 15 AND metadata IS NOT NULL"
            )
        }) ?? []
        let trajectoryData: Data? = try? databaseQueue.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT data FROM trajectory_metadata_blob WHERE id = 'main' AND data IS NOT NULL"
            )
        }
        return (generationRows, stepRows, trajectoryData)
    }

    /// GRDB 只读打开（`Configuration.readonly = true`）；失败 → nil。
    private static func readOnlyQueue(at url: URL) -> DatabaseQueue? {
        var configuration = Configuration()
        configuration.readonly = true
        return try? DatabaseQueue(path: url.path, configuration: configuration)
    }

    // MARK: - 单轮去重与聚合

    /// 单轮扫描的共享累加器：已见 key 去重 + 半小时桶内存聚合。
    private final class ScanAccumulator {
        private let provider: TokenUsageProvider
        private let aggregator: UsageAggregator
        /// 扫描开始时持久化的已见 key（跨扫描去重）。
        private let seenKeys: Set<String>
        /// 本轮新见 key（随 commitScan 落库）。
        private var newSeenKeys: Set<String> = []

        init(provider: TokenUsageProvider, store: UsageStoring) {
            self.provider = provider
            self.aggregator = UsageAggregator { [store] key in
                store.loadBucket(key)
            }
            self.seenKeys = store.loadSeenKeys()
        }

        /// 去重通过后累加到对应半小时桶。
        func ingest(_ generation: AntigravityGeneration) {
            let key = generation.deduplicationKey
            guard !seenKeys.contains(key), !newSeenKeys.contains(key) else { return }
            newSeenKeys.insert(key)
            aggregator.ingest(
                usage: generation.usage,
                conversationDelta: generation.conversationDelta,
                key: UsageBucketKey(
                    provider: provider,
                    model: generation.model,
                    bucketStart: generation.bucketStart
                )
            )
        }

        /// 取出本轮被触碰桶的累计快照（写库后复用聚合器也安全）。
        func drainBuckets() -> [UsageBucketState] {
            aggregator.drainTouched()
        }

        /// 取出本轮新见 key 并清空。
        func drainNewSeen() -> Set<String> {
            let drained = newSeenKeys
            newSeenKeys.removeAll()
            return drained
        }
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
