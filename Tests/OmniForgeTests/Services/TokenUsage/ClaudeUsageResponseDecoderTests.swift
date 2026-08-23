import XCTest
@testable import OmniForge

final class ClaudeUsageResponseDecoderTests: XCTestCase {
    // MARK: - 窗口分类

    func test_decode_classifiesByWindowSeconds() {
        let object: [String: Any] = [
            "five_hour": [
                "used_percent": 82,
                "limit_window_seconds": 18000,
                "reset_at": 1_800_000_123,
            ],
            "seven_day": [
                "used_percent": 45,
                "limit_window_seconds": 604800,
            ],
        ]
        let windows = ClaudeUsageResponseDecoder.decode(object)
        XCTAssertEqual(windows[.session]?.usedPercent, 82)
        XCTAssertEqual(windows[.session]?.windowSeconds, 18000)
        XCTAssertEqual(windows[.weekly]?.usedPercent, 45)
        XCTAssertNil(windows[.monthly])
    }

    func test_decode_secondsPreferredOverKeyName() {
        // seven_day_opus 的秒数若是 18000 → 归为会话窗（秒数优先于键名）
        let object: [String: Any] = [
            "seven_day_opus": [
                "used_percent": 10,
                "limit_window_seconds": 18000,
            ],
        ]
        let windows = ClaudeUsageResponseDecoder.decode(object)
        XCTAssertNil(windows[.weekly], "秒数分类优先，不落入周窗")
        XCTAssertEqual(windows[.session]?.usedPercent, 10)
    }

    func test_decode_fallsBackToKeyNameWithoutSeconds() {
        let object: [String: Any] = [
            "five_hour": ["used_percent": 30],
            "seven_day": ["used_percent": 12],
        ]
        let windows = ClaudeUsageResponseDecoder.decode(object)
        XCTAssertEqual(windows[.session]?.usedPercent, 30)
        XCTAssertEqual(windows[.weekly]?.usedPercent, 12)
    }

    func test_decode_weeklyScopedExpandsWithSeconds() {
        let object: [String: Any] = [
            "weekly_scoped": [
                "used_percent": 66,
                "limit_window_seconds": 604800,
            ],
        ]
        let windows = ClaudeUsageResponseDecoder.decode(object)
        XCTAssertEqual(windows[.weekly]?.usedPercent, 66)
    }

    // MARK: - 模型级周窗（seven_day_opus / weekly_scoped → labeledWindows）

    func test_labeledScopedWeekly_sevenDayOpusBecomesLabeledWindow() {
        let object: [String: Any] = [
            "five_hour": ["used_percent": 50],
            "seven_day_opus": ["utilization": 33, "resets_at": "2027-01-15T08:00:00.000Z"],
        ]
        let labeled = ClaudeUsageResponseDecoder.decodeLabeledScopedWeekly(object)
        XCTAssertEqual(labeled.count, 1)
        XCTAssertEqual(labeled.first?.label, "Opus")
        XCTAssertEqual(labeled.first?.window.usedPercent, 33)
        XCTAssertEqual(labeled.first?.window.windowSeconds, 604800)
        XCTAssertNotNil(labeled.first?.window.resetAt)
    }

    func test_labeledScopedWeekly_limitsArrayEntriesWithModelLabels() {
        let object: [String: Any] = [
            "five_hour": ["used_percent": 50],
            "limits": [
                [
                    "kind": "weekly_scoped",
                    "scope": ["model": ["display_name": "Fable", "id": "claude-fable"]],
                    "percent": 21,
                    "resets_at": "2027-01-15T08:00:00.000Z",
                ],
                [
                    "kind": "weekly_scoped",
                    "scope": ["model": ["id": "claude-haiku"]],
                    "utilization": 9,
                ],
                ["kind": "other_kind", "percent": 99],
            ],
        ]
        let labeled = ClaudeUsageResponseDecoder.decodeLabeledScopedWeekly(object)
        XCTAssertEqual(labeled.map(\.label), ["Fable", "claude-haiku"], "display_name 优先，回退 id；非 weekly_scoped 跳过")
        XCTAssertEqual(labeled.first?.window.usedPercent, 21)
        XCTAssertEqual(labeled.last?.window.usedPercent, 9)
    }

    func test_labeledScopedWeekly_deduplicatesOpusWhenSevenDayOpusPresent() {
        let object: [String: Any] = [
            "seven_day_opus": ["utilization": 33],
            "limits": [
                [
                    "kind": "weekly_scoped",
                    "scope": ["model": ["display_name": "Opus", "id": "claude-opus"]],
                    "percent": 33,
                ],
            ],
        ]
        let labeled = ClaudeUsageResponseDecoder.decodeLabeledScopedWeekly(object)
        XCTAssertEqual(labeled.count, 1, "顶层 seven_day_opus 存在时，scoped 的重复 Opus 条目丢弃")
        XCTAssertEqual(labeled.first?.label, "Opus")
    }

    func test_labeledScopedWeekly_emptyOrUnusableReturnsEmpty() {
        XCTAssertTrue(ClaudeUsageResponseDecoder.decodeLabeledScopedWeekly([:]).isEmpty)
        // percent 缺失且无 limit/used → 条目不可用，跳过。
        let unusable: [String: Any] = [
            "limits": [["kind": "weekly_scoped", "scope": ["model": ["display_name": "X"]]]],
        ]
        XCTAssertTrue(ClaudeUsageResponseDecoder.decodeLabeledScopedWeekly(unusable).isEmpty)
    }

    // MARK: - 额外额度（credits）

    func test_decode_creditsMapsNestedFieldsAndBackfillsRemaining() {
        let object: [String: Any] = [
            "five_hour": ["used_percent": 50],
            "extra_usage": [
                "total_limit": ["amount": 5.00, "currency": "USD"],
                "payg_used": ["amount": 2.50],
                "resets_at": 1_800_000_456,
            ],
        ]
        let windows = ClaudeUsageResponseDecoder.decode(object)
        let credits = try? XCTUnwrap(windows[.credits])
        XCTAssertEqual(credits?.limit, 5.00)
        XCTAssertEqual(credits?.used, 2.50)
        XCTAssertEqual(credits?.remaining, 2.50)
        XCTAssertEqual(credits?.unit, "USD")
        // 反推百分比 2.5/5 = 50%
        XCTAssertEqual(credits?.usedPercent ?? -1, 50, accuracy: 0.01)
        XCTAssertNotNil(credits?.resetAt)
    }

    func test_decode_creditsKeepsServerPercentWhenPresent() {
        let object: [String: Any] = [
            "five_hour": ["used_percent": 50],
            "extra_usage": [
                "total_limit": ["amount": 5.00, "currency": "USD"],
                "payg_used": ["amount": 1.00],
                "used_percent": 41,
            ],
        ]
        let windows = ClaudeUsageResponseDecoder.decode(object)
        XCTAssertEqual(windows[.credits]?.usedPercent, 41)
    }

    // MARK: - 订阅状态

    func test_decodeSubscriptionStatus_planTypeAndStatus() {
        XCTAssertEqual(
            ClaudeUsageResponseDecoder.decodeSubscriptionStatus(["plan_type": "pro"]),
            .active
        )
        XCTAssertEqual(
            ClaudeUsageResponseDecoder.decodeSubscriptionStatus(["plan_type": "free"]),
            .inactive
        )
        XCTAssertEqual(
            ClaudeUsageResponseDecoder.decodeSubscriptionStatus(["subscription_status": "active"]),
            .active
        )
        XCTAssertEqual(
            ClaudeUsageResponseDecoder.decodeSubscriptionStatus(["subscription_status": "expired"]),
            .inactive
        )
        XCTAssertEqual(ClaudeUsageResponseDecoder.decodeSubscriptionStatus([:]), .unknown)
        XCTAssertEqual(
            ClaudeUsageResponseDecoder.decodeSubscriptionStatus(["subscription_status": "weird"]),
            .unknown
        )
    }
}
