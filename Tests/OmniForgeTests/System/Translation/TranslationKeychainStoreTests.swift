import Foundation
import Security
import XCTest
@testable import OmniForge

// MARK: - 注入闭包的内存钥匙串替身

/// 用注入闭包模拟 Security 调用：完全不触碰真实用户钥匙串。
///
/// 测试可预置读取/写入/删除失败状态，并检查传给 Security 的查询与属性字典。
private final class InMemoryKeychainOperations {
    /// 当前条目数据；nil 表示条目不存在。
    var storedData: Data?
    /// 非 nil 时 `copyMatching` 返回该失败状态，模拟钥匙串不可读。
    var readFailureStatus: OSStatus?
    /// 非 nil 时 add/update 返回该失败状态。
    var writeFailureStatus: OSStatus?
    /// 非 nil 时 delete 返回该失败状态。
    var deleteFailureStatus: OSStatus?

    private(set) var copyQueries: [[String: Any]] = []
    private(set) var addAttributes: [[String: Any]] = []
    private(set) var updateQueries: [[String: Any]] = []
    private(set) var updateAttributes: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []

    var operations: TranslationKeychainOperations {
        TranslationKeychainOperations(
            copyMatching: { [unowned self] query in
                self.copyQueries.append(query)
                if let readFailureStatus = self.readFailureStatus {
                    return (readFailureStatus, nil)
                }
                guard let storedData = self.storedData else {
                    return (errSecItemNotFound, nil)
                }
                let shouldReturnData = (query[kSecReturnData as String] as? Bool) == true
                return (errSecSuccess, shouldReturnData ? storedData : nil)
            },
            update: { [unowned self] query, attributes in
                self.updateQueries.append(query)
                self.updateAttributes.append(attributes)
                if let writeFailureStatus = self.writeFailureStatus { return writeFailureStatus }
                self.storedData = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            },
            add: { [unowned self] attributes in
                self.addAttributes.append(attributes)
                if let writeFailureStatus = self.writeFailureStatus { return writeFailureStatus }
                self.storedData = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            },
            delete: { [unowned self] query in
                self.deleteQueries.append(query)
                if let deleteFailureStatus = self.deleteFailureStatus { return deleteFailureStatus }
                let existed = self.storedData != nil
                self.storedData = nil
                return existed ? errSecSuccess : errSecItemNotFound
            }
        )
    }
}

// MARK: - TranslationKeychainStore 测试

/// 翻译功能独立 Keychain 存储：缺失、保存、清除、读取失败与命名/访问策略。
final class TranslationKeychainStoreTests: XCTestCase {
    private var fake: InMemoryKeychainOperations!
    private var store: TranslationKeychainStore!

    override func setUp() {
        super.setUp()
        fake = InMemoryKeychainOperations()
        store = TranslationKeychainStore(operations: fake.operations)
    }

    override func tearDown() {
        store = nil
        fake = nil
        super.tearDown()
    }

    // MARK: - 工具

    private func assertKeychainError(
        _ expected: OSStatus,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ expression: () throws -> Void
    ) {
        do {
            try expression()
            XCTFail("期望抛出 keychainUnavailable(\(expected))", file: file, line: line)
        } catch let error as TranslationKeychainError {
            XCTAssertEqual(error, .keychainUnavailable(expected), file: file, line: line)
        } catch {
            XCTFail("期望 TranslationKeychainError，实际 \(error)", file: file, line: line)
        }
    }

    // MARK: - 命名

    func test_entryNamingIsTranslationOwnAndStable() {
        XCTAssertEqual(TranslationKeychain.service, "app.omniforge.translation")
        XCTAssertEqual(TranslationKeychain.account, "api-key")
    }

    // MARK: - 缺失

    func test_readMissingEntryReturnsNil() throws {
        XCTAssertNil(try store.readAPIKey())

        let query = try XCTUnwrap(fake.copyQueries.first)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, TranslationKeychain.service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, TranslationKeychain.account)
        // 读取必须带 kSecReturnData，才能拿到 Key 数据。
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    }

    // MARK: - 保存

    func test_writeNewEntryUsesThisDeviceOnlyAccessibility() throws {
        try store.writeAPIKey("sk-翻译-key")

        let attributes = try XCTUnwrap(fake.addAttributes.first)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, TranslationKeychain.service)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, TranslationKeychain.account)
        // 仅本设备可用，不上 iCloud 同步。
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("sk-翻译-key".utf8))
        // 新条目走 add，不应走 update。
        XCTAssertTrue(fake.updateQueries.isEmpty)
        XCTAssertEqual(fake.storedData, Data("sk-翻译-key".utf8))
    }

    func test_writeExistingEntryUpdatesWithoutReadding() throws {
        fake.storedData = Data("sk-old".utf8)

        try store.writeAPIKey("sk-new")

        XCTAssertTrue(fake.addAttributes.isEmpty, "已存在条目不应重复新增")
        let attributes = try XCTUnwrap(fake.updateAttributes.first)
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, Data("sk-new".utf8))
        // 更新已存在条目时不携带访问策略，避免误改条目属性。
        XCTAssertNil(attributes[kSecAttrAccessible as String])
        XCTAssertEqual(fake.storedData, Data("sk-new".utf8))
    }

    func test_writeThenReadRoundTrip() throws {
        try store.writeAPIKey("sk-round-trip")

        XCTAssertEqual(try store.readAPIKey(), "sk-round-trip")
    }

    func test_writeFailureThrows() {
        fake.writeFailureStatus = errSecInteractionNotAllowed

        assertKeychainError(errSecInteractionNotAllowed) {
            try self.store.writeAPIKey("sk-any")
        }
    }

    func test_writeExistingEntryFailureThrows() {
        fake.storedData = Data("sk-old".utf8)
        fake.writeFailureStatus = errSecDuplicateItem

        assertKeychainError(errSecDuplicateItem) {
            try self.store.writeAPIKey("sk-new")
        }
    }

    // MARK: - 读取

    func test_readReturnsStoredKey() throws {
        fake.storedData = Data("sk-live".utf8)

        XCTAssertEqual(try store.readAPIKey(), "sk-live")
    }

    func test_readFailureThrowsInsteadOfReturningNil() {
        fake.readFailureStatus = errSecInteractionNotAllowed

        // 读取失败不能误当成「未配置 Key」。
        assertKeychainError(errSecInteractionNotAllowed) {
            _ = try self.store.readAPIKey()
        }
    }

    func test_readUndecodableDataThrows() {
        fake.storedData = Data([0xFF, 0xFE, 0xFD])

        assertKeychainError(errSecDecode) {
            _ = try self.store.readAPIKey()
        }
    }

    func test_readEmptyDataThrows() {
        fake.storedData = Data()

        assertKeychainError(errSecDecode) {
            _ = try self.store.readAPIKey()
        }
    }

    // MARK: - 清除

    func test_deleteRemovesEntryAndIsIdempotent() throws {
        fake.storedData = Data("sk-live".utf8)

        try store.deleteAPIKey()
        XCTAssertNil(fake.storedData)

        // 条目已不存在时删除视为成功（幂等）。
        XCTAssertNoThrow(try store.deleteAPIKey())
    }

    func test_deleteFailureThrows() {
        fake.deleteFailureStatus = errSecInteractionNotAllowed

        assertKeychainError(errSecInteractionNotAllowed) {
            try self.store.deleteAPIKey()
        }
    }
}
