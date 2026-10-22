import AppKit
import Combine
import Foundation

/// 单会话翻译编排：入口动作 → 语言解析 → 引擎请求 → 结果展示 → 历史保存。
///
/// 设计约束（SPEC §4/§7）：
/// - 进程内只有一个会话；任何新请求先取消旧任务，迟到响应按 request id 丢弃。
/// - 历史写入跟随提交成功的结果，且可取消：取消检查覆盖写事务入口。
/// - 视图只调用本类方法，不直接发网络请求或访问数据库。
@MainActor
final class TranslationManager: ObservableObject {
    /// 运行状态。
    enum Phase: Equatable {
        case idle
        case translating
        case failed(TranslationError)
    }

    /// 入口取词提示：与「失败」区分，避免把权限问题显示成翻译错误。
    enum Notice: Equatable {
        /// 辅助功能权限未授予或未生效；仍允许手动输入。
        case accessibilityRequired
        /// 目标应用没有可读选区。
        case noSelection
    }

    // MARK: - 依赖

    let preferences: TranslationPreferences
    private let historyStore: TranslationHistoryStoring
    private let resolver: TranslationLanguageResolving
    /// 每次提交按当前引擎与配置构造实例；系统引擎返回浮窗共享的 bridge。
    private let engineFactory: (TranslationEngineID) throws -> any TranslationEngine
    private let reader: SelectedTextReading
    private let pasteboard: PasteboardWriting
    private let isFeatureAvailable: () -> Bool
    private let historyLimit: Int
    private let now: () -> Date

    /// 快捷键管理器；由 factory 装配后注入，避免 manager 反向构造。
    weak var hotkeyManager: TranslationHotkeyManager?
    /// 浮窗展示；由窗口 controller 注入，弱引用避免循环。
    weak var windowPresenter: TranslationWindowPresenting?
    /// 动态窗口外观；由 composition root 注入。
    weak var appearance: AppearanceSettings?

    // MARK: - 会话状态

    /// 原文。视图可直接编辑；编辑会取消进行中的请求并标记旧译文失效。
    @Published var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue else { return }
            handleSourceTextEdited()
        }
    }

    @Published private(set) var result: TranslationResult?
    /// 原文或设置变化后旧译文失效：仍可查看，但禁用复制。
    @Published private(set) var isResultStale = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var history: [TranslationHistoryEntry] = []
    /// 历史持久化失败提示（读取或写入）；不把翻译成功等同于历史保存成功。
    @Published private(set) var historyError: TranslationError?
    @Published private(set) var notice: Notice?
    /// 最近一次复制是否成功，用于「已复制」反馈。
    @Published private(set) var didCopyResult = false

    private var activeEngine: (any TranslationEngine)?
    private var activeRequestID: UUID?
    private var translationTask: Task<Void, Never>?
    /// 程序化改写原文（新会话 / 打开历史）时抑制编辑失效逻辑。
    private var isSuppressingTextEdit = false

    init(
        preferences: TranslationPreferences,
        historyStore: TranslationHistoryStoring,
        resolver: TranslationLanguageResolving,
        reader: SelectedTextReading = AXSelectedTextReader(),
        pasteboard: PasteboardWriting = SystemPasteboardWriter(),
        isFeatureAvailable: @escaping () -> Bool = { true },
        historyLimit: Int = TranslationPreferences.defaultHistoryLimit,
        now: @escaping () -> Date = Date.init,
        engineFactory: @escaping (TranslationEngineID) throws -> any TranslationEngine
    ) {
        self.preferences = preferences
        self.historyStore = historyStore
        self.resolver = resolver
        self.reader = reader
        self.pasteboard = pasteboard
        self.isFeatureAvailable = isFeatureAvailable
        self.historyLimit = historyLimit
        self.now = now
        self.engineFactory = engineFactory
    }

    // MARK: - 派生状态

    var isTranslating: Bool {
        if case .translating = phase { return true }
        return false
    }

    /// 复制按钮可用条件：有译文、未失效，且不在翻译中。
    var canCopyResult: Bool {
        result != nil && !isResultStale && !isTranslating
    }

    /// 当前展示的引擎（macOS 14 上存储 system 会解析为 AI）。
    var displayedEngine: TranslationEngineID {
        preferences.effectiveEngine()
    }

    /// 需要提示用户「系统偏好已降级为 AI」。
    var needsAIConfigurationHint: Bool {
        displayedEngine == .ai && !preferences.isAIConfigured
    }

    // MARK: - 生命周期

    /// install 后调用：读取历史并按当前偏好同步快捷键；不打开浮窗。
    func bootstrap() {
        Task { [weak self] in
            await self?.reloadHistory()
        }
        syncWithPreferences()
    }

    /// availability 即启用：可用时注册快捷键，关闭时注销并取消请求。
    func syncWithPreferences() {
        guard isFeatureAvailable() else {
            teardown()
            return
        }
        hotkeyManager?.syncWithPreferences()
    }

    /// 卸载 / 退出：停止快捷键与请求、隐藏窗口；不删除历史与偏好。
    func teardown() {
        hotkeyManager?.stop()
        cancel()
        windowPresenter?.hide()
    }

    // MARK: - 入口动作

    /// 新建空白会话（管理页「新建翻译」或快捷键后无可用选区）。不读取选区。
    func newSession() {
        cancel()
        isSuppressingTextEdit = true
        sourceText = ""
        isSuppressingTextEdit = false
        resetSessionState()
        windowPresenter?.show(focusInput: true)
    }

    /// 查看历史记录：展示已保存的完整内容，不重新翻译、不改写当前引擎偏好。
    func openHistory(_ entry: TranslationHistoryEntry) {
        cancel()
        isSuppressingTextEdit = true
        sourceText = entry.request.text
        isSuppressingTextEdit = false
        result = entry.result
        isResultStale = false
        phase = .idle
        notice = nil
        historyError = nil
        didCopyResult = false
        windowPresenter?.show(focusInput: false)
    }

    /// 全局快捷键触发。
    ///
    /// 顺序要求（SPEC §3.2）：先读取原前台应用选区，再前置浮窗；
    /// 浮窗已是键盘焦点时不读取自己的选区。
    func handleHotkeyTrigger() {
        guard isFeatureAvailable() else { return }
        if windowPresenter?.isKeyWindow == true {
            // 已在浮窗内：只前置，不把浮窗自己的选区当作外部新任务。
            windowPresenter?.show(focusInput: true)
            return
        }

        let selection = reader.readSelectedText()
        // 前置必须发生在取词之后；此处先完成读取再 show。
        windowPresenter?.show(focusInput: true)

        switch selection {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                notice = .noSelection
                return
            }
            cancel()
            isSuppressingTextEdit = true
            sourceText = text
            isSuppressingTextEdit = false
            result = nil
            isResultStale = false
            didCopyResult = false
            notice = nil
            historyError = nil
            submit()
        case .failure(.noSelection):
            // 无可读选区：保留原有会话或草稿，不清空。
            notice = .noSelection
        case .failure(.accessibilityInactive):
            // 权限未生效：仍打开输入框，并显示授权入口。
            notice = .accessibilityRequired
        }
    }

    /// 隐藏浮窗：取消进行中的翻译，保留本次会话供下次查看。
    func hide() {
        cancel()
        windowPresenter?.hide()
    }

    // MARK: - 编辑与设置

    func updateText(_ text: String) {
        sourceText = text
    }

    func selectSourceLanguage(_ language: String?) {
        guard preferences.sourceLanguage != language else { return }
        cancel()
        preferences.sourceLanguage = language
        invalidateResultForSettingsChange()
    }

    func selectTarget(_ target: TranslationTarget) {
        guard preferences.target != target else { return }
        cancel()
        preferences.target = target
        invalidateResultForSettingsChange()
    }

    func selectEngine(_ engine: TranslationEngineID) {
        guard preferences.engine != engine else { return }
        cancel()
        preferences.engine = engine
        invalidateResultForSettingsChange()
    }

    /// 交换源与目标语言；只在源语言明确时可用，交换后不自动提交。
    func swapLanguages() {
        guard let source = preferences.sourceLanguage else { return }
        let targetCode: String
        switch preferences.target {
        case .automatic:
            targetCode = TranslationLanguage.isSimplifiedChinese(source)
                ? TranslationLanguage.english
                : TranslationLanguage.simplifiedChinese
        case .language(let code):
            targetCode = code
        }
        cancel()
        preferences.sourceLanguage = targetCode
        preferences.target = .language(source)
        invalidateResultForSettingsChange()
    }

    // MARK: - 提交

    func submit() {
        cancel()
        notice = nil
        historyError = nil

        let text = sourceText
        let resolution: ResolvedTranslationLanguages
        do {
            resolution = try resolver.resolve(
                text: text,
                source: preferences.sourceLanguage,
                target: preferences.target
            )
        } catch let error as TranslationError {
            phase = .failed(error)
            return
        } catch {
            phase = .failed(.invalidResponse)
            return
        }

        let engineID = preferences.effectiveEngine()
        // macOS 14 上系统偏好降级为 AI：未配置时明确提示，不静默发送请求。
        if engineID == .ai && !preferences.isAIConfigured {
            phase = .failed(.configurationIncomplete)
            return
        }

        let engine: any TranslationEngine
        do {
            engine = try engineFactory(engineID)
        } catch let error as TranslationError {
            phase = .failed(error)
            return
        } catch {
            phase = .failed(.configurationIncomplete)
            return
        }

        let request = TranslationRequest(
            text: text,
            sourceLanguage: resolution.source,
            targetLanguage: resolution.target
        )
        activeEngine = engine
        activeRequestID = request.id
        if result != nil {
            isResultStale = true
        }
        didCopyResult = false
        phase = .translating

        translationTask = Task { [weak self] in
            await self?.performTranslation(request: request, engine: engine)
        }
    }

    /// 取消当前翻译；迟到响应不得更新界面或写入历史。
    func cancel() {
        translationTask?.cancel()
        translationTask = nil
        activeEngine?.cancel()
        activeEngine = nil
        activeRequestID = nil
        if isTranslating {
            phase = .idle
        }
    }

    // MARK: - 复制

    func copyResult() {
        guard canCopyResult, let result else { return }
        pasteboard.clearContents()
        didCopyResult = pasteboard.setString(result.text, forType: .string)
    }

    // MARK: - 历史

    /// 读取历史（启动与写入后调用）。
    func reloadHistory() async {
        do {
            history = try await historyStore.load(limit: historyLimit)
        } catch {
            historyError = .historyWriteFailed
        }
    }

    /// 单条删除：只删除历史数据，不清除当前会话、不取消其他请求。
    func deleteHistory(id: UUID) async {
        do {
            try await historyStore.delete(id: id)
            history.removeAll { $0.id == id }
        } catch {
            historyError = .historyWriteFailed
        }
    }

    /// 清空历史：同样不影响当前会话。
    func clearHistory() async {
        do {
            try await historyStore.deleteAll()
            history.removeAll()
            historyError = nil
        } catch {
            historyError = .historyWriteFailed
        }
    }

    // MARK: - 私有：翻译执行

    private func performTranslation(
        request: TranslationRequest,
        engine: any TranslationEngine
    ) async {
        do {
            let translationResult = try await engine.translate(request)
            try Task.checkCancellation()
            // 迟到响应：只有仍是当前请求才允许更新界面。
            guard activeRequestID == request.id else { return }

            result = translationResult
            isResultStale = false
            phase = .idle
            activeEngine = nil
            activeRequestID = nil
            didCopyResult = false

            // 保存开关以「完成时」偏好为准。
            guard preferences.saveHistory else { return }
            try Task.checkCancellation()
            let entry = TranslationHistoryEntry(
                request: request,
                result: translationResult,
                completedAt: now()
            )
            do {
                // 存储实现内部会在写事务入口与提交前检查取消。
                try await historyStore.insertAndPrune(entry, limit: historyLimit)
                try Task.checkCancellation()
                await reloadHistory()
            } catch is CancellationError {
                // 取消不提示；事务已回滚。
            } catch {
                // 落库失败：译文仍可复制，单独提示「译文未保存」。
                historyError = .historyWriteFailed
            }
        } catch is CancellationError {
            // 取消由新任务 / 隐藏 / 卸载触发，不显示成错误。
        } catch let error as TranslationError {
            guard !Task.isCancelled, activeRequestID == request.id else { return }
            phase = .failed(error)
        } catch {
            guard !Task.isCancelled, activeRequestID == request.id else { return }
            phase = .failed(.invalidResponse)
        }
    }

    // MARK: - 私有：状态失效

    private func handleSourceTextEdited() {
        guard !isSuppressingTextEdit else { return }
        cancel()
        invalidateResultForSettingsChange()
    }

    /// 原文或设置变更：旧译文保留但标记失效，复制禁用，直到下次成功。
    private func invalidateResultForSettingsChange() {
        if result != nil {
            isResultStale = true
        }
        didCopyResult = false
        notice = nil
        if case .failed = phase {
            phase = .idle
        }
    }

    private func resetSessionState() {
        result = nil
        isResultStale = false
        phase = .idle
        notice = nil
        historyError = nil
        didCopyResult = false
    }
}
