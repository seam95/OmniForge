import AppKit
import XCTest
@testable import OmniForge

// MARK: - 测试假件

/// 共享事件日志：断言「先读选区、后前置窗口」的顺序。
private final class EventLog {
    var events: [String] = []
}

private final class FakeTranslationResolver: TranslationLanguageResolving {
    var result: Result<ResolvedTranslationLanguages, Error> = .success(
        ResolvedTranslationLanguages(source: "en", target: "zh-Hans")
    )
    private(set) var inputs: [(text: String, source: String?, target: TranslationTarget)] = []

    func resolve(
        text: String,
        source: String?,
        target: TranslationTarget
    ) throws -> ResolvedTranslationLanguages {
        inputs.append((text, source, target))
        return try result.get()
    }
}

private final class FakeHistoryStore: TranslationHistoryStoring {
    var entries: [TranslationHistoryEntry] = []
    var loadError: Error?
    var insertError: Error?
    var deleteError: Error?
    var deleteAllError: Error?
    /// 插入钩子：用于把「历史写入排队中」挂起，模拟取消竞态。
    var insertGate: (() async -> Void)?
    private(set) var insertCount = 0

    func load(limit: Int) async throws -> [TranslationHistoryEntry] {
        if let loadError { throw loadError }
        return Array(entries.prefix(limit))
    }

    func insertAndPrune(_ entry: TranslationHistoryEntry, limit: Int) async throws {
        insertCount += 1
        if let insertGate {
            await insertGate()
        }
        // 与生产实现一致：写事务入口检查取消。
        try Task.checkCancellation()
        if let insertError { throw insertError }
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
    }

    func delete(id: UUID) async throws {
        if let deleteError { throw deleteError }
        entries.removeAll { $0.id == id }
    }

    func deleteAll() async throws {
        if let deleteAllError { throw deleteAllError }
        entries.removeAll()
    }
}

/// 可控引擎：默认挂起 continuation，由测试决定完成时机（不用固定 sleep 断言）。
@MainActor
private final class ControlledEngine: TranslationEngine {
    var autoResult: TranslationResult?
    var autoError: Error?

    private(set) var receivedRequests: [TranslationRequest] = []
    private(set) var cancelCount = 0
    private var pending: [(id: UUID, continuation: CheckedContinuation<TranslationResult, Error>)] = []

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        receivedRequests.append(request)
        if let autoError { throw autoError }
        if let autoResult { return autoResult }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((request.id, continuation))
        }
    }

    /// 只标记取消，不主动恢复：让测试可以模拟「取消后旧响应才迟到」的竞态。
    func cancel() {
        cancelCount += 1
    }

    /// 完成所有挂起请求（含已被取消标记的请求，用于验证迟到响应被丢弃）。
    func completeAll(with result: TranslationResult) {
        let current = pending
        pending = []
        for item in current {
            item.continuation.resume(returning: result)
        }
    }

    func failAll(with error: Error) {
        let current = pending
        pending = []
        for item in current {
            item.continuation.resume(throwing: error)
        }
    }
}

private final class EventRecordingReader: SelectedTextReading {
    var stubbedResult: Result<String, SelectedTextReadFailure> = .failure(.noSelection)
    var log: EventLog?
    private(set) var readCount = 0

    func readSelectedText() -> Result<String, SelectedTextReadFailure> {
        readCount += 1
        log?.events.append("read")
        return stubbedResult
    }
}

@MainActor
private final class FakeWindowPresenter: TranslationWindowPresenting {
    var isKeyWindow = false
    var log: EventLog?
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var lastFocusInput: Bool?

    func show(focusInput: Bool) {
        showCount += 1
        lastFocusInput = focusInput
        log?.events.append("show")
    }

    func hide() {
        hideCount += 1
        log?.events.append("hide")
    }
}

private final class FakePasteboardWriter: PasteboardWriting {
    private(set) var writtenStrings: [String] = []

    func clearContents() {}

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        writtenStrings.append(string)
        return true
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool { true }

    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool { true }
}

// MARK: - 测试

@MainActor
final class TranslationManagerTests: XCTestCase {
    private var suiteName = ""
    private var userDefaults: UserDefaults!
    private var preferences: TranslationPreferences!
    private var store: FakeHistoryStore!
    private var engine: ControlledEngine!
    private var presenter: FakeWindowPresenter!
    private var reader: EventRecordingReader!
    private var resolver: FakeTranslationResolver!
    private var pasteboard: FakePasteboardWriter!
    private var eventLog: EventLog!
    private var isFeatureAvailable = true
    private var manager: TranslationManager!

    override func setUp() {
        super.setUp()
        suiteName = "TranslationManagerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        Defaults.register(in: userDefaults)
        preferences = TranslationPreferences(userDefaults: userDefaults)
        store = FakeHistoryStore()
        engine = ControlledEngine()
        presenter = FakeWindowPresenter()
        reader = EventRecordingReader()
        resolver = FakeTranslationResolver()
        pasteboard = FakePasteboardWriter()
        eventLog = EventLog()
        reader.log = eventLog
        presenter.log = eventLog
        isFeatureAvailable = true
        manager = makeManager()
    }

    override func tearDown() {
        manager?.teardown()
        manager = nil
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager() -> TranslationManager {
        let manager = TranslationManager(
            preferences: preferences,
            historyStore: store,
            resolver: resolver,
            reader: reader,
            pasteboard: pasteboard,
            isFeatureAvailable: { [weak self] in self?.isFeatureAvailable ?? false },
            // 既有用例手动 submit，关闭防抖自动翻译以保持请求次数断言稳定；
            // 自动翻译由 TranslationAutoTranslateTests 单独覆盖。
            autoTranslateDelay: nil,
            engineFactory: { [weak self] _ in
                guard let self else { throw TranslationError.configurationIncomplete }
                return self.engine
            }
        )
        manager.windowPresenter = presenter
        return manager
    }

    /// 让出主 actor，直到条件成立；不依赖固定 sleep 断言。
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "等待条件超时", file: file, line: line)
    }

    private func makeResult(text: String = "译文", engine: TranslationEngineID = .ai) -> TranslationResult {
        TranslationResult(
            text: text,
            sourceLanguage: "en",
            targetLanguage: "zh-Hans",
            engine: engine,
            model: engine == .ai ? "test-model" : nil
        )
    }

    // MARK: - 会话

    func test_newSessionClearsInputWithoutReadingSelection() {
        manager.updateText("尚未翻译的草稿")
        manager.newSession()

        XCTAssertEqual(manager.sourceText, "")
        XCTAssertEqual(reader.readCount, 0, "新建会话不得读取选区")
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.lastFocusInput, true)
    }

    func test_historyViewDoesNotTranslateOrChangePreferredEngine() {
        preferences.engine = .system
        let request = TranslationRequest(
            text: "原文",
            sourceLanguage: "en",
            targetLanguage: "zh-Hans"
        )
        let entry = TranslationHistoryEntry(
            request: request,
            result: makeResult(),
            completedAt: Date()
        )
        engine.autoResult = makeResult(text: "不应被使用")

        manager.openHistory(entry)

        XCTAssertEqual(manager.sourceText, "原文")
        XCTAssertEqual(manager.result?.text, "译文")
        XCTAssertTrue(engine.receivedRequests.isEmpty, "查看历史不得重新翻译")
        XCTAssertEqual(preferences.engine, .system, "查看历史不得改写引擎偏好")
        XCTAssertTrue(manager.canCopyResult)
    }

    // MARK: - 成功与历史

    func test_successSavesOneHistoryEntry() async {
        engine.autoResult = makeResult(text: "你好，世界")

        manager.updateText("hello world")
        manager.submit()

        await waitUntil { manager.history.count == 1 }

        XCTAssertEqual(store.insertCount, 1, "同一次成功请求只保存一次")
        XCTAssertEqual(manager.result?.text, "你好，世界")
        XCTAssertNil(manager.historyError)
        XCTAssertFalse(manager.isResultStale)
    }

    func test_historyDisabledSkipsNewWrites() async {
        preferences.saveHistory = false
        engine.autoResult = makeResult()

        manager.updateText("hello")
        manager.submit()
        await waitUntil { manager.result != nil }

        XCTAssertEqual(store.insertCount, 0, "关闭保存开关后不写新记录")
        XCTAssertTrue(manager.history.isEmpty)
    }

    func test_storeFailureKeepsCopyableResult() async {
        store.insertError = NSError(domain: "test", code: 1)
        engine.autoResult = makeResult(text: "可复制译文")

        manager.updateText("hello")
        manager.submit()
        await waitUntil { manager.historyError != nil }

        XCTAssertEqual(manager.historyError, .historyWriteFailed)
        XCTAssertEqual(manager.result?.text, "可复制译文", "落库失败不影响译文展示")
        XCTAssertTrue(manager.canCopyResult)
    }

    // MARK: - 取消与竞态

    func test_lateResponseDoesNotOverwriteNewText() async {
        manager.updateText("第一段")
        manager.submit()
        await waitUntil { engine.receivedRequests.count == 1 }

        // 新输入到达：取消旧任务；旧响应随后才完成。
        manager.updateText("第二段")
        engine.completeAll(with: makeResult(text: "旧译文"))
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(manager.result, "取消后的迟到响应不得更新界面")
        XCTAssertFalse(manager.isTranslating)
        XCTAssertEqual(store.insertCount, 0, "取消任务不得写历史")
    }

    func test_closeOrDisableCancelsAndPreventsHistory() async {
        manager.updateText("待翻译")
        manager.submit()
        await waitUntil { engine.receivedRequests.count == 1 }

        manager.hide()
        engine.completeAll(with: makeResult())
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertNil(manager.result)
        XCTAssertEqual(store.insertCount, 0)

        // 关闭功能：同样取消请求且不写历史。
        isFeatureAvailable = false
        manager.syncWithPreferences()
        XCTAssertEqual(engine.cancelCount >= 1, true)
    }

    func test_cancelWhileHistoryWriteQueuedDoesNotPersist() async {
        engine.autoResult = makeResult()
        var gateContinuation: CheckedContinuation<Void, Never>?
        store.insertGate = {
            await withCheckedContinuation { continuation in
                gateContinuation = continuation
            }
        }

        manager.updateText("hello")
        manager.submit()
        await waitUntil { store.insertCount == 1 && gateContinuation != nil }

        // 历史写入排队期间取消（新输入）：提交前观察到取消，事务回滚。
        manager.updateText("新输入")
        gateContinuation?.resume()
        gateContinuation = nil
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(store.entries.isEmpty, "取消后排队的历史写入不得落库")
    }

    func test_engineInitiatedCancellationClearsRunningState() async {
        // 引擎自身取消（系统宿主任务终止、URLSession 取消）不经过 manager.cancel()。
        engine.autoError = CancellationError()
        manager.updateText("hello")
        manager.submit()

        await waitUntil { !manager.isTranslating }

        XCTAssertEqual(manager.phase, .idle, "取消后必须退出翻译中，否则按钮永久禁用")
        XCTAssertNil(manager.result)
        XCTAssertFalse(manager.canCopyResult)
    }

    func test_swapLanguagesFromTraditionalChineseAutoUsesEnglishSource() {
        preferences.sourceLanguage = "zh-Hant"
        preferences.target = .automatic

        manager.swapLanguages()

        // 自动方向规则：繁体中文也应按「中文 → 英语」；交换后源语言必须是英语。
        XCTAssertEqual(preferences.sourceLanguage, TranslationLanguage.english)
        XCTAssertEqual(preferences.target, .language("zh-Hant"))
    }

    func test_swapLanguagesFromSimplifiedChineseUsesEnglishSource() {
        preferences.sourceLanguage = "zh-Hans"
        preferences.target = .automatic

        manager.swapLanguages()

        XCTAssertEqual(preferences.sourceLanguage, TranslationLanguage.english)
        XCTAssertEqual(preferences.target, .language("zh-Hans"))
    }

    func test_editingInvalidatesCopyUntilNextSuccess() async {
        engine.autoResult = makeResult(text: "初次译文")
        manager.updateText("hello")
        manager.submit()
        await waitUntil { manager.canCopyResult }

        manager.updateText("hello world")
        XCTAssertFalse(manager.canCopyResult, "编辑原文后旧译文不得复制")
        XCTAssertTrue(manager.isResultStale)
        XCTAssertEqual(manager.result?.text, "初次译文", "旧译文可保留查看")

        engine.autoResult = makeResult(text: "新译文")
        manager.submit()
        await waitUntil { manager.canCopyResult }
        XCTAssertEqual(manager.result?.text, "新译文")
    }

    // MARK: - 快捷键入口动作

    func test_selectionReadPrecedesWindowFront() {
        reader.stubbedResult = .success("选中的文本")
        manager.handleHotkeyTrigger()

        XCTAssertEqual(eventLog.events, ["read", "show"], "必须先取词再前置窗口")
        XCTAssertEqual(manager.sourceText, "选中的文本")
    }

    func test_noSelectionPreservesDraft() {
        manager.updateText("未翻译草稿")
        reader.stubbedResult = .failure(.noSelection)

        manager.handleHotkeyTrigger()

        XCTAssertEqual(manager.sourceText, "未翻译草稿", "无选区不得清空草稿")
        XCTAssertEqual(manager.notice, .noSelection)
        XCTAssertEqual(presenter.showCount, 1)
    }

    func test_permissionFailureStillShowsInput() {
        manager.updateText("保留内容")
        reader.stubbedResult = .failure(.accessibilityInactive)

        manager.handleHotkeyTrigger()

        XCTAssertEqual(manager.notice, .accessibilityRequired)
        XCTAssertEqual(presenter.showCount, 1, "权限异常仍展示输入框")
        XCTAssertEqual(manager.sourceText, "保留内容")
    }

    func test_keyWindowHotkeyDoesNotReadOwnSelection() {
        presenter.isKeyWindow = true

        manager.handleHotkeyTrigger()

        XCTAssertEqual(reader.readCount, 0, "浮窗已聚焦时不读取自己的选区")
        XCTAssertEqual(presenter.showCount, 1)
    }

    // MARK: - 删除历史

    func test_deleteAndClearOnlyTouchHistory() async {
        let entry = TranslationHistoryEntry(
            request: TranslationRequest(text: "a", sourceLanguage: "en", targetLanguage: "zh-Hans"),
            result: makeResult()
        )
        store.entries = [entry]
        await manager.reloadHistory()
        manager.updateText("当前会话")
        manager.openHistory(entry)

        await manager.deleteHistory(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(manager.sourceText, "a", "删除历史不清除当前会话")

        store.entries = [entry]
        await manager.reloadHistory()
        await manager.clearHistory()
        XCTAssertTrue(store.entries.isEmpty)
    }
}
