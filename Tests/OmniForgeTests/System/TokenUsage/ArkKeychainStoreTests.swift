import XCTest
import Security
@testable import OmniForge

final class ArkKeychainStoreTests: XCTestCase {
    func test_readMissingReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(try store.readCredentials(), "无条目 → nil = 未配置")
    }

    func test_writeThenReadRoundTrips() throws {
        let store = try makeStore()
        let creds = ArkCredentials(accessKeyId: "AK-123", secretAccessKey: "SK-456")
        try store.writeCredentials(creds)
        XCTAssertEqual(try store.readCredentials(), creds)
    }

    func test_writeIsIdempotentAddOrUpdate() throws {
        let store = try makeStore()
        try store.writeCredentials(ArkCredentials(accessKeyId: "AK-1", secretAccessKey: "SK-1"))
        try store.writeCredentials(ArkCredentials(accessKeyId: "AK-2", secretAccessKey: "SK-2"))
        XCTAssertEqual(try store.readCredentials(), ArkCredentials(accessKeyId: "AK-2", secretAccessKey: "SK-2"))
    }

    func test_deleteRemovesAndReadReturnsNil() throws {
        let store = try makeStore()
        try store.writeCredentials(ArkCredentials(accessKeyId: "AK-123", secretAccessKey: "SK-456"))
        try store.deleteCredentials()
        XCTAssertNil(try store.readCredentials())
    }

    func test_deleteMissingSucceeds() throws {
        let store = try makeStore()
        XCTAssertNoThrow(try store.deleteCredentials(), "删除不存在的条目视为成功（幂等）")
    }

    // MARK: - 工具

    private func makeStore() throws -> ArkKeychainStore {
        let service = "ArkKeychainStoreTests.\(UUID().uuidString)"
        let store = ArkKeychainStore(service: service)
        addTeardownBlock {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }
        do {
            _ = try store.readCredentials()
        } catch ArkKeychainError.keychainUnavailable(let status) where status == errSecInteractionNotAllowed {
            throw XCTSkip("host 环境无法访问钥匙串（errSecInteractionNotAllowed），跳过真实 SecItem 用例")
        }
        return store
    }
}
