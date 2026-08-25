import XCTest
import Security
@testable import OmniForge

/// OpenCode Go API Key 钥匙串封装：真实 SecItem 读写删闭环（每测试唯一 service，teardown 清理）。
/// 无钥匙串权限的宿主（CI/无登录会话）以 `errSecInteractionNotAllowed` 识别并跳过。
final class OpencodeKeychainStoreTests: XCTestCase {
    func test_readMissingReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(try store.readAPIKey(), "无条目 → nil = 未配置")
    }

    func test_writeThenReadRoundTrips() throws {
        let store = try makeStore()
        try store.writeAPIKey("sk-test-opencode-123")
        XCTAssertEqual(try store.readAPIKey(), "sk-test-opencode-123")
    }

    func test_writeIsIdempotentAddOrUpdate() throws {
        let store = try makeStore()
        try store.writeAPIKey("sk-v1")
        try store.writeAPIKey("sk-v2")
        XCTAssertEqual(try store.readAPIKey(), "sk-v2", "重复写入覆盖旧值，不报错")
    }

    func test_deleteRemovesAndReadReturnsNil() throws {
        let store = try makeStore()
        try store.writeAPIKey("sk-test-opencode-123")
        try store.deleteAPIKey()
        XCTAssertNil(try store.readAPIKey())
    }

    func test_deleteMissingSucceeds() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.deleteAPIKey(), "删除不存在的条目视为成功（幂等）")
    }

    // MARK: - 工具

    /// 每测试唯一 service 的 store；test 结束自动清理条目。
    private func makeStore() throws -> OpencodeKeychainAPIKeyStore {
        let service = "OpencodeKeychainStoreTests.\(UUID().uuidString)"
        let store = OpencodeKeychainAPIKeyStore(service: service)
        addTeardownBlock {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }
        do {
            _ = try store.readAPIKey()
        } catch OpencodeKeychainError.keychainUnavailable(let status) where status == errSecInteractionNotAllowed {
            throw XCTSkip("host 环境无法访问钥匙串（errSecInteractionNotAllowed），跳过真实 SecItem 用例")
        }
        return store
    }
}
