import XCTest
@testable import OmniForge

@MainActor
final class RightClickServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var notificationCenter: NotificationCenter!
    /// 令牌读写注入域：# 前缀的 suite 是不落盘的易失域，测试不污染真实 App Group 容器。
    private var sharedTokenDefaults: UserDefaults!
    private var service: RightClickService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniForgeRightClickServiceTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        notificationCenter = NotificationCenter()
        sharedTokenDefaults = UserDefaults(suiteName: "#RightClickServiceTests_\(UUID().uuidString)")
        service = RightClickService(
            executor: RightClickActionExecutor(fileRevealer: { _ in }),
            notificationCenter: notificationCenter,
            tokenDefaults: sharedTokenDefaults
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

    // MARK: - IPC 共享令牌校验（防伪造分布式通知）

    /// 首次启动必须把令牌写进 App Group 域：沙盒扩展只能读 App Group，
    /// 写 .standard 等于扩展永远读不到，校验永远失败。
    func test_start_generatesTokenIntoAppGroupDefaults() throws {
        let defaults = makeVolatileDefaults()
        let service = makeService(executor: SpyActionExecutor(), tokenDefaults: defaults)
        defer { service.stop() }

        service.start()

        let token = try XCTUnwrap(defaults.string(forKey: RightClickService.ipcTokenKey))
        XCTAssertFalse(token.isEmpty, "令牌应为非空随机值")
    }

    /// 宿主重启不得轮换已有令牌：轮换会让扩展手中的旧令牌在窗口期失效。
    func test_start_reusesExistingTokenInsteadOfRotating() throws {
        let defaults = makeVolatileDefaults()
        defaults.set("preexisting-token", forKey: RightClickService.ipcTokenKey)
        let service = makeService(executor: SpyActionExecutor(), tokenDefaults: defaults)
        defer { service.stop() }

        service.start()

        XCTAssertEqual(defaults.string(forKey: RightClickService.ipcTokenKey), "preexisting-token")
    }

    /// 不带令牌的消息（伪造者可省略字段冒充旧版扩展）必须被拒绝执行。
    func test_handleNotification_withoutToken_doesNotExecuteAction() async throws {
        let spy = SpyActionExecutor()
        let service = makeService(executor: spy, tokenDefaults: makeVolatileDefaults())
        service.start()
        defer { service.stop() }

        post("newFile", parameter: "txt", targets: [tempDirectory.absoluteString], token: nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(spy.createFileCalls.isEmpty, "无令牌载荷不得触达执行层")
    }

    /// 令牌不匹配（猜测/篡改）必须被拒绝执行。
    func test_handleNotification_withMismatchedToken_doesNotExecuteAction() async throws {
        let spy = SpyActionExecutor()
        let service = makeService(executor: spy, tokenDefaults: makeVolatileDefaults())
        service.start()
        defer { service.stop() }

        // 伪造者猜测的令牌：与 App Group 中的真值不符
        post("newFile", parameter: "txt", targets: [tempDirectory.absoluteString], token: "attacker-forged-token")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(spy.createFileCalls.isEmpty, "令牌不匹配的载荷不得触达执行层")
    }

    /// 令牌匹配（与 App Group 中一致）时正常分发动作。
    func test_handleNotification_withMatchingToken_dispatchesAction() async throws {
        let spy = SpyActionExecutor()
        let defaults = makeVolatileDefaults()
        let service = makeService(executor: spy, tokenDefaults: defaults)
        service.start()
        defer { service.stop() }

        post("newFile", parameter: "txt", targets: [tempDirectory.absoluteString],
             token: defaults.string(forKey: RightClickService.ipcTokenKey))
        let dispatched = await waitUntil { !spy.createFileCalls.isEmpty }

        XCTAssertTrue(dispatched, "令牌匹配的载荷应正常分发")
        XCTAssertEqual(spy.createFileCalls.count, 1)
        XCTAssertEqual(spy.createFileCalls.first?.fileExtension, "txt")
    }

    // MARK: - 动作分发缺口（审计补充）

    /// moveTo 的目标目录不存在、targetURLs 混入非法 URL 字符串时：
    /// 非法目标被过滤，合法目标仍送达执行层（目录校验由执行层负责），且不崩溃。
    func test_handleNotification_moveToWithInvalidTargets_dispatchesOnlyValidURLs() async throws {
        let spy = SpyActionExecutor()
        let defaults = makeVolatileDefaults()
        let service = makeService(executor: spy, tokenDefaults: defaults)
        service.start()
        defer { service.stop() }

        post("moveTo", parameter: "/nonexistent/destination",
             targets: ["file:///tmp/a.txt", "not a url"],
             token: defaults.string(forKey: RightClickService.ipcTokenKey))
        let dispatched = await waitUntil { !spy.moveCalls.isEmpty }

        XCTAssertTrue(dispatched)
        XCTAssertEqual(spy.moveCalls.count, 1)
        XCTAssertEqual(spy.moveCalls.first?.sources.map(\.absoluteString), ["file:///tmp/a.txt"],
                       "非法 URL 字符串应在分发前被过滤")
        XCTAssertEqual(spy.moveCalls.first?.destination.path, "/nonexistent/destination")
    }

    /// copyTo 缺少目标参数（parameter 为 nil）时：分发层仍以空路径送达执行层，
    /// 由执行层报「目标目录不存在」，分发路径不得崩溃。
    func test_handleNotification_copyToWithoutParameter_dispatchesToExecutorWithoutCrash() async throws {
        let spy = SpyActionExecutor()
        let defaults = makeVolatileDefaults()
        let service = makeService(executor: spy, tokenDefaults: defaults)
        service.start()
        defer { service.stop() }

        post("copyTo", parameter: nil,
             targets: ["file:///tmp/a.txt"],
             token: defaults.string(forKey: RightClickService.ipcTokenKey))
        let dispatched = await waitUntil { !spy.copyCalls.isEmpty }

        XCTAssertTrue(dispatched)
        XCTAssertEqual(spy.copyCalls.count, 1)
        XCTAssertEqual(spy.copyCalls.first?.sources.map(\.absoluteString), ["file:///tmp/a.txt"])
    }

    /// copyPath 的格式参数为未知值时回退 posix 格式（现有 `?? .posix` 行为的回归锁定）。
    func test_handleNotification_copyPathWithUnknownFormat_fallsBackToPosix() async throws {
        let spy = SpyActionExecutor()
        let defaults = makeVolatileDefaults()
        let service = makeService(executor: spy, tokenDefaults: defaults)
        service.start()
        defer { service.stop() }

        post("copyPath", parameter: "bogus-format",
             targets: ["file:///tmp/a.txt"],
             token: defaults.string(forKey: RightClickService.ipcTokenKey))
        let dispatched = await waitUntil { !spy.copyPathCalls.isEmpty }

        XCTAssertTrue(dispatched)
        XCTAssertEqual(spy.copyPathCalls.count, 1)
        XCTAssertEqual(spy.copyPathCalls.first?.format, .posix, "未知格式必须回退 posix")
        XCTAssertEqual(spy.copyPathCalls.first?.urls.map(\.absoluteString), ["file:///tmp/a.txt"])
    }

    /// toggleHiddenFiles 缺辅助功能权限（toggler 返回 false）时：
    /// 必须走到权限引导回调，而不是静默失败。
    func test_handleNotification_toggleHiddenFilesWithoutAccessibilityPrompt_promptsForPermission() async throws {
        let spy = SpyActionExecutor()
        spy.toggleResult = false // 模拟未获辅助功能权限
        let promptSpy = AccessibilityPromptSpy()
        let defaults = makeVolatileDefaults()
        let service = makeService(
            executor: spy,
            tokenDefaults: defaults,
            accessibilityPrompter: promptSpy.record
        )
        service.start()
        defer { service.stop() }

        post("toggleHiddenFiles", parameter: nil, targets: [],
             token: defaults.string(forKey: RightClickService.ipcTokenKey))
        let dispatched = await waitUntil { spy.toggleCalls == 1 }

        XCTAssertTrue(dispatched)
        XCTAssertEqual(promptSpy.count, 1, "缺权限路径应触发一次权限引导")
    }

    // MARK: - 辅助

    private func makeService(
        executor: any RightClickActionExecuting,
        tokenDefaults: UserDefaults,
        accessibilityPrompter: @escaping () -> Void = {}
    ) -> RightClickService {
        RightClickService(
            executor: executor,
            notificationCenter: notificationCenter,
            tokenDefaults: tokenDefaults,
            accessibilityPrompter: accessibilityPrompter
        )
    }

    private func makeVolatileDefaults() -> UserDefaults {
        // # 前缀：仅存在于本进程内存的易失域，测试间互不干扰
        UserDefaults(suiteName: "#RightClickServiceTests_\(UUID().uuidString)")!
    }

    /// 按给定令牌构造载荷并发出通知（令牌为 nil 时 JSON 中省略该字段，模拟旧格式载荷）。
    private func post(_ actionType: String, parameter: String?, targets: [String], token: String?) {
        let message = RightClickIPCMessage(
            actionType: actionType,
            parameter: parameter,
            targetURLs: targets,
            token: token
        )
        let data = try! JSONEncoder().encode(message)
        notificationCenter.post(
            name: NSNotification.Name(RightClickIPCMessage.notificationName),
            object: String(data: data, encoding: .utf8)
        )
    }

    private func postNewFileAction() {
        post("newFile", parameter: "txt", targets: [tempDirectory.absoluteString],
             token: sharedTokenDefaults.string(forKey: RightClickService.ipcTokenKey))
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

    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}

/// 测试替身：记录分发到执行层的调用，不触碰真实文件系统、剪贴板与系统事件。
/// moveTo/copyTo 在后台 Task 执行，计数访问需加锁。
private final class SpyActionExecutor: RightClickActionExecuting {
    private let lock = NSLock()
    private var _createFileCalls: [(directory: URL, fileExtension: String, baseName: String)] = []
    private var _openTerminalCalls: [(target: URL, bundleId: String?)] = []
    private var _openCalls: [(urls: [URL], bundleId: String)] = []
    private var _copyPathCalls: [(urls: [URL], format: RightClickPathFormat)] = []
    private var _moveCalls: [(sources: [URL], destination: URL)] = []
    private var _copyCalls: [(sources: [URL], destination: URL)] = []
    private var _toggleCalls = 0

    /// toggleHiddenFiles 的模拟返回值：false 表示未获辅助功能权限。
    var toggleResult = true

    var createFileCalls: [(directory: URL, fileExtension: String, baseName: String)] {
        lock.withLock { _createFileCalls }
    }

    var openTerminalCalls: [(target: URL, bundleId: String?)] {
        lock.withLock { _openTerminalCalls }
    }

    var openCalls: [(urls: [URL], bundleId: String)] {
        lock.withLock { _openCalls }
    }

    var copyPathCalls: [(urls: [URL], format: RightClickPathFormat)] {
        lock.withLock { _copyPathCalls }
    }

    var moveCalls: [(sources: [URL], destination: URL)] {
        lock.withLock { _moveCalls }
    }

    var copyCalls: [(sources: [URL], destination: URL)] {
        lock.withLock { _copyCalls }
    }

    var toggleCalls: Int {
        lock.withLock { _toggleCalls }
    }

    func createUniqueEmptyFile(in directoryURL: URL, fileExtension: String, baseName: String) throws -> URL {
        lock.withLock { _createFileCalls.append((directoryURL, fileExtension, baseName)) }
        return directoryURL
    }

    func openTerminal(at targetURL: URL, bundleId: String?) throws {
        lock.withLock { _openTerminalCalls.append((targetURL, bundleId)) }
    }

    func open(urls: [URL], withAppBundleIdentifier bundleId: String) throws {
        lock.withLock { _openCalls.append((urls, bundleId)) }
    }

    @discardableResult
    func copyPathsToPasteboard(_ urls: [URL], format: RightClickPathFormat) -> String {
        lock.withLock { _copyPathCalls.append((urls, format)) }
        return ""
    }

    func moveFiles(_ sourceURLs: [URL], to targetDirectoryURL: URL) throws -> [URL] {
        lock.withLock { _moveCalls.append((sourceURLs, targetDirectoryURL)) }
        return []
    }

    func copyFiles(_ sourceURLs: [URL], to targetDirectoryURL: URL) throws -> [URL] {
        lock.withLock { _copyCalls.append((sourceURLs, targetDirectoryURL)) }
        return []
    }

    @discardableResult
    func toggleHiddenFiles() -> Bool {
        lock.withLock { _toggleCalls += 1 }
        return toggleResult
    }
}

/// 权限引导回调的测试替身：计数代替真实的系统授权弹窗。
private final class AccessibilityPromptSpy {
    private let lock = NSLock()
    private var _count = 0

    var count: Int {
        lock.withLock { _count }
    }

    func record() {
        lock.withLock { _count += 1 }
    }
}
