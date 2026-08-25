import XCTest
@testable import OmniForge

/// 限额重置检测器 — rollover 判据、防抖与读数提取纯逻辑测试（移植自 TokenTracker WeeklyLimitResetDetectorTests）。
final class LimitResetDetectorTests: XCTestCase {

    private func reading(
        provider: TokenUsageProvider = .codex,
        windowKey: String = "codex.weekly",
        windowLabel: String = "7d",
        usedPercent: Double,
        resetAt: Double?
    ) -> (provider: TokenUsageProvider, windowKey: String, windowLabel: String, usedPercent: Double, resetAt: Double?) {
        (provider, windowKey, windowLabel, usedPercent, resetAt)
    }

    private func makeSnapshot(percent: Double, resetAt: Double, eventAt: Double? = nil) -> LimitResetDetector.Snapshot {
        var snapshot = LimitResetDetector.Snapshot()
        snapshot.lastPercent["codex.weekly"] = percent
        snapshot.lastResetAt["codex.weekly"] = resetAt
        if let eventAt {
            snapshot.lastEventAt["codex.weekly"] = eventAt
        }
        return snapshot
    }

    private func makeDetector(
        minDrop: Double = 5,
        resetAdvanceTolerance: TimeInterval = 60,
        cooldown: TimeInterval = 3600
    ) -> LimitResetDetector {
        var detector = LimitResetDetector()
        detector.minDrop = minDrop
        detector.resetAdvanceTolerance = resetAdvanceTolerance
        detector.cooldown = cooldown
        return detector
    }

    // MARK: - rollover 判据

    func test_firstObservation_onlyRecordsBaseline() {
        let detector = makeDetector()
        let result = detector.evaluate(
            readings: [reading(usedPercent: 80, resetAt: 1_700_000_000)],
            snapshot: .init(),
            now: 1_700_000_100
        )
        XCTAssertTrue(result.events.isEmpty, "首次观测只记基线，绝不庆祝")
        XCTAssertEqual(result.snapshot.lastPercent["codex.weekly"], 80)
        XCTAssertEqual(result.snapshot.lastResetAt["codex.weekly"], 1_700_000_000)
    }

    func test_realRollover_afterConstrainedUser_fires() {
        let detector = makeDetector()
        let snapshot = makeSnapshot(percent: 92, resetAt: 1_600_000_000)
        let result = detector.evaluate(
            readings: [reading(usedPercent: 8, resetAt: 1_704_800_000)],
            snapshot: snapshot,
            now: 1_704_800_100
        )
        XCTAssertEqual(result.events.count, 1)
        let event = result.events[0]
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.windowKey, "codex.weekly")
        XCTAssertEqual(event.windowLabel, "7d")
        XCTAssertEqual(event.previousPercent, 92)
        XCTAssertEqual(result.snapshot.lastPercent["codex.weekly"], 8, "快照推进到当前读数")
        XCTAssertEqual(result.snapshot.lastEventAt["codex.weekly"], 1_704_800_100, "事件时间落进快照防抖")
    }

    func test_resetAtNotAdvanced_noFire() {
        let detector = makeDetector()
        let snapshot = makeSnapshot(percent: 90, resetAt: 1_700_000_000)
        // 百分比骤降但 reset_at 未前进（如回填/修正）→ 不是 rollover
        let result = detector.evaluate(
            readings: [reading(usedPercent: 10, resetAt: 1_700_000_050)],
            snapshot: snapshot,
            now: 1_700_000_100
        )
        XCTAssertTrue(result.events.isEmpty)
    }

    func test_dropBelowMinDrop_noFire() {
        let detector = makeDetector(minDrop: 5)
        let snapshot = makeSnapshot(percent: 50, resetAt: 1_600_000_000)
        // reset_at 前进但下降不足 5pp → 不触发（防 Kiro 类连续滑动 reset_at 误报）
        let result = detector.evaluate(
            readings: [reading(usedPercent: 48, resetAt: 1_704_800_000)],
            snapshot: snapshot,
            now: 1_704_800_100
        )
        XCTAssertTrue(result.events.isEmpty)
    }

    func test_windowWithoutResetTimestamp_neverFires() {
        let detector = makeDetector()
        var snapshot = LimitResetDetector.Snapshot()
        snapshot.lastPercent["codex.weekly"] = 90
        // 旧快照有基线但无 lastResetAt；当前读数也无 resetAt → 永不庆祝
        let result = detector.evaluate(
            readings: [reading(usedPercent: 5, resetAt: nil)],
            snapshot: snapshot,
            now: 1_704_800_100
        )
        XCTAssertTrue(result.events.isEmpty)
    }

    func test_cooldown_suppressesRepeat() {
        let detector = makeDetector(minDrop: 1, cooldown: 3600)
        let first = detector.evaluate(
            readings: [reading(usedPercent: 5, resetAt: 1_704_800_000)],
            snapshot: makeSnapshot(percent: 90, resetAt: 1_600_000_000),
            now: 1_704_800_100
        )
        XCTAssertEqual(first.events.count, 1)

        // 冷却期内（事件后 1000s < 1h）再喂一次（满足 rollover 判据）→ 不重复
        let second = detector.evaluate(
            readings: [reading(usedPercent: 4, resetAt: 1_704_801_000)],
            snapshot: first.snapshot,
            now: 1_704_801_100
        )
        XCTAssertTrue(second.events.isEmpty, "冷却期内不重复触发")

        // 冷却期（1h）后再次 rollover → 可再触发
        let third = detector.evaluate(
            readings: [reading(usedPercent: 2, resetAt: 1_704_810_000)],
            snapshot: second.snapshot,
            now: 1_704_810_100
        )
        XCTAssertEqual(third.events.count, 1, "冷却期后新 rollover 重新触发")
    }

    func test_oldSnapshotWithoutLastResetAt_decodesTolerantly() {
        let legacyData = """
        {"lastPercent":{"codex.weekly":80},"lastEventAt":{}}
        """.data(using: .utf8)!
        let snapshot = try! JSONDecoder().decode(LimitResetDetector.Snapshot.self, from: legacyData)
        XCTAssertEqual(snapshot.lastPercent["codex.weekly"], 80)
        XCTAssertTrue(snapshot.lastResetAt.isEmpty, "旧快照缺 lastResetAt → 空字典兜底")
        XCTAssertTrue(snapshot.lastEventAt.isEmpty)
    }

    func test_multipleWindows_firePerKeyIndependently() {
        let detector = makeDetector()
        var snapshot = LimitResetDetector.Snapshot()
        snapshot.lastPercent["codex.weekly"] = 95
        snapshot.lastResetAt["codex.weekly"] = 1_600_000_000
        snapshot.lastPercent["codex.session"] = 70
        snapshot.lastResetAt["codex.session"] = 1_600_000_000

        let result = detector.evaluate(
            readings: [
                reading(windowKey: "codex.weekly", usedPercent: 6, resetAt: 1_704_800_000),
                reading(windowKey: "codex.session", usedPercent: 68, resetAt: 1_704_800_000),
            ],
            snapshot: snapshot,
            now: 1_704_800_100
        )
        XCTAssertEqual(result.events.count, 1, "仅周窗 rollover，会话窗未下降够")
        XCTAssertEqual(result.events[0].windowKey, "codex.weekly")
    }

    // MARK: - 读数提取

    private func makeLimits(
        provider: TokenUsageProvider,
        configured: Bool = true,
        issue: LimitError? = nil,
        windows: [LimitWindowKind: UsageWindow] = [:],
        labeledWindows: [LabeledUsageWindow] = []
    ) -> ProviderUsageLimits {
        ProviderUsageLimits(
            provider: provider,
            configured: configured,
            subscriptionStatus: .unknown,
            planLabel: nil,
            windows: windows,
            labeledWindows: labeledWindows.isEmpty ? nil : labeledWindows,
            confidence: .official,
            capturedAt: Date(),
            stale: false,
            issue: issue
        )
    }

    func test_readings_flattenWindowsAndLabeledWindows() {
        let limits: [TokenUsageProvider: ProviderUsageLimits] = [
            .codex: makeLimits(
                provider: .codex,
                windows: [
                    .weekly: UsageWindow(usedPercent: 42, resetAt: Date(timeIntervalSince1970: 1_700_000_000)),
                    .session: UsageWindow(usedPercent: 10, resetAt: nil),
                ],
                labeledWindows: [
                    LabeledUsageWindow(label: "Spark 5h", window: UsageWindow(usedPercent: 3, resetAt: Date(timeIntervalSince1970: 1_690_000_000))),
                ]
            ),
        ]
        let readings = limits.limitResetReadings(strings: .en)
        XCTAssertEqual(readings.count, 3)
        XCTAssertTrue(readings.contains { $0.windowKey == "codex.weekly" && $0.windowLabel == "7d" && $0.usedPercent == 42 && $0.resetAt == 1_700_000_000 })
        XCTAssertTrue(readings.contains { $0.windowKey == "codex.session" && $0.windowLabel == "5h" && $0.usedPercent == 10 && $0.resetAt == nil })
        XCTAssertTrue(readings.contains { $0.windowKey == "codex.labeled.Spark 5h" && $0.windowLabel == "Spark 5h" && $0.usedPercent == 3 })
    }

    func test_readings_skipUnconfiguredAndErrorSnapshots() {
        let limits: [TokenUsageProvider: ProviderUsageLimits] = [
            .claude: makeLimits(
                provider: .claude,
                windows: [.weekly: UsageWindow(usedPercent: 60, resetAt: Date())]
            ),
            .codex: makeLimits(provider: .codex, configured: false),
            .kimi: makeLimits(
                provider: .kimi,
                issue: .reauthRequired,
                windows: [.weekly: UsageWindow(usedPercent: 80, resetAt: Date())]
            ),
        ]
        let readings = limits.limitResetReadings(strings: .en)
        XCTAssertEqual(readings.count, 1, "未配置与出错 provider 的窗口不参与检测")
        XCTAssertEqual(readings[0].provider, .claude)
    }

    // MARK: - 快照持久化

    func test_snapshot_persistenceRoundTrip() {
        let suite = "LimitResetDetectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var snapshot = LimitResetDetector.Snapshot()
        snapshot.lastPercent["codex.weekly"] = 88
        snapshot.lastResetAt["codex.weekly"] = 1_700_000_000
        LimitResetDetector.saveSnapshot(snapshot, defaults)

        let loaded = LimitResetDetector.loadSnapshot(defaults)
        XCTAssertEqual(loaded, snapshot)
    }
}
