import XCTest
import Security
@testable import OmniForge

/// 火山方舟 AK/SK 钥匙串封装：注入内存假钥匙串验证契约，不访问系统钥匙串。
final class ArkKeychainStoreTests: XCTestCase {
    func test_readMissingReturnsNil() throws {
        let (store, _) = makeStore()
        XCTAssertNil(try store.readCredentials(), "无条目 → nil = 未配置")
    }

    func test_writeThenReadRoundTrips() throws {
        let (store, _) = makeStore()
        let creds = ArkCredentials(accessKeyId: "AK-123", secretAccessKey: "SK-456")
        try store.writeCredentials(creds)
        XCTAssertEqual(try store.readCredentials(), creds)
    }

    func test_writeIsIdempotentAddOrUpdate() throws {
        let (store, _) = makeStore()
        try store.writeCredentials(ArkCredentials(accessKeyId: "AK-1", secretAccessKey: "SK-1"))
        try store.writeCredentials(ArkCredentials(accessKeyId: "AK-2", secretAccessKey: "SK-2"))
        XCTAssertEqual(try store.readCredentials(), ArkCredentials(accessKeyId: "AK-2", secretAccessKey: "SK-2"))
    }

    func test_deleteRemovesAndReadReturnsNil() throws {
        let (store, _) = makeStore()
        try store.writeCredentials(ArkCredentials(accessKeyId: "AK-123", secretAccessKey: "SK-456"))
        try store.deleteCredentials()
        XCTAssertNil(try store.readCredentials())
    }

    func test_deleteMissingSucceeds() throws {
        let (store, _) = makeStore()
        XCTAssertNoThrow(try store.deleteCredentials(), "删除不存在的条目视为成功（幂等）")
    }

    func test_readPropagatesKeychainUnavailable() {
        let (store, keychain) = makeStore()
        keychain.copyStatusOverride = errSecAuthFailed
        XCTAssertThrowsError(try store.readCredentials()) { error in
            XCTAssertEqual(error as? ArkKeychainError, .keychainUnavailable(errSecAuthFailed))
        }
    }

    // MARK: - 工具

    private func makeStore() -> (ArkKeychainStore, InMemoryKeychain) {
        let keychain = InMemoryKeychain()
        let store = ArkKeychainStore(
            service: "tests.ark",
            operations: keychain.operations
        )
        return (store, keychain)
    }
}
