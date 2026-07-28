import XCTest
@testable import OmniForge

final class ClamshellRecoveryStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: ClamshellRecoveryStore!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clamshell-store-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = ClamshellRecoveryStore(applicationSupportRoot: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        store = nil
        super.tearDown()
    }

    func test_roundTripAndPermissions() throws {
        let record = ClamshellRecoveryRecord.makePrepared(
            userName: "seam",
            uid: 501,
            operationID: "abc",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(record)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: store.directoryURL.path)
        let dirPerms = dirAttrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirPerms?.intValue, 0o700)

        let loaded = try store.load(expectedUID: 501, expectedUserName: "seam")
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded?.restoreTargetSleepDisabled, 0)
    }

    func test_corruptJSON_rejected() throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        XCTAssertThrowsError(try store.load(expectedUID: 501, expectedUserName: "seam"))
    }

    func test_unknownSchema_rejected() throws {
        var record = ClamshellRecoveryRecord.makePrepared(userName: "seam", uid: 501, operationID: "x")
        record.schemaVersion = 99
        try store.save(record)
        XCTAssertThrowsError(try store.load(expectedUID: 501, expectedUserName: "seam")) { error in
            guard case let KeepAwakeError.recoveryRecordReadFailed(message) = error as! KeepAwakeError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertTrue(message.contains("schemaVersion"))
        }
    }

    func test_uidOrUsernameMismatch_rejected() throws {
        let record = ClamshellRecoveryRecord.makePrepared(userName: "seam", uid: 501, operationID: "x")
        try store.save(record)
        XCTAssertThrowsError(try store.load(expectedUID: 502, expectedUserName: "seam"))
        XCTAssertThrowsError(try store.load(expectedUID: 501, expectedUserName: "other"))
    }

    func test_deleteRequiresValidation() throws {
        let record = ClamshellRecoveryRecord.makePrepared(userName: "seam", uid: 501, operationID: "x")
        try store.save(record)
        // 错误身份不得删除
        XCTAssertThrowsError(
            try store.deleteValidatedRecord(expectedUID: 502, expectedUserName: "seam")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.deleteValidatedRecord(expectedUID: 501, expectedUserName: "seam")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func test_symlinkFile_rejected() throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let real = tempRoot.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: real)
        XCTAssertThrowsError(try store.load(expectedUID: 501, expectedUserName: "seam"))
    }
}
