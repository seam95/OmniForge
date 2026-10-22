import Foundation
import GRDB
import XCTest
@testable import OmniForge

/// Copilot 采集器：临时 session-store.db（GRDB 建表插样本）与 OTEL JSONL 验证
/// 立即扫描 / 回填标记 / 桶与总量 / 二次扫描幂等 / 指纹跳过 / 坏库与空目录静默 / 原子提交失败重试。
final class CopilotUsageCollectorTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!
    private var otelDir: URL!
    private var store: FakeUsageStore!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: CopilotUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotUsageCollectorTests_\(UUID().uuidString)", isDirectory: true)
        databaseURL = tempDir.appendingPathComponent("session-store.db")
        otelDir = tempDir.appendingPathComponent("otel", isDirectory: true)
        try FileManager.default.createDirectory(at: otelDir, withIntermediateDirectories: true)
        store = FakeUsageStore()
        scheduler = FakeRepeatingScheduler()
        backfillStates = []
        usageChanges = 0
        collector = makeCollector()
    }

    override func tearDownWithError() throws {
        collector.stop()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 辅助

    private func makeCollector(
        databaseURLs: [URL]? = nil,
        otelDirectories: [URL]? = nil,
        otelExporterFile: URL? = nil
    ) -> CopilotUsageCollector {
        let collector = CopilotUsageCollector(
            store: store,
            databaseURLs: databaseURLs ?? [databaseURL],
            otelDirectories: otelDirectories ?? [otelDir],
            otelExporterFile: otelExporterFile,
            scheduler: scheduler
        )
        collector.onBackfillStateChange = { [weak self] value in
            self?.backfillStates.append(value)
        }
        collector.onUsageDidChange = { [weak self] _ in
            self?.usageChanges += 1
        }
        return collector
    }

    private func pumpUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    private func scanOnce() {
        collector.start()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount >= 1 }
        pumpUntil { self.backfillStates.count == 2 }
    }

    private func rescan(expectedScanCount: Int = 2) {
        scheduler.fire()
        collector.waitForIdle()
        pumpUntil { self.collector.scanCount >= expectedScanCount }
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - 临时库构造

    /// assistant_usage_events 样本行（默认值覆盖常用列）。
    private struct UsageSeed {
        var id: Int64
        var sessionID: String = "session-1"
        var turnIndex: Int64? = 0
        var model: String? = "gpt-5.4-mini"
        var copilotUsageModel: String? = nil
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0
        var reasoning: Int = 0
        var createdAt: String = "2026-07-01 12:34:56"
    }

    /// 在临时目录构造 session-store.db（表结构与 tokscale 权威参考一致）。
    private func writeDatabase(
        rows: [UsageSeed],
        sessions: [(id: String, createdAt: String)] = [],
        includeUsageTable: Bool = true,
        includeSessionsTable: Bool = true,
        modificationDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.removeItem(at: databaseURL)
        }
        do {
            let queue = try DatabaseQueue(path: databaseURL.path)
            try queue.write { db in
                if includeSessionsTable {
                    try db.execute(sql: """
                        CREATE TABLE sessions (
                            id TEXT PRIMARY KEY,
                            cwd TEXT,
                            created_at TEXT
                        )
                        """)
                    for session in sessions {
                        try db.execute(
                            sql: "INSERT INTO sessions (id, created_at) VALUES (?, ?)",
                            arguments: [session.id, session.createdAt]
                        )
                    }
                }
                if includeUsageTable {
                    try db.execute(sql: """
                        CREATE TABLE assistant_usage_events (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            session_id TEXT,
                            turn_index INTEGER,
                            model TEXT,
                            copilot_usage_model TEXT,
                            input_tokens INTEGER,
                            output_tokens INTEGER,
                            cache_read_tokens INTEGER,
                            cache_write_tokens INTEGER,
                            reasoning_tokens INTEGER,
                            total_nano_aiu INTEGER,
                            duration_ms INTEGER,
                            created_at TEXT
                        )
                        """)
                    for row in rows {
                        try db.execute(sql: """
                            INSERT INTO assistant_usage_events (
                                id, session_id, turn_index, model, copilot_usage_model,
                                input_tokens, output_tokens, cache_read_tokens,
                                cache_write_tokens, reasoning_tokens, created_at
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, arguments: [
                                row.id, row.sessionID, row.turnIndex, row.model,
                                row.copilotUsageModel, row.input, row.output,
                                row.cacheRead, row.cacheWrite, row.reasoning,
                                row.createdAt,
                            ])
                    }
                }
            }
        }
        if let modificationDate {
            try setModificationDate(modificationDate, for: databaseURL)
        }
    }

    private func writeOTELFile(
        _ lines: [String],
        named name: String = "export.jsonl",
        modificationDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> URL {
        let url = otelDir.appendingPathComponent(name)
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
        try setModificationDate(modificationDate, for: url)
        return url
    }

    // MARK: - 首轮扫描与回填

    func test_start_scansImmediately_writesBucketsAndMarksBackfill() throws {
        try writeDatabase(
            rows: [UsageSeed(
                id: 1,
                input: 21_343,
                output: 100,
                cacheWrite: 20_974
            )],
            sessions: [("session-1", "2026-07-01T12:34:56.000Z")]
        )

        scanOnce()

        XCTAssertEqual(scheduler.lastInterval, CopilotUsageCollector.defaultScanInterval)
        XCTAssertEqual(CopilotUsageCollector.defaultScanInterval, 5 * 60)
        XCTAssertEqual(backfillStates, [true, false], "首轮扫描首尾标记回填")
        XCTAssertGreaterThanOrEqual(usageChanges, 1, "每轮扫描结束通知管理器刷新快照")

        XCTAssertEqual(store.bucketsByKey.count, 1)
        let bucket = try XCTUnwrap(store.bucketsByKey.values.first)
        XCTAssertEqual(bucket.key.provider, .copilot)
        XCTAssertEqual(bucket.key.model, "gpt-5.4-mini")
        XCTAssertEqual(bucket.key.bucketStart.timeIntervalSince1970, 1_782_909_000, "UTC 半小时桶")
        XCTAssertEqual(bucket.usage.inputTokens, 369)
        XCTAssertEqual(bucket.usage.cachedInputTokens, 0)
        XCTAssertEqual(bucket.usage.cacheCreationInputTokens, 20_974)
        XCTAssertEqual(bucket.usage.outputTokens, 100)
        XCTAssertEqual(bucket.usage.totalTokens, 469)
        XCTAssertEqual(bucket.conversationCount, 1)
        XCTAssertTrue(store.seenKeys.contains("copilot:session-1:event:1"))
    }

    func test_secondScan_skipsUnchangedDatabaseAndDoesNotDuplicate() throws {
        try writeDatabase(rows: [UsageSeed(id: 1, input: 100, output: 20)])
        scanOnce()
        XCTAssertEqual(store.totalTokens(), 120)
        XCTAssertEqual(collector.parsedDatabaseCount, 1)

        rescan()

        XCTAssertEqual(collector.parsedDatabaseCount, 1, "(size, mtime) 未变 → 不再解析")
        XCTAssertEqual(store.totalTokens(), 120, "二次扫描不重复计数")
        XCTAssertEqual(store.totalConversations(), 1)
        XCTAssertEqual(backfillStates, [true, false], "回填只标记首轮")
    }

    func test_changedDatabase_addsOnlyNewEvents() throws {
        try writeDatabase(rows: [UsageSeed(id: 1, input: 100, output: 20)])
        scanOnce()
        XCTAssertEqual(store.totalTokens(), 120)

        // 追加第二条事件（不同 turn，新桶时间）后重写库文件。
        try writeDatabase(
            rows: [
                UsageSeed(id: 1, input: 100, output: 20),
                UsageSeed(
                    id: 2,
                    turnIndex: 1,
                    input: 200,
                    output: 30,
                    createdAt: "2026-07-01 13:05:00"
                ),
            ],
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100)
        )
        rescan()

        XCTAssertEqual(collector.parsedDatabaseCount, 2, "文件变化后重新解析")
        XCTAssertEqual(store.totalConversations(), 2, "只新增一条，旧行去重")
        XCTAssertEqual(store.totalTokens(), 120 + 230)
        XCTAssertEqual(
            store.bucketsByKey.values.map(\.key.bucketStart.timeIntervalSince1970).sorted(),
            [1_782_909_000, 1_782_910_800]
        )
        XCTAssertTrue(store.seenKeys.contains("copilot:session-1:event:2"))
    }

    func test_turnIndexSharedAcrossEvents_countsOneConversation() throws {
        try writeDatabase(rows: [
            UsageSeed(id: 1, turnIndex: 2, input: 100),
            UsageSeed(id: 2, turnIndex: 2, input: 50),
        ])
        scanOnce()
        XCTAssertEqual(store.totalTokens(), 150, "两条事件 token 都计入")
        XCTAssertEqual(store.totalConversations(), 1, "同一会话轮次只计 1 次会话")
    }

    func test_sessionCreatedAtFallback_whenEventTimestampInvalid() throws {
        try writeDatabase(
            rows: [UsageSeed(id: 1, input: 100, createdAt: "not-a-timestamp")],
            sessions: [("session-1", "2026-07-01T12:34:56.000Z")]
        )
        scanOnce()
        let bucket = try XCTUnwrap(store.bucketsByKey.values.first)
        XCTAssertEqual(bucket.key.bucketStart.timeIntervalSince1970, 1_782_909_000)
    }

    // MARK: - 去重与提交失败

    func test_seenKeysPreventDuplicateCountingOnRescan() throws {
        store.seenKeys = ["copilot:session-1:event:1"]
        try writeDatabase(rows: [UsageSeed(id: 1, input: 100)])
        scanOnce()

        XCTAssertTrue(store.bucketsByKey.isEmpty, "已见 key 不再入桶")
        XCTAssertEqual(collector.parsedDatabaseCount, 1)
    }

    func test_commitFailure_doesNotAdvanceProgressAndRetriesNextScan() throws {
        store.commitError = NSError(domain: "test", code: 1)
        try writeDatabase(rows: [UsageSeed(id: 1, input: 100, output: 20)])
        scanOnce()

        XCTAssertTrue(store.bucketsByKey.isEmpty, "提交失败整体不生效")
        XCTAssertEqual(collector.parsedDatabaseCount, 1)

        store.commitError = nil
        rescan()

        XCTAssertEqual(collector.parsedDatabaseCount, 2, "提交失败不缓存指纹，下轮重扫")
        XCTAssertEqual(store.totalTokens(), 120)
    }

    // MARK: - 空目录 / 缺表 / 坏库

    func test_emptyPaths_areSilent() {
        collector.stop()
        collector = makeCollector(
            databaseURLs: [tempDir.appendingPathComponent("missing.db")],
            otelDirectories: [tempDir.appendingPathComponent("missing-otel", isDirectory: true)]
        )
        scanOnce()

        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertEqual(collector.parsedDatabaseCount, 0)
        XCTAssertEqual(collector.parsedOTELFileCount, 0)
        XCTAssertEqual(backfillStates, [true, false])
        XCTAssertEqual(usageChanges, 1, "每轮结束都通知（即使无数据）")
    }

    func test_databaseWithoutUsageTable_isSilentAndFingerprintIsCached() throws {
        try writeDatabase(rows: [], includeUsageTable: false)
        scanOnce()

        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertEqual(collector.parsedDatabaseCount, 1)

        rescan()
        XCTAssertEqual(collector.parsedDatabaseCount, 1, "缺表库可读：缓存指纹，不每轮重开")
    }

    func test_brokenDatabaseFile_isSkippedAndRetried() throws {
        let broken = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        try broken.write(to: databaseURL)

        scanOnce()
        XCTAssertTrue(store.bucketsByKey.isEmpty, "坏库不产生数据也不报错")
        XCTAssertEqual(collector.parsedDatabaseCount, 1)

        rescan()
        XCTAssertEqual(collector.parsedDatabaseCount, 2, "坏库不缓存指纹，下一轮重试")
        XCTAssertTrue(store.bucketsByKey.isEmpty)
    }

    func test_fileFingerprint_includesWALSidecar() throws {
        try Data([0x01]).write(to: databaseURL)
        let before = try XCTUnwrap(
            CopilotUsageCollector.fileFingerprint(forPath: databaseURL.path)
        )

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        try Data([0x01, 0x02]).write(to: walURL)
        let after = try XCTUnwrap(
            CopilotUsageCollector.fileFingerprint(forPath: databaseURL.path)
        )

        XCTAssertNotEqual(before, after, "WAL 侧文件变化必须视为库变化，否则会漏掉新写入")
    }

    // MARK: - immutable 只读兜底

    func test_immutableDatabaseReader_readsUsageEventsWithSessionFallback() throws {
        try writeDatabase(
            rows: [UsageSeed(id: 1, input: 100, output: 20, cacheRead: 30)],
            sessions: [("session-1", "2026-07-01T12:34:56.000Z")]
        )
        let reader = try XCTUnwrap(CopilotImmutableDatabase(url: databaseURL))
        guard case let .rows(rows) = reader.readUsageRows() else {
            return XCTFail("immutable 读取应返回数据行")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.eventID, 1)
        XCTAssertEqual(rows.first?.inputTokens, 100)
        XCTAssertEqual(rows.first?.cacheReadTokens, 30)
        XCTAssertEqual(rows.first?.sessionCreatedAt, "2026-07-01T12:34:56.000Z")
    }

    func test_immutableDatabaseReader_reportsMissingUsageTable() throws {
        try writeDatabase(rows: [], includeUsageTable: false)
        let reader = try XCTUnwrap(CopilotImmutableDatabase(url: databaseURL))
        guard case .missingTable = reader.readUsageRows() else {
            return XCTFail("缺 assistant_usage_events 表应报告 missingTable")
        }
    }

    // MARK: - OTEL JSONL

    func test_otelJSONL_parsedAndSkippedWhenUnchanged() throws {
        try writeOTELFile([chatSpanLine(trace: "trace-1", span: "span-1", input: 42, output: 7)])
        scanOnce()

        XCTAssertEqual(collector.parsedOTELFileCount, 1)
        XCTAssertEqual(store.bucketsByKey.count, 1)
        let bucket = try XCTUnwrap(store.bucketsByKey.values.first)
        XCTAssertEqual(bucket.key.provider, .copilot)
        XCTAssertEqual(bucket.key.model, "gpt-5.4-mini")
        XCTAssertEqual(bucket.usage.totalTokens, 49)
        XCTAssertEqual(bucket.key.bucketStart.timeIntervalSince1970, 1_775_934_000)
        XCTAssertTrue(store.seenKeys.contains("copilot:conv-1:span:trace-1:span-1"))

        rescan()
        XCTAssertEqual(collector.parsedOTELFileCount, 1, "文件未变 → 不再解析")
        XCTAssertEqual(store.bucketsByKey.count, 1)
        XCTAssertEqual(store.totalTokens(), 49)
    }

    func test_otelFileAppend_addsOnlyNewEvents() throws {
        try writeOTELFile([chatSpanLine(trace: "trace-1", span: "span-1", input: 42, output: 7)])
        scanOnce()
        XCTAssertEqual(store.totalTokens(), 49)

        try writeOTELFile(
            [
                chatSpanLine(trace: "trace-1", span: "span-1", input: 42, output: 7),
                chatSpanLine(
                    trace: "trace-2",
                    span: "span-2",
                    input: 10,
                    output: 2,
                    secondOffset: 60
                ),
            ],
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100)
        )
        rescan()

        XCTAssertEqual(collector.parsedOTELFileCount, 2)
        XCTAssertEqual(store.totalTokens(), 49 + 12)
        XCTAssertEqual(store.totalConversations(), 2)
    }

    func test_otelMalformedLinesAreTolerated() throws {
        let url = otelDir.appendingPathComponent("export.jsonl")
        let content = [
            chatSpanLine(trace: "trace-1", span: "span-1", input: 42, output: 7),
            "not-json",
            #"{"broken":"#,
            "",
        ].joined(separator: "\n")
        try content.data(using: .utf8)?.write(to: url)
        try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), for: url)

        scanOnce()
        XCTAssertEqual(store.totalTokens(), 49, "坏行跳过，好行照常入桶")
    }

    func test_otelInferenceLog_isUsedWhenChatSpanAbsent() throws {
        let inference = #"{"type":"log","spanContext":{"traceId":"trace-log","spanId":"log-1","traceFlags":1},"hrTime":[1775934264,967317833],"attributes":{"event.name":"gen_ai.client.inference.operation.details","gen_ai.request.model":"gpt-5.4-mini","gen_ai.response.model":"gpt-5.4-mini","gen_ai.conversation.id":"conv-log","gen_ai.response.id":"response-log","gen_ai.usage.input_tokens":42,"gen_ai.usage.output_tokens":7},"_body":"GenAI inference: gpt-5.4-mini"}"#
        try writeOTELFile([inference])
        scanOnce()

        XCTAssertEqual(store.totalTokens(), 49)
        XCTAssertTrue(store.seenKeys.contains("copilot:conv-log:span:trace-log:log-1"))
    }

    // MARK: - 调度生命周期

    func test_stop_cancelsTimerAndStopsScanning() {
        scanOnce()
        collector.stop()
        scheduler.fire()
        pumpUntil(timeout: 0.5) { self.collector.scanCount == 1 }
        XCTAssertEqual(collector.scanCount, 1, "stop 后定时器不再触发")
    }

    func test_defaultPaths_areNotScannedInTestProcess() {
        let defaultCollector = CopilotUsageCollector(
            store: FakeUsageStore(),
            scheduler: FakeRepeatingScheduler()
        )
        defaultCollector.start()
        XCTAssertEqual(defaultCollector.scanCount, 0, "xctest 进程用真实路径构造时不扫描")
        XCTAssertEqual(defaultCollector.parsedDatabaseCount, 0)
        XCTAssertEqual(defaultCollector.parsedOTELFileCount, 0)
        defaultCollector.stop()
    }

    // MARK: - OTEL 样本

    /// 一条 chat span JSON（默认 1775934264 秒，UTC 半小时桶 1775934000）。
    private func chatSpanLine(
        trace: String,
        span: String,
        input: Int,
        output: Int,
        secondOffset: Int64 = 0
    ) -> String {
        let seconds = Int64(1_775_934_264) + secondOffset
        // 用 JSONSerialization 生成单行 JSON，避免手写转义（JSONL 要求一行一条记录）。
        let record: [String: Any] = [
            "type": "span",
            "traceId": trace,
            "spanId": span,
            "name": "chat gpt-5.4-mini",
            "startTime": [seconds, 0],
            "attributes": [
                "gen_ai.operation.name": "chat",
                "gen_ai.request.model": "gpt-5.4-mini",
                "gen_ai.conversation.id": "conv-1",
                "gen_ai.usage.input_tokens": input,
                "gen_ai.usage.output_tokens": output,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
