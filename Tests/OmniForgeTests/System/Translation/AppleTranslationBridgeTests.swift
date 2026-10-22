import Foundation
import Translation
import XCTest
@testable import OmniForge

// 测试目标 deployment target 仍为 macOS 14，引用系统翻译桥接的用例逐方法标注
// @available(macOS 15.0, *)，在 macOS 14 运行环境不执行这些用例。

/// 系统语言可用性的假实现：固定返回状态，并记录查询过的语言对。
@available(macOS 15.0, *)
private final class FakeAvailabilityProvider: AppleTranslationAvailabilityProviding, @unchecked Sendable {
    var statusResult: AppleTranslationLanguagePairStatus
    var supportedCodes: [String]
    private(set) var queriedPairs: [(String, String)] = []

    init(
        status: AppleTranslationLanguagePairStatus = .installed,
        supportedCodes: [String] = ["en", "zh-Hans"]
    ) {
        self.statusResult = status
        self.supportedCodes = supportedCodes
    }

    func status(sourceLanguage: String, targetLanguage: String) async -> AppleTranslationLanguagePairStatus {
        queriedPairs.append((sourceLanguage, targetLanguage))
        return statusResult
    }

    func supportedLanguageCodes() async -> [String] {
        supportedCodes
    }
}

/// 系统会话操作的假实现：不依赖真实 TranslationSession 与模型下载。
///
/// 允许注入准备/翻译阶段的错误，用于模拟下载拒绝等系统侧失败。
/// 仅在测试的串行 await 流程中使用，因此用 @unchecked Sendable 关闭并发检查。
@available(macOS 15.0, *)
private final class FakeSessionDriver: AppleTranslationSessionDriving, @unchecked Sendable {
    /// 会话语言对：模拟宿主会话创建时的语言；nil 表示未知（不参与校验）。
    var sourceLanguage: String?
    var targetLanguage: String?
    var prepareError: Error?
    var translateError: Error?
    var outcome: AppleTranslationSessionOutcome
    private(set) var prepareCallCount = 0
    private(set) var translateCallCount = 0
    private(set) var translatedTexts: [String] = []

    init(
        outcome: AppleTranslationSessionOutcome = AppleTranslationSessionOutcome(
            text: "译文",
            sourceLanguage: nil,
            targetLanguage: nil
        )
    ) {
        self.outcome = outcome
    }

    func prepareTranslation() async throws {
        prepareCallCount += 1
        if let prepareError {
            throw prepareError
        }
    }

    func translate(_ text: String) async throws -> AppleTranslationSessionOutcome {
        translateCallCount += 1
        translatedTexts.append(text)
        if let translateError {
            throw translateError
        }
        return outcome
    }
}

/// macOS 15 系统翻译桥接的定向测试。
///
/// 全部使用假会话驱动，不触发真实模型下载或网络请求；
/// 真实系统翻译、首次下载与断网行为留待真机验证。
@MainActor
final class AppleTranslationBridgeTests: XCTestCase {

    private static func makeRequest(
        text: String = "hello",
        source: String = "en",
        target: String = "zh-Hans"
    ) -> TranslationRequest {
        TranslationRequest(text: text, sourceLanguage: source, targetLanguage: target)
    }

    /// 等待 bridge 发布待执行请求；失败时结束该请求并让调用方提前返回，避免测试挂起。
    @available(macOS 15.0, *)
    private func requirePendingCall(
        on bridge: AppleTranslationBridge,
        task: Task<TranslationResult, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        guard await waitForPendingRequest(on: bridge) else {
            bridge.cancel()
            _ = try? await task.value
            XCTFail("bridge 未进入等待状态", file: file, line: line)
            return false
        }
        return true
    }

    /// 轮询等待待执行请求发布。用 1ms 步进让出主 actor，避免固定 sleep 断言。
    @available(macOS 15.0, *)
    private func waitForPendingRequest(
        on bridge: AppleTranslationBridge,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if bridge.pendingRequest != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return bridge.pendingRequest != nil
    }

    // MARK: - 成功路径

    @available(macOS 15.0, *)
    func test_supportedPairReturnsTranslation() async throws {
        let bridge = AppleTranslationBridge(availability: FakeAvailabilityProvider(status: .installed))
        let driver = FakeSessionDriver(
            outcome: AppleTranslationSessionOutcome(
                text: "你好",
                sourceLanguage: "en",
                targetLanguage: "zh-Hans"
            )
        )
        let request = Self.makeRequest()

        let task = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: task) else { return }
        await bridge.runSession(driver)

        let result = try await task.value
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertEqual(result.targetLanguage, "zh-Hans")
        XCTAssertEqual(result.engine, .system)
        XCTAssertNil(result.model)
        XCTAssertEqual(driver.prepareCallCount, 1)
        XCTAssertEqual(driver.translateCallCount, 1)
        XCTAssertEqual(driver.translatedTexts, ["hello"])
        XCTAssertNil(bridge.pendingRequest)
        XCTAssertNil(bridge.configuration)
    }

    // MARK: - 准备失败与重试

    @available(macOS 15.0, *)
    func test_downloadDeclinedCanRetry() async throws {
        let bridge = AppleTranslationBridge(availability: FakeAvailabilityProvider(status: .supported))
        let driver = FakeSessionDriver(
            outcome: AppleTranslationSessionOutcome(
                text: "你好",
                sourceLanguage: nil,
                targetLanguage: nil
            )
        )
        // 模拟用户在系统下载确认中拒绝：准备阶段抛出非取消错误。
        driver.prepareError = NSError(domain: "AppleTranslationBridgeTests.download", code: 1)
        let request = Self.makeRequest()

        let firstTask = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: firstTask) else { return }
        await bridge.runSession(driver)

        do {
            _ = try await firstTask.value
            XCTFail("下载被拒应抛出 modelNotPrepared")
        } catch let error as OmniForge.TranslationError {
            XCTAssertEqual(error, .modelNotPrepared)
        }
        XCTAssertNil(bridge.pendingRequest)
        XCTAssertNil(bridge.configuration)

        // 拒绝后原文保留，可再次提交并成功：模型准备由系统重新发起。
        driver.prepareError = nil
        let secondTask = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: secondTask) else { return }
        await bridge.runSession(driver)

        let result = try await secondTask.value
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(result.sourceLanguage, "en")
        XCTAssertEqual(result.targetLanguage, "zh-Hans")
        XCTAssertEqual(driver.translateCallCount, 1)
    }

    // MARK: - 迟到旧会话

    @available(macOS 15.0, *)
    func test_staleSessionWithDifferentLanguagePairDoesNotStealNewRequest() async throws {
        let bridge = AppleTranslationBridge(availability: FakeAvailabilityProvider())

        // 旧会话（德语→中文）在配置切换后才被调度：不得领取新的英译中请求。
        let staleDriver = FakeSessionDriver()
        staleDriver.sourceLanguage = "de"
        staleDriver.targetLanguage = "zh-Hans"
        let request = Self.makeRequest(source: "en", target: "zh-Hans")

        let task = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: task) else { return }

        await bridge.runSession(staleDriver)
        XCTAssertEqual(staleDriver.prepareCallCount, 0, "旧会话不得处理新请求")
        XCTAssertEqual(staleDriver.translateCallCount, 0)
        XCTAssertNotNil(bridge.pendingRequest, "请求应继续等待匹配的会话")

        // 正确语言对的会话随后处理并成功。
        let freshDriver = FakeSessionDriver(
            outcome: AppleTranslationSessionOutcome(
                text: "你好",
                sourceLanguage: nil,
                targetLanguage: nil
            )
        )
        freshDriver.sourceLanguage = "en"
        freshDriver.targetLanguage = "zh"
        await bridge.runSession(freshDriver)

        let result = try await task.value
        XCTAssertEqual(result.text, "你好")
        XCTAssertEqual(freshDriver.translateCallCount, 1)
        XCTAssertEqual(freshDriver.translatedTexts, ["hello"])
    }

    // MARK: - 取消语义

    @available(macOS 15.0, *)
    func test_cancelResumesPendingCallerOnce() async throws {
        let bridge = AppleTranslationBridge(availability: FakeAvailabilityProvider())
        let driver = FakeSessionDriver()
        let request = Self.makeRequest()

        let task = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: task) else { return }
        bridge.cancel()
        // 第二次取消必须是幂等空操作，不能重复恢复等待者。
        bridge.cancel()

        do {
            _ = try await task.value
            XCTFail("取消后应抛出 CancellationError")
        } catch is CancellationError {
            // 预期：取消保持 CancellationError，不映射成 TranslationError。
        }
        XCTAssertNil(bridge.pendingRequest)
        XCTAssertNil(bridge.configuration)

        // 取消后迟到的系统会话不得恢复等待者，也不得调用系统翻译。
        await bridge.runSession(driver)
        XCTAssertEqual(driver.prepareCallCount, 0)
        XCTAssertEqual(driver.translateCallCount, 0)
    }

    @available(macOS 15.0, *)
    func test_detachedHostCancelsPendingRequest() async throws {
        let bridge = AppleTranslationBridge(availability: FakeAvailabilityProvider())
        bridge.hostDidAppear()
        XCTAssertTrue(bridge.isTaskHostAttached)
        let request = Self.makeRequest()

        let task = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: task) else { return }
        // 窗口收起后 SwiftUI 树不保证销毁，宿主移除必须显式结束等待。
        bridge.hostDidDisappear()
        XCTAssertFalse(bridge.isTaskHostAttached)

        do {
            _ = try await task.value
            XCTFail("宿主移除后应抛出 CancellationError")
        } catch is CancellationError {
            // 预期：不留下挂起的等待者。
        }
        XCTAssertNil(bridge.pendingRequest)
        XCTAssertNil(bridge.configuration)
    }

    // MARK: - 重试配置与语言可用性

    @available(macOS 15.0, *)
    func test_samePairRetryUsesFreshTaskConfiguration() async throws {
        let bridge = AppleTranslationBridge(availability: FakeAvailabilityProvider())
        let secondDriver = { () -> FakeSessionDriver in
            FakeSessionDriver(
                outcome: AppleTranslationSessionOutcome(
                    text: "你好",
                    sourceLanguage: nil,
                    targetLanguage: nil
                )
            )
        }
        let request = Self.makeRequest()

        let firstTask = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: firstTask) else { return }
        let firstConfiguration = try XCTUnwrap(bridge.configuration)
        await bridge.runSession(secondDriver())
        _ = try await firstTask.value

        // 同一语言对再次提交：Configuration 相等时 SwiftUI 不会重新执行 translationTask，
        // 因此必须显式失效，让宿主重新取得会话并重新触发准备流程。
        let secondTask = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: secondTask) else { return }
        let retriedConfiguration = try XCTUnwrap(bridge.configuration)
        XCTAssertNotEqual(firstConfiguration, retriedConfiguration)
        XCTAssertEqual(retriedConfiguration.source, Locale.Language(identifier: "en"))
        XCTAssertEqual(retriedConfiguration.target, Locale.Language(identifier: "zh-Hans"))
        await bridge.runSession(secondDriver())
        _ = try await secondTask.value
    }

    @available(macOS 15.0, *)
    func test_unsupportedPairDoesNotCallTranslate() async throws {
        let availability = FakeAvailabilityProvider(status: .unsupported)
        let bridge = AppleTranslationBridge(availability: availability)
        let driver = FakeSessionDriver()
        let request = Self.makeRequest()

        let task = Task { try await bridge.translate(request) }
        guard await requirePendingCall(on: bridge, task: task) else { return }
        await bridge.runSession(driver)

        do {
            _ = try await task.value
            XCTFail("不支持的语言对应抛出 unsupportedLanguagePair")
        } catch let error as OmniForge.TranslationError {
            XCTAssertEqual(
                error,
                .unsupportedLanguagePair(source: "en", target: "zh-Hans")
            )
        }
        // 语言对不支持时不得进入准备或翻译，避免触发无意义的下载流程。
        XCTAssertEqual(driver.prepareCallCount, 0)
        XCTAssertEqual(driver.translateCallCount, 0)
        XCTAssertEqual(availability.queriedPairs.count, 1)
        XCTAssertEqual(availability.queriedPairs.first?.0, "en")
        XCTAssertEqual(availability.queriedPairs.first?.1, "zh-Hans")
    }
}
