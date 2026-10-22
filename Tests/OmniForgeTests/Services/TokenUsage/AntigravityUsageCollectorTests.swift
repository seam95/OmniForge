import Foundation
import GRDB
import XCTest
@testable import OmniForge

/// Antigravity 采集器：临时会话库（GRDB 建表 + 构造 protobuf blob）验证
/// 立即扫描 / 回填标记 / 桶与总量 / 二次扫描幂等 / 未变文件跳过 / 坏库与空目录静默。
final class AntigravityUsageCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var cliDir: URL!
    private var ideDir: URL!
    private var store: FakeUsageStore!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: AntigravityUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    private let sampleResponseID = "nOHSavOXNcucz7IPlf2gmAs"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        cliDir = tempDir.appendingPathComponent("antigravity-cli", isDirectory: true)
        ideDir = tempDir.appendingPathComponent("antigravity", isDirectory: true)
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ideDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        scheduler = FakeRepeatingScheduler()
        collector = AntigravityUsageCollector(
            store: store,
            cliConversationsDirectory: cliDir,
            ideConversationsDirectory: ideDir,
            scheduler: scheduler
        )
        backfillStates = []
        usageChanges = 0
        collector.onBackfillStateChange = { [weak self] value in
            self?.backfillStates.append(value)
        }
        collector.onUsageDidChange = { [weak self] _ in
            self?.usageChanges += 1
        }
    }

    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 辅助

    private func pumpUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    private func sampleGenerationData(responseID: String?) -> Data {
        AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(
                fixed: 1318,
                input: 14_836,
                output: 470,
                reasoning: 91,
                responseID: responseID
            ),
            responseModel: "gemini-3.8-flash"
        )
    }

    private func plainGenerationData(responseID: String?, fixedInput: UInt64 = 100) -> Data {
        AntigravityTestProto.generation(
            usage: AntigravityTestProto.usage(fixed: fixedInput, responseID: responseID),
            responseModel: "gemini-3.8-flash"
        )
    }

    private func sampleStepData(seconds: UInt64, nanos: UInt64 = 0, responseID: String?) -> Data {
        AntigravityTestProto.step(
            timestamp: (seconds, nanos),
            responseID: responseID,
            generationSequence: 0
        )
    }

    /// 在指定目录构造一个会话库（同真实 schema 的必要表 + 构造的 protobuf blob）。
    @discardableResult
    private func writeDatabase(
        named name: String,
        in directory: URL? = nil,
        generations: [(Int, Data)],
        steps: [(Int, Data)] = [],
        trajectory: Data? = nil,
        includeOptionalTables: Bool = true,
        modificationDate: Date? = nil
    ) throws -> URL {
        let targetDirectory = directory ?? cliDir!
        let url = targetDirectory.appendingPathComponent("\(name).db")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
            if includeOptionalTables {
                try db.execute(sql: """
                    CREATE TABLE steps (
                        idx INTEGER PRIMARY KEY,
                        step_type INTEGER NOT NULL,
                        metadata BLOB
                    )
                    """)
                try db.execute(sql: """
                    CREATE TABLE trajectory_metadata_blob (
                        id TEXT PRIMARY KEY,
                        data BLOB
                    )
                    """)
            }
            for row in generations {
                try db.execute(
                    sql: "INSERT INTO gen_metadata (idx, data) VALUES (?, ?)",
                    arguments: [row.0, row.1]
                )
            }
            for row in steps where includeOptionalTables {
                try db.execute(
                    sql: "INSERT INTO steps (idx, step_type, metadata) VALUES (?, 15, ?)",
                    arguments: [row.0, row.1]
                )
            }
            if includeOptionalTables, let trajectory {
                try db.execute(
                    sql: "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?)",
                    arguments: [trajectory]
                )
            }
        }
        if let modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    private func scanOnce() {
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount >= 1 }
    }

    private func rescan() {
        scheduler.fire()
        collector.waitForIdle()
    }

    // MARK: - 首轮扫描与回填

    func test_start_scansImmediately_writesBucketsAndMarksBackfill() throws {
        let step = sampleStepData(seconds: 1_792_205_211, nanos: 441_479_000, responseID: sampleResponseID)
        try writeDatabase(
            named: "session-1",
            generations: [(0, sampleGenerationData(responseID: sampleResponseID))],
            steps: [(1, step)],
            trajectory: AntigravityTestProto.trajectory(createdAt: (1_792_200_000, 0)),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        scanOnce()
        pumpUntil { self.backfillStates.count == 2 }

        XCTAssertEqual(scheduler.lastInterval, AntigravityUsageCollector.defaultScanInterval)
        XCTAssertEqual(AntigravityUsageCollector.defaultScanInterval, 5 * 60)
        XCTAssertEqual(backfillStates, [true, false], "首轮扫描首尾标记回填")
        XCTAssertGreaterThanOrEqual(usageChanges, 1, "每轮扫描结束通知管理器刷新快照")

        XCTAssertEqual(store.bucketsByKey.count, 1)
        let bucket = try XCTUnwrap(store.bucketsByKey.values.first)
        XCTAssertEqual(bucket.key.provider, .antigravity)
        XCTAssertEqual(bucket.key.model, "gemini-3.8-flash")
        XCTAssertEqual(bucket.key.bucketStart.timeIntervalSince1970, 1_792_204_200, "UTC 半小时桶")
        XCTAssertEqual(bucket.usage.inputTokens, 16_154)
        XCTAssertEqual(bucket.usage.cachedInputTokens, 0)
        XCTAssertEqual(bucket.usage.cacheCreationInputTokens, 0)
        XCTAssertEqual(bucket.usage.outputTokens, 470)
        XCTAssertEqual(bucket.usage.reasoningOutputTokens, 91)
        XCTAssertEqual(bucket.usage.totalTokens, 16_715)
        XCTAssertEqual(bucket.conversationCount, 1)
        XCTAssertTrue(store.seenKeys.contains("antigravity:cli:session-1:\(sampleResponseID)"))
    }

    func test_secondScan_skipsUnchangedFilesAndDoesNotDuplicate() throws {
        try writeDatabase(
            named: "session-1",
            generations: [(0, sampleGenerationData(responseID: sampleResponseID))],
            steps: [(1, sampleStepData(seconds: 1_792_205_211, responseID: sampleResponseID))],
            trajectory: AntigravityTestProto.trajectory(createdAt: (1_792_200_000, 0)),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        scanOnce()
        pumpUntil { self.backfillStates.count == 2 }
        let firstTotal = store.totalTokens()
        XCTAssertEqual(firstTotal, 16_715)
        XCTAssertEqual(collector.parsedFileCount, 1)

        rescan()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(collector.parsedFileCount, 1, "(size, mtime) 未变 → 不再解析")
        XCTAssertEqual(store.totalTokens(), firstTotal, "二次扫描不重复计数")
        XCTAssertEqual(store.totalConversations(), 1)
        XCTAssertEqual(backfillStates, [true, false], "回填只标记首轮")
    }

    func test_changedDatabase_addsOnlyNewGenerations() throws {
        try writeDatabase(
            named: "session-1",
            generations: [(0, sampleGenerationData(responseID: sampleResponseID))],
            steps: [(1, sampleStepData(seconds: 1_792_205_211, responseID: sampleResponseID))],
            trajectory: AntigravityTestProto.trajectory(createdAt: (1_792_200_000, 0)),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        scanOnce()
        XCTAssertEqual(store.totalTokens(), 16_715)

        // 追加第二条生成（新 responseId / 不同半小时桶）后重写库文件。
        let newResponseID = "second-response-id"
        try writeDatabase(
            named: "session-1",
            generations: [
                (0, sampleGenerationData(responseID: sampleResponseID)),
                (1, plainGenerationData(responseID: newResponseID, fixedInput: 500)),
            ],
            steps: [
                (1, sampleStepData(seconds: 1_792_205_211, responseID: sampleResponseID)),
                (3, sampleStepData(seconds: 1_792_208_811, responseID: newResponseID)),
            ],
            trajectory: AntigravityTestProto.trajectory(createdAt: (1_792_200_000, 0)),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100)
        )
        rescan()
        pumpUntil { self.collector.scanCount == 2 }

        XCTAssertEqual(collector.parsedFileCount, 2, "文件变化后重新解析")
        XCTAssertEqual(store.totalConversations(), 2, "只新增一条，旧行去重")
        XCTAssertEqual(store.totalTokens(), 16_715 + 500)
        XCTAssertEqual(
            store.bucketsByKey.values.map(\.key.bucketStart.timeIntervalSince1970).sorted(),
            [1_792_204_200, 1_792_207_800]
        )
        XCTAssertTrue(store.seenKeys.contains("antigravity:cli:session-1:\(newResponseID)"))
    }

    // MARK: - 空目录 / 坏库 / 缺表

    func test_emptyDirectories_areSilent() {
        scanOnce()
        pumpUntil { self.backfillStates.count == 2 }

        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertEqual(collector.parsedFileCount, 0)
        XCTAssertEqual(backfillStates, [true, false])
        XCTAssertEqual(usageChanges, 1, "每轮结束都通知（即使无数据）")
    }

    func test_brokenDatabaseFile_skippedSilentlyAndRetried() throws {
        let brokenURL = cliDir.appendingPathComponent("broken.db")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]).write(to: brokenURL)

        scanOnce()
        pumpUntil { self.backfillStates.count == 2 }
        XCTAssertTrue(store.bucketsByKey.isEmpty, "坏库不产生数据也不报错")
        XCTAssertEqual(collector.parsedFileCount, 1)
        XCTAssertEqual(backfillStates, [true, false])

        rescan()
        pumpUntil { self.collector.scanCount == 2 }
        XCTAssertEqual(collector.parsedFileCount, 2, "坏库不缓存指纹，下一轮重试")
        XCTAssertTrue(store.bucketsByKey.isEmpty)
    }

    func test_missingOptionalTables_fallsBackToFileModificationDate() throws {
        // 只有 gen_metadata 表（steps/trajectory 缺失）：时间回退到文件 mtime，模型回退 unknown。
        try writeDatabase(
            named: "minimal-session",
            generations: [(0, AntigravityTestProto.generation(usage: AntigravityTestProto.usage(fixed: 100)))],
            includeOptionalTables: false,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        scanOnce()
        XCTAssertEqual(store.totalTokens(), 100)
        let bucket = try XCTUnwrap(store.bucketsByKey.values.first)
        XCTAssertEqual(bucket.key.bucketStart.timeIntervalSince1970, 1_699_999_200)
        XCTAssertEqual(bucket.key.model, "unknown")
    }

    func test_unparsableGenerationRow_doesNotAbortWholeFile() throws {
        try writeDatabase(
            named: "session-mixed",
            generations: [
                (0, Data([0xFF, 0x00, 0x13])),
                (1, plainGenerationData(responseID: "good-row", fixedInput: 42)),
            ],
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        scanOnce()
        XCTAssertEqual(store.totalTokens(), 42, "坏行跳过，好行照常入桶")
        XCTAssertEqual(store.totalConversations(), 1)
    }

    // MARK: - 双目录与客户端前缀

    func test_bothDirectoriesScanned_dedupeKeyIncludesClientKind() throws {
        let generation = plainGenerationData(responseID: "shared-response", fixedInput: 100)
        try writeDatabase(
            named: "same-session",
            in: cliDir,
            generations: [(0, generation)],
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try writeDatabase(
            named: "same-session",
            in: ideDir,
            generations: [(0, generation)],
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        scanOnce()
        XCTAssertEqual(store.totalConversations(), 2, "CLI/IDE 各自独立计数")
        XCTAssertEqual(store.totalTokens(), 200)
        XCTAssertTrue(store.seenKeys.contains("antigravity:cli:same-session:shared-response"))
        XCTAssertTrue(store.seenKeys.contains("antigravity:ide:same-session:shared-response"))
    }

    // MARK: - 调度生命周期

    func test_stop_cancelsTimerAndStopsScanning() {
        scanOnce()
        collector.stop()
        scheduler.fire()
        pumpUntil(timeout: 0.5) { self.collector.scanCount == 1 }
        XCTAssertEqual(collector.scanCount, 1, "stop 后定时器不再触发")
    }

    func test_defaultDirectories_areNotScannedInTestProcess() {
        let defaultCollector = AntigravityUsageCollector(
            store: FakeUsageStore(),
            scheduler: FakeRepeatingScheduler()
        )
        defaultCollector.start()
        XCTAssertEqual(defaultCollector.scanCount, 0, "xctest 进程用真实目录构造时不扫描")
        XCTAssertEqual(defaultCollector.parsedFileCount, 0)
        defaultCollector.stop()
    }
}
