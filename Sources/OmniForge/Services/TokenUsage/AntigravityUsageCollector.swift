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
/// 调度骨架（定时兜底、信号合并、回填标记、通知）复用 `JSONLUsageCollectorBase`；
/// 本类只覆盖 `performScan`（指纹跳过 + 无游标语义）。
///
/// 隐私红线（SPEC 2.6）：生成 blob 含对话正文；本采集器只按字段号读取数值字段，
/// blob 永不落库、永不打印。
final class AntigravityUsageCollector: JSONLUsageCollectorBase {
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

    /// 实际打开解析的库文件数（指纹未变的库被跳过；测试断言）。
    private(set) var parsedFileCount = 0
    /// 库文件 → (size, mtime) 指纹；未变化则跳过解析（首次全部解析）。
    private var fileSignatures: [String: FileSignature] = [:]
    private let cliConversationsDirectory: URL
    private let ideConversationsDirectory: URL

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
        self.cliConversationsDirectory = cliConversationsDirectory
        self.ideConversationsDirectory = ideConversationsDirectory
        super.init(
            provider: .antigravity,
            store: store,
            scanInterval: scanInterval,
            fileManager: fileManager,
            scheduler: scheduler
        )
    }

    // MARK: - 测试进程守护

    /// 是否以默认（真实用户）目录构造。
    override var usesRealDirectories: Bool {
        cliConversationsDirectory.standardizedFileURL == Self.defaultCLIConversationsDirectory.standardizedFileURL
            || ideConversationsDirectory.standardizedFileURL == Self.defaultIDEConversationsDirectory.standardizedFileURL
    }

    // MARK: - 扫描

    /// 全量一轮：枚举 → 指纹跳过未变库 → 只读解析 → 内存聚合 → 单事务提交。
    override func performScan() {
        let files = enumerateDatabaseFiles()
        guard !files.isEmpty else { return }

        let scan = ScanContext(
            provider: provider,
            aggregator: UsageAggregator { [store] key in
                store.loadBucket(key)
            },
            seen: store.loadSeenKeys()
        )
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
                scan.ingest(
                    dedupKey: generation.deduplicationKey,
                    usage: generation.usage,
                    conversationDelta: generation.conversationDelta,
                    model: generation.model,
                    bucketStart: generation.bucketStart
                )
            }
            if let signature {
                pendingSignatures[file.url.path] = signature
            }
        }

        let buckets = scan.aggregator.drainTouched()
        guard !buckets.isEmpty else {
            // 解析成功但无新增（重复扫描/空库）：只推进文件指纹，不写事务。
            fileSignatures.merge(pendingSignatures) { _, latest in latest }
            return
        }

        var commit = ScanCommit()
        commit.buckets = buckets
        commit.newSeenKeys = scan.drainNewSeen()
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
}
