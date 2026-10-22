import AppKit
import XCTest
@testable import OmniForge

// MARK: - 翻译测试共享假件
//
// 供窗口、交互与集成测试复用；TranslationManagerTests 内部有各自的 file-private 假件，
// 命名刻意不同，避免同一模块内的可见性混淆。

/// 内存历史存储：可注入读写失败与插入挂起。
final class InMemoryTranslationHistoryStore: TranslationHistoryStoring {
    var entries: [TranslationHistoryEntry] = []
    var loadError: Error?
    var insertError: Error?
    var deleteError: Error?
    var deleteAllError: Error?
    private(set) var insertCount = 0
    private(set) var deleteAllCount = 0

    func load(limit: Int) async throws -> [TranslationHistoryEntry] {
        if let loadError { throw loadError }
        return Array(entries.prefix(limit))
    }

    func insertAndPrune(_ entry: TranslationHistoryEntry, limit: Int) async throws {
        insertCount += 1
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
        deleteAllCount += 1
        if let deleteAllError { throw deleteAllError }
        entries.removeAll()
    }
}

/// 桩引擎：同步返回固定结果或固定错误，记录取消次数。
@MainActor
final class StubTranslationEngine: TranslationEngine {
    var result = TranslationResult(
        text: "译文",
        sourceLanguage: "en",
        targetLanguage: "zh-Hans",
        engine: .ai,
        model: "test-model"
    )
    var error: Error?
    private(set) var receivedRequests: [TranslationRequest] = []
    private(set) var cancelCount = 0

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        receivedRequests.append(request)
        if let error { throw error }
        return result
    }

    func cancel() {
        cancelCount += 1
    }
}

/// 桩语言解析器：默认返回固定方向。
struct StubTranslationResolver: TranslationLanguageResolving {
    var resolved = ResolvedTranslationLanguages(source: "en", target: "zh-Hans")
    var error: Error?

    func resolve(
        text: String,
        source: String?,
        target: TranslationTarget
    ) throws -> ResolvedTranslationLanguages {
        if let error { throw error }
        return resolved
    }
}

/// 桩取词器：返回固定 Result 并记录调用次数。
final class StubSelectedTextReader: SelectedTextReading {
    var result: Result<String, SelectedTextReadFailure> = .failure(.noSelection)
    private(set) var readCount = 0

    func readSelectedText() -> Result<String, SelectedTextReadFailure> {
        readCount += 1
        return result
    }
}

/// 记录 show/hide 的窗口展示桩。
@MainActor
final class RecordingTranslationWindowPresenter: TranslationWindowPresenting {
    var isKeyWindow = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var lastFocusInput: Bool?

    func show(focusInput: Bool) {
        showCount += 1
        lastFocusInput = focusInput
    }

    func hide() {
        hideCount += 1
    }
}

final class TranslationRecordingPasteboardWriter: PasteboardWriting {
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

// MARK: - 便捷构造

/// 独立 UserDefaults 套件（注册默认值后交给偏好）。
func makeTranslationTestDefaults(_ suiteName: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    Defaults.register(in: defaults)
    return defaults
}

@MainActor
func makeTranslationTestManager(
    preferences: TranslationPreferences,
    store: TranslationHistoryStoring,
    engine: TranslationEngine,
    resolver: TranslationLanguageResolving = StubTranslationResolver(),
    reader: SelectedTextReading = StubSelectedTextReader(),
    isFeatureAvailable: @escaping () -> Bool = { true }
) -> TranslationManager {
    TranslationManager(
        preferences: preferences,
        historyStore: store,
        resolver: resolver,
        reader: reader,
        pasteboard: TranslationRecordingPasteboardWriter(),
        isFeatureAvailable: isFeatureAvailable,
        engineFactory: { _ in engine }
    )
}
