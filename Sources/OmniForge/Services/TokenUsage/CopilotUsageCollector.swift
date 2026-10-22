import Combine
import Foundation
import GRDB
import SQLite3

// MARK: - 只读读取结果

/// session-store.db 单文件读取结果（区分「表缺失」与「打不开」，前者可缓存指纹）。
/// internal 供测试直接覆盖 GRDB/immutable 两条读取路径。
enum CopilotSessionStoreReadResult {
    /// 表存在并读取成功（空数组 = 表内无用量行）。
    case rows([CopilotSessionUsageRow])
    /// 库内没有 assistant_usage_events 表（如 VS Code 的 session 索引库）：静默跳过。
    case missingTable
    /// 打不开/被锁/格式错误：本轮跳过，下轮重试（不缓存指纹）。
    case unavailable
}

/// OTEL JSONL 单文件读取结果。
private enum CopilotOTELFileReadResult {
    /// 解析结果（空数组 = 文件可读但无用量记录）。
    case events([CopilotUsageEvent])
    /// 超出大小上限：本文件永久跳过（缓存指纹，避免每轮重读）。
    case skipped
    /// 读取失败（权限/占用）：下轮重试（不缓存指纹）。
    case unavailable
}

// MARK: - 采集器

/// GitHub Copilot 用量采集器（A/C 混合：本地 SQLite 主源 + OTEL JSONL 兜底）。
///
/// 数据源：
/// 1. **session-store.db**（SQLite，表 assistant_usage_events）：
///    - VS Code Copilot Chat：`~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/session-store.db`
///      （任务指定路径；注意当前 VS Code 版本该库是会话索引库，无用量表时会静默跳过）；
///    - Copilot CLI：`~/.copilot/session-store.db`（与 tokscale 权威解析器同 schema，本机实测路径）；
///    - VS Code Insiders 同构路径（存在则扫描）。
/// 2. **OTEL JSONL**（可选）：`~/.copilot/otel/**/*.jsonl` 与
///    `COPILOT_OTEL_FILE_EXPORTER_PATH` 指定的导出文件。
///
/// 采集语义（对齐 AntigravityUsageCollector，独立实现 UsageCollecting）：
/// - 每轮枚举并解析，内存 `(size, mtime)` 指纹跳过未变化文件；数据库指纹额外包含
///   `-wal/-shm` 侧文件——WAL 模式下主库 mtime 可能不变，只看主库会漏掉新写入；
/// - GRDB 只读打开（`Configuration.readonly = true`）；失败时用 SQLite3 `immutable=1`
///   快照兜底（覆盖应用退出后 -shm 被清理、WAL 库只读打开失败这一常态）；
/// - 每轮全部文件解析完，用 `store.commitScan` 一次事务提交桶 + 新见去重 key；
/// - 坏库/缺表/被锁/坏行全部静默跳过：不写库、不报错、不打印内容；失败不缓存指纹，下轮重试；
/// - 每轮结束（无论有无数据）通知管理器刷新快照；首轮扫描为「回填」，首尾标记。
///
/// 隐私红线（SPEC 2.6）：只读取 token 数字、时间、模型与身份字段；prompt/正文/工具输出
/// 从不物化，数据库只读打开、绝不写入。
final class CopilotUsageCollector: UsageCollecting {
    let provider: TokenUsageProvider = .copilot

    var onUsageDidChange: ((TokenUsageProvider) -> Void)?
    var onBackfillStateChange: ((Bool) -> Void)?

    /// 定时兜底间隔（与其它本地采集器一致：5 分钟）。
    static let defaultScanInterval: TimeInterval = 5 * 60

    /// OTEL JSONL 单文件大小上限（超过则跳过，避免把超大导出整体读入内存）。
    static let maximumOTELFileBytes = 64 * 1024 * 1024

    // MARK: - 默认路径

    /// 默认 session-store.db 路径（按优先级排列；不存在的路径静默跳过）。
    static func defaultDatabaseURLs(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [URL] {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        return [
            // 任务指定的 VS Code Copilot Chat 路径（当前版本为会话索引库）。
            home.appendingPathComponent(
                "Library/Application Support/Code/User/globalStorage/github.copilot-chat/session-store.db"
            ),
            // VS Code Insiders 同构路径。
            home.appendingPathComponent(
                "Library/Application Support/Code - Insiders/User/globalStorage/github.copilot-chat/session-store.db"
            ),
            // Copilot CLI 用量库（assistant_usage_events schema，tokscale 权威参考）。
            home.appendingPathComponent(".copilot/session-store.db"),
        ]
    }

    /// 默认 OTEL 导出目录（Copilot CLI 的 file exporter 默认落盘位置）。
    static func defaultOTELDirectories(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [URL] {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        return [home.appendingPathComponent(".copilot/otel", isDirectory: true)]
    }

    /// 环境变量指定的 OTEL 导出文件（Copilot CLI 的 file exporter 配置）。
    static func defaultOTELExporterFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard let raw = environment["COPILOT_OTEL_FILE_EXPORTER_PATH"] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    // MARK: - 状态

    /// 扫描轮次计数（测试断言）。
    private(set) var scanCount = 0
    /// 实际打开解析的数据库数（指纹未变的库被跳过；测试断言）。
    private(set) var parsedDatabaseCount = 0
    /// 实际打开解析的 OTEL 文件数（指纹未变的文件被跳过；测试断言）。
    private(set) var parsedOTELFileCount = 0

    private let store: UsageStoring
    private let databaseURLs: [URL]
    private let otelDirectories: [URL]
    private let otelExporterFile: URL?
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
    /// 文件路径 → 指纹；未变化则跳过解析（首次全部解析）。
    private var fileSignatures: [String: FileFingerprint] = [:]

    // MARK: - 指纹

    /// 单文件版本指纹。
    struct FileSignature: Equatable {
        var size: UInt64
        var modificationDate: Date
    }

    /// 文件指纹：主文件 + SQLite WAL/shm 侧文件。
    struct FileFingerprint: Equatable {
        var size: UInt64
        var modificationDate: Date
        /// 侧文件指纹（顺序固定 `-wal`、`-shm`；不存在则为空）。
        var sidecars: [FileSignature]
    }

    // MARK: - 初始化

    init(
        store: UsageStoring,
        databaseURLs: [URL] = CopilotUsageCollector.defaultDatabaseURLs(),
        otelDirectories: [URL] = CopilotUsageCollector.defaultOTELDirectories(),
        otelExporterFile: URL? = CopilotUsageCollector.defaultOTELExporterFile(),
        scheduler: RepeatingScheduling = TimerRepeatingScheduler(),
        scanInterval: TimeInterval = CopilotUsageCollector.defaultScanInterval,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.databaseURLs = databaseURLs.map(\.standardizedFileURL)
        self.otelDirectories = otelDirectories.map(\.standardizedFileURL)
        self.otelExporterFile = otelExporterFile?.standardizedFileURL
        self.scheduler = scheduler
        self.scanInterval = scanInterval
        self.fileManager = fileManager
        self.queue = DispatchQueue(
            label: "omniForge.tokenUsage.copilotCollector",
            qos: .utility
        )
    }

    // MARK: - UsageCollecting

    /// 测试进程检测（仓库既有约定：与 Cursor/Claude/Codex 采集器一致）。
    private var isRunningUnitTests: Bool {
        let hasXCTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return hasXCTestEnvironment || ProcessInfo.processInfo.processName == "xctest"
    }

    /// 是否以默认（真实用户）路径构造。
    private var usesRealPaths: Bool {
        databaseURLs == Self.defaultDatabaseURLs().map(\.standardizedFileURL)
            && otelDirectories == Self.defaultOTELDirectories().map(\.standardizedFileURL)
            && otelExporterFile == Self.defaultOTELExporterFile()?.standardizedFileURL
    }

    /// 启动：立即返回；首次扫描即后台回填（首尾回填标记）。
    func start() {
        guard !started else { return }
        started = true
        // 测试进程用真实路径构造时不得扫描：避免测试读用户真实会话库。
        guard !(isRunningUnitTests && usesRealPaths) else { return }
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

    /// 全量一轮：枚举 → 指纹跳过未变文件 → 只读解析 → 内存聚合 → 单事务提交。
    private func performScan() {
        let accumulator = ScanAccumulator(provider: provider, store: store)
        var pendingSignatures: [String: FileFingerprint] = [:]

        // 1. session-store.db（主源）。
        for databaseURL in databaseURLs {
            guard fileManager.fileExists(atPath: databaseURL.path),
                  let fingerprint = Self.fileFingerprint(
                      forPath: databaseURL.path,
                      fileManager: fileManager
                  ) else {
                continue
            }
            let path = databaseURL.path
            if fileSignatures[path] == fingerprint { continue }
            parsedDatabaseCount += 1
            let result = readSessionStoreEvents(from: databaseURL)
            guard case .unavailable = result else {
                if case let .rows(rows) = result {
                    for event in CopilotUsageProcessing.sessionStoreEvents(rows) {
                        accumulator.ingest(event)
                    }
                }
                // .missingTable 与 .rows 都代表库可读：缓存指纹，避免每轮重开 VS Code 索引库。
                pendingSignatures[path] = fingerprint
                continue
            }
        }

        // 2. OTEL JSONL（可选兜底）。
        for otelURL in enumerateOTELFiles() {
            guard let fingerprint = Self.fileFingerprint(
                forPath: otelURL.path,
                fileManager: fileManager
            ) else {
                continue
            }
            let path = otelURL.path
            if fileSignatures[path] == fingerprint { continue }
            parsedOTELFileCount += 1
            switch readOTELFile(from: otelURL) {
            case .unavailable:
                continue // 不缓存指纹：下轮重试
            case .skipped:
                pendingSignatures[path] = fingerprint
            case let .events(events):
                for event in events {
                    accumulator.ingest(event)
                }
                pendingSignatures[path] = fingerprint
            }
        }

        // 3. 单事务提交桶 + 新见 key；提交失败不推进任何指纹，下轮重扫重算。
        let buckets = accumulator.drainBuckets()
        guard !buckets.isEmpty else {
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
            print("[CopilotUsageCollector] commitScan failed, will retry next scan: \(error)")
        }
    }

    // MARK: - 文件指纹与枚举

    /// 文件指纹（主文件 + `-wal`/`-shm` 侧文件）；主文件属性不可读 → nil。
    static func fileFingerprint(
        forPath path: String,
        fileManager: FileManager = .default
    ) -> FileFingerprint? {
        guard let main = fileSignature(forPath: path, fileManager: fileManager) else { return nil }
        var sidecars: [FileSignature] = []
        for suffix in ["-wal", "-shm"] {
            if let signature = fileSignature(forPath: path + suffix, fileManager: fileManager) {
                sidecars.append(signature)
            }
        }
        return FileFingerprint(
            size: main.size,
            modificationDate: main.modificationDate,
            sidecars: sidecars
        )
    }

    private static func fileSignature(
        forPath path: String,
        fileManager: FileManager
    ) -> FileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileSignature(size: size, modificationDate: modificationDate)
    }

    /// 枚举 OTEL JSONL：目录递归 + 环境变量指定的导出文件（去重、按路径稳定排序）。
    private func enumerateOTELFiles() -> [URL] {
        var files: [URL] = []
        var seenPaths = Set<String>()

        for directory in otelDirectories {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue // 目录不存在/不可读：静默跳过（OTEL 未启用）
            }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues?.isRegularFile ?? false else { continue }
                let standardized = url.standardizedFileURL
                if seenPaths.insert(standardized.path).inserted {
                    files.append(standardized)
                }
            }
        }

        if let exporter = otelExporterFile,
           fileManager.fileExists(atPath: exporter.path),
           seenPaths.insert(exporter.path).inserted {
            files.append(exporter)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - session-store.db 只读解析

    /// 只读打开一个 session-store.db 并读取用量行。
    ///
    /// 主路径 GRDB 只读（能正确处理 WAL），失败时降级 SQLite3 immutable 快照。
    private func readSessionStoreEvents(from url: URL) -> CopilotSessionStoreReadResult {
        if let queue = Self.readOnlyQueue(at: url),
           let result = try? Self.readSessionStoreRows(from: queue) {
            return result
        }
        // WAL 库只读打开失败（-shm 缺失/不可写、应用已退出）→ immutable 快照兜底。
        guard let snapshot = CopilotImmutableDatabase(url: url) else { return .unavailable }
        return snapshot.readUsageRows()
    }

    /// GRDB 只读打开（`Configuration.readonly = true`）；失败 → nil。
    private static func readOnlyQueue(at url: URL) -> DatabaseQueue? {
        var configuration = Configuration()
        configuration.readonly = true
        return try? DatabaseQueue(path: url.path, configuration: configuration)
    }

    /// 读 usage 行：优先带 sessions JOIN（会话创建时间兜底）；sessions 缺失时退回单表查询。
    private static func readSessionStoreRows(from queue: DatabaseQueue) throws -> CopilotSessionStoreReadResult {
        try queue.read { db in
            guard try db.tableExists("assistant_usage_events") else { return .missingTable }
            let joinSQL = """
            SELECT e.*, s.created_at AS session_created_at
            FROM assistant_usage_events AS e
            LEFT JOIN sessions AS s ON s.id = e.session_id
            ORDER BY e.rowid
            """
            if let rows = try? Row.fetchAll(db, sql: joinSQL) {
                return .rows(rows.compactMap { Self.sessionUsageRow(from: $0) })
            }
            // sessions 表/列缺失：无会话时间兜底，其余字段照常解析。
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM assistant_usage_events")
            return .rows(rows.compactMap { Self.sessionUsageRow(from: $0) })
        }
    }

    /// GRDB Row → 纯值行（只取已知列；缺列返回 nil/0）。
    private static func sessionUsageRow(from row: Row) -> CopilotSessionUsageRow? {
        guard let sessionID = row["session_id"] as String? else { return nil }
        return CopilotSessionUsageRow(
            eventID: row["id"] as Int64?,
            sessionID: sessionID,
            turnIndex: row["turn_index"] as Int64?,
            model: row["model"] as String?,
            copilotUsageModel: row["copilot_usage_model"] as String?,
            inputTokens: tokenCount(row, "input_tokens"),
            outputTokens: tokenCount(row, "output_tokens"),
            cacheReadTokens: tokenCount(row, "cache_read_tokens"),
            cacheWriteTokens: tokenCount(row, "cache_write_tokens"),
            reasoningTokens: tokenCount(row, "reasoning_tokens"),
            createdAt: row["created_at"] as String?,
            sessionCreatedAt: row["session_created_at"] as String?
        )
    }

    private static func tokenCount(_ row: Row, _ column: String) -> Int {
        Int(clamping: (row[column] as Int64?) ?? 0)
    }

    // MARK: - OTEL 文件解析

    /// 读取一个 OTEL JSONL 文件：逐行解析 JSON，坏行跳过。
    private func readOTELFile(from url: URL) -> CopilotOTELFileReadResult {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .unavailable
        }
        guard data.count <= Self.maximumOTELFileBytes else { return .skipped }

        var records: [[String: Any]] = []
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let record = CopilotUsageProcessing.parseOTELLine(String(line)) {
                records.append(record)
            }
        }
        let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let fallbackTimestamp = modified.map { $0.timeIntervalSince1970 * 1000 }
        return .events(CopilotUsageProcessing.otelEvents(
            records: records,
            fallbackTimestampMilliseconds: fallbackTimestamp
        ))
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
        func ingest(_ event: CopilotUsageEvent) {
            guard !seenKeys.contains(event.deduplicationKey),
                  !newSeenKeys.contains(event.deduplicationKey) else {
                return
            }
            newSeenKeys.insert(event.deduplicationKey)
            aggregator.ingest(
                usage: event.usage,
                conversationDelta: event.conversationDelta,
                key: UsageBucketKey(
                    provider: provider,
                    model: event.model,
                    bucketStart: event.bucketStart
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

// MARK: - immutable 只读快照兜底

/// session-store.db 的只读 immutable 快照读取（GRDB 只读打开失败时的兜底）。
///
/// 背景：WAL 模式库的只读连接需要同目录可用的 `-shm` 文件；Copilot CLI/VS Code
/// 退出后 SQLite 会清理侧文件，只读打开随之失败（SQLite error 14）。用 `immutable=1`
/// URI 打开主库可忽略不可用的 WAL 侧文件，覆盖「应用未运行」这一常态。
///
/// 只用于 GRDB 失败后的兜底，不写任何文件。若写入方仍在运行，immutable 快照可能漏掉
/// WAL 中的最新数据——主路径（GRDB 只读）正常时不会走到这里。
final class CopilotImmutableDatabase {
    private var handle: OpaquePointer?

    init?(url: URL) {
        var database: OpaquePointer?
        // 路径可能含空格/中文：SQLite 的 URI 文件名要求百分号编码。
        let encodedPath = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? url.path
        let uri = "file:\(encodedPath)?immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        handle = database
    }

    deinit {
        sqlite3_close(handle)
    }

    /// 读取 assistant_usage_events（含 sessions 时间兜底的单表回退）。
    func readUsageRows() -> CopilotSessionStoreReadResult {
        guard let handle else { return .unavailable }
        switch tableExists("assistant_usage_events", handle: handle) {
        case .exists: break
        case .missing: return .missingTable
        case .failed: return .unavailable
        }

        let joinSQL = """
        SELECT e.*, s.created_at AS session_created_at
        FROM assistant_usage_events AS e
        LEFT JOIN sessions AS s ON s.id = e.session_id
        ORDER BY e.rowid
        """
        if let rows = rows(matching: joinSQL, handle: handle) {
            return .rows(rows)
        }
        if let rows = rows(matching: "SELECT * FROM assistant_usage_events", handle: handle) {
            return .rows(rows)
        }
        return .unavailable
    }

    /// 表存在性三态：prepare 失败（非 SQLite 文件/损坏）与「表不存在」必须区分。
    private enum TableExistence {
        case exists
        case missing
        case failed
    }

    private func tableExists(_ name: String, handle: OpaquePointer) -> TableExistence {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement else {
            return .failed
        }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_text(prepared, 1, name, -1, Self.sqliteTransient)
        return sqlite3_step(prepared) == SQLITE_ROW ? .exists : .missing
    }

    private func rows(matching sql: String, handle: OpaquePointer) -> [CopilotSessionUsageRow]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let prepared = statement else {
            return nil
        }
        defer { sqlite3_finalize(prepared) }

        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(prepared) {
            guard let name = sqlite3_column_name(prepared, index) else { continue }
            columns[String(cString: name)] = index
        }

        var result: [CopilotSessionUsageRow] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard let row = Self.sessionUsageRow(statement: prepared, columns: columns) else {
                continue
            }
            result.append(row)
        }
        return result
    }

    private static func sessionUsageRow(
        statement: OpaquePointer,
        columns: [String: Int32]
    ) -> CopilotSessionUsageRow? {
        guard let sessionID = text(statement, columns["session_id"]) else { return nil }
        return CopilotSessionUsageRow(
            eventID: int64(statement, columns["id"]),
            sessionID: sessionID,
            turnIndex: int64(statement, columns["turn_index"]),
            model: text(statement, columns["model"]),
            copilotUsageModel: text(statement, columns["copilot_usage_model"]),
            inputTokens: tokenCount(statement, columns["input_tokens"]),
            outputTokens: tokenCount(statement, columns["output_tokens"]),
            cacheReadTokens: tokenCount(statement, columns["cache_read_tokens"]),
            cacheWriteTokens: tokenCount(statement, columns["cache_write_tokens"]),
            reasoningTokens: tokenCount(statement, columns["reasoning_tokens"]),
            createdAt: text(statement, columns["created_at"]),
            sessionCreatedAt: text(statement, columns["session_created_at"])
        )
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32?) -> String? {
        guard let index,
              sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func int64(_ statement: OpaquePointer, _ index: Int32?) -> Int64? {
        guard let index, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private static func tokenCount(_ statement: OpaquePointer, _ index: Int32?) -> Int {
        Int(clamping: int64(statement, index) ?? 0)
    }

    /// SQLite 绑定字符串的析构器哨兵（SQLITE_TRANSIENT）。
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
