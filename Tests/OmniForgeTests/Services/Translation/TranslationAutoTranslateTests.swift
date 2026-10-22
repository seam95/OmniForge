import XCTest

@testable import OmniForge

// MARK: - 自动翻译（输入停顿触发）

/// 覆盖防抖自动翻译的触发条件与竞态：只翻译最后一次输入、空白/超长不请求、
/// 设置变化立即重译、清空文本取消排队中的请求。
@MainActor
final class TranslationAutoTranslateTests: XCTestCase {
    private final class EmptyStore: TranslationHistoryStoring {
        func load(limit: Int) async throws -> [TranslationHistoryEntry] { [] }
        func insertAndPrune(_ entry: TranslationHistoryEntry, limit: Int) async throws {}
        func delete(id: UUID) async throws {}
        func deleteAll() async throws {}
    }

    /// 立即返回的引擎：只记录请求，便于断言触发次数与文本。
    private final class ImmediateEngine: TranslationEngine {
        private(set) var requests: [TranslationRequest] = []

        func translate(_ request: TranslationRequest) async throws -> TranslationResult {
            requests.append(request)
            return TranslationResult(
                text: "译:" + request.text,
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                engine: .system
            )
        }

        func cancel() {}
    }

    private var suiteName = ""
    private var userDefaults: UserDefaults!
    private var preferences: TranslationPreferences!
    private var engine: ImmediateEngine!
    private var manager: TranslationManager!

    override func setUp() {
        super.setUp()
        suiteName = "TranslationAutoTranslateTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        Defaults.register(in: userDefaults)
        preferences = TranslationPreferences(userDefaults: userDefaults)
        preferences.engine = .system
        // 固定源语言，避免测试环境的 NaturalLanguage 检测结果波动影响自动翻译断言。
        preferences.sourceLanguage = "en"
        engine = ImmediateEngine()
        manager = makeManager(delay: 0.05)
    }

    override func tearDown() {
        manager?.teardown()
        manager = nil
        userDefaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager(delay: TimeInterval?) -> TranslationManager {
        TranslationManager(
            preferences: preferences,
            historyStore: EmptyStore(),
            resolver: TranslationLanguageResolver(),
            autoTranslateDelay: delay,
            engineFactory: { [weak self] _ in
                guard let self else { throw TranslationError.configurationIncomplete }
                return self.engine
            }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testUpdateTextAutomaticallyTranslatesAfterDelay() async {
        manager.updateText("hello world")

        await waitUntil { self.manager.result != nil }
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests.first?.text, "hello world")
        XCTAssertEqual(manager.result?.text, "译:hello world")
    }

    func testRapidEditsOnlyTranslateFinalText() async {
        manager.updateText("a")
        manager.updateText("ab")
        manager.updateText("abc")

        await waitUntil { self.manager.result != nil }
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests.first?.text, "abc")
    }

    func testBlankTextDoesNotAutoTranslate() async {
        manager.updateText("   \n")

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testTextOverLimitDoesNotAutoTranslate() async {
        manager.updateText(String(repeating: "a", count: TranslationTextValidator.defaultMaxLength + 1))

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testClearingTextCancelsPendingTranslation() async {
        manager.updateText("hello")
        manager.updateText("")

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testTargetChangeRetranslatesExistingText() async {
        manager.updateText("hello")
        await waitUntil { self.manager.result != nil }
        XCTAssertEqual(engine.requests.count, 1)

        manager.selectTarget(.language("ja"))
        await waitUntil { self.engine.requests.count == 2 }
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertEqual(engine.requests.last?.targetLanguage, "ja")
    }

    func testNilDelayRequiresExplicitSubmit() async {
        manager = makeManager(delay: nil)
        manager.updateText("hello")

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(engine.requests.isEmpty)

        manager.submit()
        await waitUntil { self.manager.result != nil }
        XCTAssertEqual(engine.requests.count, 1)
    }
}
