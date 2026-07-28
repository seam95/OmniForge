import XCTest
@testable import OmniForge

@MainActor
final class FakeClamshellController: ClamshellControlling {
    var sleepDisabled: Int = 0
    var setCalls: [Int] = []
    var failSet = false
    var failRead = false
    /// 模拟慢启用；测试用。
    var delaySetNanoseconds: UInt64 = 0

    func refreshCapability() async -> ClamshellCapability { .ready }

    func readSleepDisabled() async throws -> Int {
        if failRead { throw KeepAwakeError.clamshellStateUnverified("read fail") }
        return sleepDisabled
    }

    func setSleepDisabled(_ value: Int, allowPasswordPrompt: Bool) async throws {
        if delaySetNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delaySetNanoseconds)
        }
        setCalls.append(value)
        if failSet { throw KeepAwakeError.sleepRestoreFailed("set fail") }
        sleepDisabled = value
    }

    func installAuthorization() async throws {}
    func removeAuthorization() async throws {}
}

@MainActor
final class ClamshellRecoveryCoordinatorTests: XCTestCase {
    private var tempRoot: URL!
    private var store: ClamshellRecoveryStore!
    private var controller: FakeClamshellController!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-coord-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = ClamshellRecoveryStore(applicationSupportRoot: tempRoot)
        controller = FakeClamshellController()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeCoordinator() -> ClamshellRecoveryCoordinator {
        ClamshellRecoveryCoordinator(
            store: store,
            controller: controller,
            userName: "seam",
            uid: 501
        )
    }

    func test_noRecord_sleepZero_recoversAndUnblocks() async {
        controller.sleepDisabled = 0
        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        XCTAssertEqual(coord.state, .recovered)
        XCTAssertFalse(coord.blocksKeepAwakeStart)
        XCTAssertTrue(controller.setCalls.isEmpty)
    }

    func test_preparedPlusOne_restoresAndDeletes() async throws {
        let record = ClamshellRecoveryRecord.makePrepared(
            userName: "seam",
            uid: 501,
            operationID: "op-crash-window"
        )
        // changedByInputLock=false 仍须恢复
        XCTAssertFalse(record.changedByInputLock)
        try store.save(record)
        controller.sleepDisabled = 1

        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        XCTAssertEqual(coord.state, .recovered)
        XCTAssertFalse(coord.blocksKeepAwakeStart)
        XCTAssertEqual(controller.setCalls, [0])
        XCTAssertNil(try store.load(expectedUID: 501, expectedUserName: "seam"))
    }

    func test_preparedPlusZero_deletesOnly() async throws {
        try store.save(ClamshellRecoveryRecord.makePrepared(userName: "seam", uid: 501, operationID: "op"))
        controller.sleepDisabled = 0
        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        XCTAssertEqual(coord.state, .recovered)
        XCTAssertTrue(controller.setCalls.isEmpty)
        XCTAssertNil(try store.load(expectedUID: 501, expectedUserName: "seam"))
    }

    func test_enabledPlusOne_restores() async throws {
        var record = ClamshellRecoveryRecord.makePrepared(userName: "seam", uid: 501, operationID: "op")
        record.phase = .enabled
        record.changedByInputLock = true
        try store.save(record)
        controller.sleepDisabled = 1
        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        XCTAssertEqual(coord.state, .recovered)
        XCTAssertEqual(controller.setCalls, [0])
    }

    func test_noRecord_sleepOne_conflictsWithoutWriting() async {
        controller.sleepDisabled = 1
        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        guard case .conflict = coord.state else {
            return XCTFail("expected conflict, got \(coord.state)")
        }
        XCTAssertTrue(coord.blocksKeepAwakeStart)
        XCTAssertTrue(controller.setCalls.isEmpty)
    }

    func test_restoreFailure_cleanupRequiredAndBlocksStart() async throws {
        try store.save(ClamshellRecoveryRecord.makePrepared(userName: "seam", uid: 501, operationID: "op"))
        controller.sleepDisabled = 1
        controller.failSet = true
        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        guard case .cleanupRequired = coord.state else {
            return XCTFail("expected cleanupRequired, got \(coord.state)")
        }
        XCTAssertTrue(coord.blocksKeepAwakeStart)
    }

    func test_corruptRecord_blocksAndDoesNotDelete() async throws {
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        let coord = makeCoordinator()
        await coord.recoverOnLaunch()
        guard case .cleanupRequired = coord.state else {
            return XCTFail("expected cleanupRequired, got \(coord.state)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(coord.blocksKeepAwakeStart)
    }
}
