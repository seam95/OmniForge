import Foundation
import XCTest
@testable import OmniForge

/// Cursor 用量采集器（云端口径）：云端账单 CSV 定时轮询 → 半小时桶快照 upsert；
/// 无本地日志可监听，无增量游标与去重；失败仅降级自身不通知。
final class CursorUsageCollectorTests: XCTestCase {
    private var store: FakeUsageStore!
    private var credentials: FakeCursorCredentials!
    private var fetcher: FakeCursorCSVFetcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: CursorUsageCollector!
    private var backfillStates: [Bool] = []
    private var usageChanges = 0

    override func setUp() {
        super.setUp()
        store = FakeUsageStore()
        credentials = FakeCursorCredentials(bundle: CursorAuthBundle(
            jwt: "jwt-1",
            userId: "user_abc",
            sessionCookie: "WorkosCursorSessionToken=user_abc%3A%3Ajwt-1"
        ))
        fetcher = FakeCursorCSVFetcher()
        scheduler = FakeRepeatingScheduler()
        collector = CursorUsageCollector(
            store: store,
            credentials: credentials,
            fetcher: fetcher,
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

    private func pumpUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "pumpUntil timed out")
    }

    private func csv(_ rows: [String]) -> String {
        "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost\n"
            + (rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n")
    }

    // MARK: - 首轮回填

    func test_start_pollsImmediately_andMarksBackfill_andWritesBuckets() throws {
        fetcher.results = [.success(csv([
            "\"2026-08-22T06:56:12.521Z\",auto,\"160000\",\"159990\",\"578207\",\"2055\",\"740252\",\"0.49\"",
            "\"2026-08-22T06:50:00.000Z\",auto,\"0\",\"40\",\"20\",\"5\",\"65\",\"0.1\"",
        ]))]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 && self.backfillStates.count == 2 }

        XCTAssertEqual(scheduler.lastInterval, CursorUsageCollector.defaultPollInterval, "定时兜底间隔 30 分钟")
        XCTAssertEqual(fetcher.lastCookie, "WorkosCursorSessionToken=user_abc%3A%3Ajwt-1")
        XCTAssertEqual(backfillStates, [true, false], "首个成功轮次即回填")
        XCTAssertGreaterThanOrEqual(usageChanges, 1, "采集后通知管理器刷新快照")

        let bucket = try XCTUnwrap(store.bucketsByKey.values.first)
        XCTAssertEqual(bucket.key.provider, .cursor)
        XCTAssertEqual(bucket.key.model, "auto")
        XCTAssertEqual(bucket.usage.inputTokens, 159_990 + 40, "同半小时桶聚合（06:56 与 06:50 同桶）")
        XCTAssertEqual(bucket.usage.cachedInputTokens, 578_207 + 20)
        XCTAssertEqual(bucket.usage.cacheCreationInputTokens, 10)
        XCTAssertEqual(bucket.usage.outputTokens, 2_055 + 5)
        XCTAssertEqual(bucket.usage.totalTokens, 740_262 + 65, "总额 = 四列之和（不以 CSV Total 列口径）")
        XCTAssertEqual(bucket.conversationCount, 2)
    }

    func test_start_withoutCredentials_doesNothing_notifyFree() throws {
        credentials.results = [.success(nil)]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertEqual(fetcher.callCount, 0, "未配置凭证 ← 不触网")
        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertEqual(usageChanges, 0, "没有数据变化 → 不通知（云端口径仅供分布行灰显）")
        XCTAssertTrue(backfillStates.isEmpty, "未成功读取不能标记回填完成")
    }

    func test_start_fetchFailureDegradesSilently_noStoreNoNotify() {
        fetcher.results = [.failure(LimitError.network("offline"))]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertEqual(usageChanges, 0, "单个 provider 失败不影响其他，也不弹错/通知")
        XCTAssertTrue(backfillStates.isEmpty)
    }

    func test_start_malformedCSV_doesNotCrashAndWritesNothing() {
        fetcher.results = [.success("cloudflare html not csv")]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertEqual(usageChanges, 0, "零行零写入 → 不通知")
    }

    // MARK: - 轮询幂等与窗口化导出

    func test_poll_refetchReplacesSameBucket_authoritativeSnapshot() throws {
        // 云端行以重新导出为准：同 (model, 半小时桶) 的快照被替换；总额 = 四列之和。
        let row1 = "\"2026-08-22T06:56:12.521Z\",auto,\"100000\",\"99000\",\"5000\",\"2000\",\"106000\",\"0.1\""
        let corrected = "\"2026-08-22T06:56:12.521Z\",auto,\"40000\",\"39000\",\"1000\",\"1000\",\"41000\",\"0.1\""
        fetcher.results = [.success(csv([row1])), .success(csv([corrected]))]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertEqual(store.bucketsByKey.values.first?.usage.totalTokens, 99_000 + 1_000 + 5_000 + 2_000)

        scheduler.fire()
        pumpUntil { self.fetcher.callCount == 2 }
        XCTAssertEqual(
            store.bucketsByKey.values.first?.usage.totalTokens,
            39_000 + 1_000 + 1_000 + 1_000,
            "云端行以重新导出为准（快照替换）"
        )
        XCTAssertEqual(backfillStates, [true, false], "仅首个轮次标记回填")
    }

    func test_poll_windowedExport_preservesHistoryOlderThanWindow() throws {
        let row = "\"2026-08-22T06:56:12.521Z\",auto,\"1000\",\"900\",\"80\",\"20\",\"1000\",\"0.1\""
        let recent = "\"2026-08-22T09:00:00.000Z\",auto,\"500\",\"450\",\"40\",\"10\",\"500\",\"0.1\""
        fetcher.results = [.success(csv([row, recent])), .success(csv([recent]))]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertEqual(store.bucketsByKey.count, 2)

        scheduler.fire()
        pumpUntil { self.fetcher.callCount == 2 }
        XCTAssertEqual(store.bucketsByKey.count, 2, "导出窗口外的旧桶不删除（绝不回零覆盖）")
        XCTAssertEqual(store.bucketsByKey.values.map(\.usage.totalTokens).sorted(), [550, 1_100])
    }

    // MARK: - 定时兜底

    func test_timerSchedulesPollAtDefaultInterval() {
        fetcher.results = [.success(csv(["\u{22}2026-08-22T06:56:12.521Z\u{22},auto,\u{22}10\u{22},\u{22}9\u{22},\u{22}1\u{22},\u{22}0\u{22},\u{22}10\u{22},\u{22}0\u{22}"]))]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertEqual(scheduler.lastInterval, 30 * 60)
        scheduler.fire()
        pumpUntil { self.collector.pollCount == 2 }
    }

    func test_stop_cancelsTimerAndStopsPolling() {
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        collector.stop()
        scheduler.fire()
        pumpUntil(timeout: 0.5) { self.collector.pollCount == 1 }
        XCTAssertEqual(collector.pollCount, 1, "stop 后定时器不再触发")
    }
}
