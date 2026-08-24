import Foundation
import XCTest
@testable import OmniForge

/// trae-cn 采集器：opt-in 守卫、会话对账（减旧加新）、空快照不表断言、失败静默。
final class TraeCnUsageCollectorTests: XCTestCase {
    private var store: FakeUsageStore!
    private var preferences: TokenUsagePreferences!
    private var keychain: FakeTraeCnKeychain!
    private var fetcher: FakeTraeCnFetcher!
    private var scheduler: FakeRepeatingScheduler!
    private var collector: TraeCnUsageCollector!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "TraeCnUsageCollectorTests_\(UUID().uuidString)")!
        store = FakeUsageStore()
        preferences = TokenUsagePreferences(userDefaults: defaults)
        keychain = FakeTraeCnKeychain()
        fetcher = FakeTraeCnFetcher()
        scheduler = FakeRepeatingScheduler()
        collector = TraeCnUsageCollector(
            store: store,
            preferences: preferences,
            keychain: keychain,
            fetcher: fetcher,
            scheduler: scheduler
        )
    }

    override func tearDownWithError() throws {
        collector.stop()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    private var defaultsSuiteName: String {
        "TraeCnUsageCollectorTests"
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

    private func row(_ session: String, model: String = "doubao-1.5", input: Double, output: Double, usageTime: Double = 1_784_502_000) -> TraeCnSessionRow {
        TraeCnSessionRow(
            sessionId: session,
            modelName: model,
            usageTime: usageTime,
            inputToken: input,
            outputToken: output,
            cacheReadToken: nil,
            cacheWriteToken: nil,
            extraInfo: nil
        )
    }

    // MARK: - opt-in 守卫

    func test_poll_skipsWhenDisabledOrNoJWT() throws {
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertTrue(fetcher.fetchCount == 0, "未启用不取数")

        preferences.setTraeCnEnabled(true)
        scheduler.fire()
        pumpUntil { self.collector.pollCount == 2 }
        XCTAssertTrue(fetcher.fetchCount == 0, "无 JWT 不取数")
    }

    // MARK: - 基本对账

    func test_poll_countsSessionsAndReconciles() throws {
        preferences.setTraeCnEnabled(true)
        keychain.jwt = "jwt-1"
        fetcher.rows = [
            row("s1", input: 1000, output: 200),
            row("s2", input: 500, output: 50, usageTime: 1_784_503_800),
        ]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }

        let buckets = store.bucketsByKey.filter { $0.key.provider == .traeCN }
        XCTAssertEqual(buckets.count, 2, "两会话分属两个半小时桶")
        XCTAssertEqual(buckets.map(\.value.usage.totalTokens).reduce(0, +), 1750)
        XCTAssertTrue(buckets.contains { $0.key.bucketStart.timeIntervalSince1970 == 1_784_502_000 && $0.value.usage.totalTokens == 1200 })
        XCTAssertTrue(buckets.contains { $0.key.bucketStart.timeIntervalSince1970 == 1_784_503_800 && $0.value.usage.totalTokens == 550 })
        XCTAssertEqual(buckets.map(\.value.conversationCount).reduce(0, +), 2)
    }

    func test_poll_sessionChangeRetractsOldAddsNew() throws {
        preferences.setTraeCnEnabled(true)
        keychain.jwt = "jwt-1"
        fetcher.rows = [row("s1", input: 1000, output: 200)]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertEqual(store.totalTokens(), 1200)

        // 会话总量变化 → 减旧加新（同桶净增 100）。
        fetcher.rows = [row("s1", input: 1100, output: 200)]
        scheduler.fire()
        pumpUntil { self.collector.pollCount == 2 }
        XCTAssertEqual(store.totalTokens(), 1300)
    }

    func test_poll_unchangedNoMutation() throws {
        preferences.setTraeCnEnabled(true)
        keychain.jwt = "jwt-1"
        fetcher.rows = [row("s1", input: 1000, output: 200)]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        let upserts = store.upsertCount

        scheduler.fire()
        pumpUntil { self.collector.pollCount == 2 }
        XCTAssertEqual(store.upsertCount, upserts, "无变化不写桶")
    }

    // MARK: - 空快照 / 失败

    func test_poll_emptySnapshotAssertsNothing() throws {
        preferences.setTraeCnEnabled(true)
        keychain.jwt = "jwt-1"
        fetcher.rows = []
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertTrue(store.bucketsByKey.isEmpty, "空快照不写库")
        XCTAssertTrue(store.messageState[.traeCN]?.isEmpty ?? true, "空快照不写状态")
    }

    func test_poll_malformedRowFailsClosed() throws {
        preferences.setTraeCnEnabled(true)
        keychain.jwt = "jwt-1"
        fetcher.rows = [
            row("s1", input: 1000, output: 200),
            TraeCnSessionRow(sessionId: "bad", modelName: nil, usageTime: -5, inputToken: 10, outputToken: 1, cacheReadToken: nil, cacheWriteToken: nil, extraInfo: nil),
        ]
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertTrue(store.bucketsByKey.isEmpty, "含坏行的部分快照不作权威（fail-closed）")
    }

    func test_poll_networkFailureSilentlySkips() throws {
        preferences.setTraeCnEnabled(true)
        keychain.jwt = "jwt-1"
        fetcher.error = LimitError.network("offline")
        collector.start()
        pumpUntil { self.collector.pollCount == 1 }
        XCTAssertTrue(store.bucketsByKey.isEmpty)
        XCTAssertTrue(store.messageState[.traeCN]?.isEmpty ?? true)
    }
}

// MARK: - 测试替身

private final class FakeTraeCnKeychain: TraeCnJWTAccessing {
    var jwt: String?

    func readJWT() throws -> String? { jwt }
    func writeJWT(_ jwt: String) throws { self.jwt = jwt }
    func deleteJWT() throws { jwt = nil }
}

private final class FakeTraeCnFetcher: TraeCnUsageFetching {
    var rows: [TraeCnSessionRow] = []
    var error: Error?
    private(set) var fetchCount = 0
    private(set) var lastStartMs: Double?
    private(set) var lastEndMs: Double?

    func fetchSessions(jwt: String, startMs: Double, endMs: Double) async throws -> [TraeCnSessionRow] {
        fetchCount += 1
        lastStartMs = startMs
        lastEndMs = endMs
        if let error { throw error }
        return rows
    }
}