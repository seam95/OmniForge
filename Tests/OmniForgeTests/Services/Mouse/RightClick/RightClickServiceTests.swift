import XCTest
@testable import OmniForge

@MainActor
final class RightClickServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var notificationCenter: NotificationCenter!
    private var service: RightClickService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniForgeRightClickServiceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        notificationCenter = NotificationCenter()
        service = RightClickService(
            executor: RightClickActionExecutor(fileRevealer: { _ in }),
            notificationCenter: notificationCenter
        )
    }

    override func tearDownWithError() throws {
        service?.stop()
        service = nil
        notificationCenter = nil
        if let temp = tempDirectory, FileManager.default.fileExists(atPath: temp.path) {
            try? FileManager.default.removeItem(at: temp)
        }
        FeatureRuntime.shared.resetForTesting()
        UserDefaults.standard.removeObject(forKey: AppFeature.rightClickEnhancement.availabilityKey)
        try super.tearDownWithError()
    }

    // MARK: - 幂等与启停

    func test_startTwice_handlesSingleNotificationOnce() async throws {
        service.start()
        service.start()

        postNewFileAction()
        _ = await waitForFileCount(atLeast: 1)
        // 给潜在的第二个 handler 留出执行窗口，确认没有重复处理
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(createdFileCount, 1, "同一实例重复 start 不得注册多个观察者")
    }

    func test_stop_removesObserver() async throws {
        service.start()
        service.stop()

        postNewFileAction()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(createdFileCount, 0)
        XCTAssertFalse(service.isRunning)
    }

    func test_restartAfterStop_resumesHandling() async throws {
        service.start()
        service.stop()
        service.start()

        postNewFileAction()
        _ = await waitForFileCount(atLeast: 1)

        XCTAssertEqual(createdFileCount, 1)
    }

    // MARK: - FeatureRuntime 接线回归

    /// 回归：binding 必须启停 registry 中的实例。
    /// 曾改为启动另一份单例，导致每个右键动作被执行两次。
    func test_runtimeBinding_startsRegisteredInstanceOnly() async throws {
        UserDefaults.standard.set(true, forKey: AppFeature.rightClickEnhancement.availabilityKey)
        FeatureRuntime.shared.resetForTesting()
        // 显式标注类型：隐式解包可选的属性会让泛型 T 推断成 Optional，注册键与查询键不一致。
        let registered: RightClickService = service
        FeatureRuntime.shared.register(.rightClickEnhancement, manager: registered)

        FeatureRuntime.shared.sync([.rightClickEnhancement])

        XCTAssertTrue(FeatureRuntime.shared.isAvailable(.rightClickEnhancement))
        XCTAssertNotNil(FeatureRuntime.shared.manager(for: .rightClickEnhancement, as: RightClickService.self))
        XCTAssertTrue(service.isRunning, "binding 应启动注册表中的实例")

        postNewFileAction()
        _ = await waitForFileCount(atLeast: 1)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(createdFileCount, 1)
    }

    // MARK: - 辅助

    private func postNewFileAction() {
        let message = RightClickIPCMessage(
            actionType: "newFile",
            parameter: "txt",
            targetURLs: [tempDirectory.absoluteString]
        )
        let data = try! JSONEncoder().encode(message)
        let json = String(data: data, encoding: .utf8)!
        notificationCenter.post(
            name: NSNotification.Name(RightClickIPCMessage.notificationName),
            object: json
        )
    }

    private var createdFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path).count) ?? 0
    }

    private func waitForFileCount(atLeast expected: Int, timeout: TimeInterval = 2) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = createdFileCount
            if count >= expected {
                return count
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return createdFileCount
    }
}
