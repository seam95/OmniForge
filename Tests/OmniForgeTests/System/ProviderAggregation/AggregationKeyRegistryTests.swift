import XCTest
@testable import OmniForge

/// key 登记簿：同 profile 稳定、对历史全部 key 去重、永不含分隔符、名称slug 为空回退短哈希、
/// 去重后缀不超 24 字符、改名后按名称重绑定、移除再加入拿回原 key。
final class AggregationKeyRegistryTests: XCTestCase {
    private func makeProfile(id: String, name: String) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            tool: .claudeCode,
            baseURL: "https://api.kimi.com/coding",
            token: "sk-kimi"
        )
    }

    func test_allocate_isStableForSameProfile() {
        let registry = AggregationKeyRegistry()
        XCTAssertEqual(registry.allocate(profile: makeProfile(id: "kimi", name: "Kimi For Coding")), "kimi-for-coding")
        XCTAssertEqual(registry.allocate(profile: makeProfile(id: "kimi", name: "Kimi For Coding")), "kimi-for-coding")
    }

    func test_allocate_deduplicatesAgainstAllKeysEverAllocated() {
        let registry = AggregationKeyRegistry(keys: ["glm": "gone-provider"])
        XCTAssertEqual(registry.allocate(profile: makeProfile(id: "glm2", name: "GLM")), "glm-2")
    }

    func test_allocate_keyNeverContainsSeparatorCharacters() {
        let key = AggregationKeyRegistry().allocate(profile: makeProfile(id: "x", name: "Kimi / For -- Coding 智谱"))
        XCTAssertFalse(key.contains("--"))
        XCTAssertFalse(key.contains("/"))
        XCTAssertLessThanOrEqual(key.count, 24)
    }

    func test_allocate_fallsBackToShortHashWhenNameYieldsEmptySlug() {
        let key = AggregationKeyRegistry().allocate(profile: makeProfile(id: "abcdef123456", name: "🙂"))
        XCTAssertTrue(key.hasPrefix("p"))
    }

    func test_allocate_deduplicateSuffixKeepsKeyWithin24Chars() {
        let longName = String(repeating: "ab", count: 15)   // slug 化后 30 字符 → 截到 24
        let registry = AggregationKeyRegistry(keys: [String(repeating: "ab", count: 12): "other"])
        let key = registry.allocate(profile: makeProfile(id: "x", name: longName))
        XCTAssertEqual(registry.allocate(profile: makeProfile(id: "x", name: longName)), key)
        XCTAssertLessThanOrEqual(key.count, 24)
    }

    func test_resolve_rebindsByProfileNameAfterRename() {
        let registry = AggregationKeyRegistry(keys: ["kimi-for-coding": "kimi-for-coding"])
        let renamed = makeProfile(id: "kimi-k3", name: "Kimi For Coding")
        XCTAssertEqual(registry.resolve(key: "kimi-for-coding", candidates: [renamed]), "kimi-k3")
    }

    func test_keySurvivesRemovalFromMembersAndIsReusedOnRejoin() {
        let registry = AggregationKeyRegistry()
        _ = registry.allocate(profile: makeProfile(id: "kimi", name: "Kimi"))
        // 成员语义上移除（调用方从 stack.members 摘除）——登记簿不动
        XCTAssertEqual(registry.keys, ["kimi": "kimi"])
        XCTAssertEqual(registry.keyOf(profileID: "kimi"), "kimi")
        // 重新加入拿回原 key，旧会话里的 id 继续有效
        XCTAssertEqual(registry.allocate(profile: makeProfile(id: "kimi", name: "Kimi")), "kimi")
    }
}
