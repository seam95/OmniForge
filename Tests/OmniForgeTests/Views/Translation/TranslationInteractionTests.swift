import AppKit
import XCTest
@testable import OmniForge

/// 实用工具入口与管理页交互语义：进入详情不弹浮窗、历史只查看不重译、删除需要显式动作。
///
/// SwiftUI 按钮点击无法在 SPM 测试目标中直接驱动；这里验证视图构造与 manager 动作边界，
/// 真实点击/确认弹窗留真机验收（见 PLAN 第 7 节验证记录）。
@MainActor
final class TranslationInteractionTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var preferences: TranslationPreferences!
    private var store: InMemoryTranslationHistoryStore!
    private var engine: StubTranslationEngine!
    private var presenter: RecordingTranslationWindowPresenter!
    private var manager: TranslationManager!

    override func setUp() {
        super.setUp()
        suiteName = "TranslationInteractionTests-\(UUID().uuidString)"
        defaults = makeTranslationTestDefaults(suiteName)
        preferences = TranslationPreferences(userDefaults: defaults)
        store = InMemoryTranslationHistoryStore()
        engine = StubTranslationEngine()
        presenter = RecordingTranslationWindowPresenter()
        manager = makeTranslationTestManager(preferences: preferences, store: store, engine: engine)
        manager.windowPresenter = presenter
    }

    override func tearDown() {
        manager.teardown()
        manager = nil
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_enterUtilityShowsManagementOnly() {
        // 管理页只构造详情视图：不得自动打开浮窗或发起请求。
        _ = TranslationUtilityDetailView(
            manager: manager,
            preferences: preferences,
            strings: .en,
            hotkeyManager: nil
        )

        XCTAssertEqual(presenter.showCount, 0, "进入管理页不得自动打开浮窗")
        XCTAssertTrue(engine.receivedRequests.isEmpty)
        XCTAssertTrue(manager.history.isEmpty)
    }

    func test_historyClickOpensStoredResultWithoutRequest() async {
        let request = TranslationRequest(
            text: "history source",
            sourceLanguage: "en",
            targetLanguage: "zh-Hans"
        )
        let entry = TranslationHistoryEntry(
            request: request,
            result: TranslationResult(
                text: "历史译文",
                sourceLanguage: "en",
                targetLanguage: "zh-Hans",
                engine: .ai,
                model: "m"
            )
        )
        store.entries = [entry]
        await manager.reloadHistory()

        manager.openHistory(entry)

        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.lastFocusInput, false, "查看历史不抢输入焦点")
        XCTAssertTrue(engine.receivedRequests.isEmpty, "查看历史不得重新翻译")
        XCTAssertEqual(manager.result?.text, "历史译文")
        XCTAssertTrue(manager.canCopyResult)
    }

    func test_deleteRequiresExplicitManagerActionAndKeepsSession() async {
        let request = TranslationRequest(text: "a", sourceLanguage: "en", targetLanguage: "zh-Hans")
        let entry = TranslationHistoryEntry(
            request: request,
            result: TranslationResult(
                text: "t",
                sourceLanguage: "en",
                targetLanguage: "zh-Hans",
                engine: .system
            )
        )
        store.entries = [entry]
        await manager.reloadHistory()

        // 仅打开历史不会删除任何记录。
        manager.openHistory(entry)
        XCTAssertEqual(store.entries.count, 1)

        await manager.deleteHistory(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(manager.sourceText, "a", "删除历史不清除当前会话")
    }

    func test_managementPageNewButtonCreatesBlankSession() {
        manager.updateText("旧草稿")
        manager.newSession()

        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.lastFocusInput, true)
        XCTAssertEqual(manager.sourceText, "")
        XCTAssertNil(manager.result)
    }

    func test_presentationMapsLanguagesAndDirection() {
        let strings = Strings.zhHans
        XCTAssertEqual(
            TranslationPresentation.languageName(for: "zh-Hans", strings: strings),
            strings.translationLanguageChineseSimplified
        )
        XCTAssertEqual(
            TranslationPresentation.languageName(for: "en-US", strings: strings),
            strings.translationLanguageEnglish
        )
        XCTAssertEqual(TranslationPresentation.symbolName, "character.bubble")
        XCTAssertEqual(
            TranslationPresentation.languageName(for: "zh-Hant", strings: strings),
            strings.translationLanguageChineseTraditional
        )
    }

    func test_utilityListShowsTranslationOnlyWhenAvailable() {
        XCTAssertTrue(
            UtilityTool.visibleCases(isAvailable: { $0 == .translation }).contains(.translation)
        )
        XCTAssertEqual(UtilityTool.translation.tintColor, .teal)
    }
}
