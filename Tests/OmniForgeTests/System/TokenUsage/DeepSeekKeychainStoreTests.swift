import XCTest
import Security
@testable import OmniForge

/// DeepSeek API Key 钥匙串封装：注入内存假钥匙串验证契约，不访问系统钥匙串。
final class DeepSeekKeychainStoreTests: XCTestCase {
    func test_readMissingReturnsNil() throws {
        let (store, _) = makeStore()
        XCTAssertNil(try store.readAPIKey(), "无条目 → nil = 未配置")
    }

    func test_writeThenReadRoundTrips() throws {
        let (store, _) = makeStore()
        try store.writeAPIKey("sk-test-123")
        XCTAssertEqual(try store.readAPIKey(), "sk-test-123")
    }

    func test_writeIsIdempotentAddOrUpdate() throws {
        let (store, _) = makeStore()
        try store.writeAPIKey("sk-v1")
        try store.writeAPIKey("sk-v2")
        XCTAssertEqual(try store.readAPIKey(), "sk-v2", "重复写入覆盖旧值，不报错")
    }

    func test_deleteRemovesAndReadReturnsNil() throws {
        let (store, _) = makeStore()
        try store.writeAPIKey("sk-test-123")
        try store.deleteAPIKey()
        XCTAssertNil(try store.readAPIKey())
    }

    func test_deleteMissingSucceeds() throws {
        let (store, _) = makeStore()
        XCTAssertNoThrow(try store.deleteAPIKey(), "删除不存在的条目视为成功（幂等）")
    }

    func test_readPropagatesKeychainUnavailable() {
        let (store, keychain) = makeStore()
        keychain.copyStatusOverride = errSecAuthFailed
        XCTAssertThrowsError(try store.readAPIKey()) { error in
            XCTAssertEqual(error as? DeepSeekKeychainError, .keychainUnavailable(errSecAuthFailed))
        }
    }

    // MARK: - 工具

    private func makeStore() -> (DeepSeekKeychainAPIKeyStore, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        let store = DeepSeekKeychainAPIKeyStore(
            service: "tests.deepseek",
            operations: keychain.operations
        )
        return (store, keychain)
    }
}
