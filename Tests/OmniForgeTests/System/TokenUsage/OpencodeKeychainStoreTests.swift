import XCTest
import Security
@testable import OmniForge

/// OpenCode Go API Key 钥匙串封装：注入内存假钥匙串验证 add/update/delete 分支契约。
/// 不访问系统钥匙串——真实 SecItem 在测试宿主会弹授权窗，且无法稳定记忆。
final class OpencodeKeychainStoreTests: XCTestCase {
    func test_readMissingReturnsNil() throws {
        let (store, _) = makeStore()
        XCTAssertNil(try store.readAPIKey(), "无条目 → nil = 未配置")
    }

    func test_writeThenReadRoundTrips() throws {
        let (store, _) = makeStore()
        try store.writeAPIKey("sk-test-opencode-123")
        XCTAssertEqual(try store.readAPIKey(), "sk-test-opencode-123")
    }

    func test_writeIsIdempotentAddOrUpdate() throws {
        let (store, _) = makeStore()
        try store.writeAPIKey("sk-v1")
        try store.writeAPIKey("sk-v2")
        XCTAssertEqual(try store.readAPIKey(), "sk-v2", "重复写入覆盖旧值，不报错")
    }

    func test_deleteRemovesAndReadReturnsNil() throws {
        let (store, _) = makeStore()
        try store.writeAPIKey("sk-test-opencode-123")
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
            XCTAssertEqual(error as? OpencodeKeychainError, .keychainUnavailable(errSecAuthFailed))
        }
    }

    func test_writeUpdateFailureThrows() {
        let (store, keychain) = makeStore()
        XCTAssertNoThrow(try store.writeAPIKey("sk-v1"))
        keychain.updateStatus = errSecAuthFailed
        XCTAssertThrowsError(try store.writeAPIKey("sk-v2")) { error in
            XCTAssertEqual(error as? OpencodeKeychainError, .keychainUnavailable(errSecAuthFailed))
        }
    }

    func test_deleteFailureThrows() {
        let (store, keychain) = makeStore()
        keychain.deleteStatusOverride = errSecAuthFailed
        XCTAssertThrowsError(try store.deleteAPIKey()) { error in
            XCTAssertEqual(error as? OpencodeKeychainError, .keychainUnavailable(errSecAuthFailed))
        }
    }

    // MARK: - 工具

    private func makeStore() -> (OpencodeKeychainAPIKeyStore, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        let store = OpencodeKeychainAPIKeyStore(
            service: "tests.opencode",
            operations: keychain.operations
        )
        return (store, keychain)
    }
}
