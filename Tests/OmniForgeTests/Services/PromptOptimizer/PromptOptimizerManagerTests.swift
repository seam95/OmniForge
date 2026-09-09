import AppKit
import Carbon
import KeyboardShortcuts
import XCTest
@testable import OmniForge

// MARK: - 测试假件

private final class FakeSelectedTextReader: SelectedTextReading {
    var stubbedResult: Result<String, SelectedTextReadFailure> = .failure(.noSelection)
    func readSelectedText() -> Result<String, SelectedTextReadFailure> { stubbedResult }
}

private final class FakePromptOptimizingService: PromptOptimizing {
    var stubbedResult: String?
    var stubbedError: Error?
    private(set) var receivedInputs: [String] = []

    func optimize(selectedText: String) async throws -> String {
        receivedInputs.append(selectedText)
        if let stubbedError { throw stubbedError }
        return stubbedResult ?? ""
    }
}

private final class FakeSelectionCopier: SelectionCopying {
    var stubbedText: String?
    private(set) var callCount = 0

    func copySelectionAndRead() async -> String? {
        callCount += 1
        return stubbedText
    }
}

private final class FakePasteboardWriter: PasteboardWriting {
    private(set) var clearedCount = 0
    private(set) var writtenStrings: [String] = []

    func clearContents() { clearedCount += 1 }

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

private final class FakeKeyEventPoster: KeyEventPosting {
    private(set) var commandVCount = 0
    private(set) var commandCCount = 0
    func postCommandV() { commandVCount += 1 }
    func postCommandC() { commandCCount += 1 }
}

@MainActor
private final class FakePromptOptimizerHUD: PromptOptimizerHUDPresenting {
    struct Outcome: Equatable {
        var text: String
        var isFailure: Bool
    }

    private(set) var runningTexts: [String] = []
    private(set) var outcomes: [Outcome] = []

    func showRunning(_ text: String) {
        runningTexts.append(text)
    }

    func showOutcome(_ text: String, isFailure: Bool) {
        outcomes.append(Outcome(text: text, isFailure: isFailure))
    }
}

private final class FakeKeyboardShortcutsClient: PromptOptimizerKeyboardShortcutsClient {
    private(set) var appliedShortcuts: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut?] = [:]
    private(set) var registeredHandlerCount = 0
    private var handler: (() -> Void)?

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        appliedShortcuts[name] = shortcut
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        registeredHandlerCount += 1
        handler = action
    }

    /// 模拟用户按下快捷键。
    func fireKeyUp() { handler?() }
}

// MARK: - 测试

/// 编排状态机与各路径的 HUD/交付断言（全依赖注入，无真实 AX/网络/剪贴板）。
@MainActor
final class PromptOptimizerManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var reader: FakeSelectedTextReader!
    private var service: FakePromptOptimizingService!
    private var writer: FakePasteboardWriter!
    private var poster: FakeKeyEventPoster!
    private var hud: FakePromptOptimizerHUD!
    private var shortcuts: FakeKeyboardShortcutsClient!
    private var fallbackCopier: FakeSelectionCopier!
    private var serviceConfigured = true

    override func setUp() {
        super.setUp()
        suiteName = "PromptOptimizerManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Defaults.register(in: defaults)
        reader = FakeSelectedTextReader()
        service = FakePromptOptimizingService()
        writer = FakePasteboardWriter()
        poster = FakeKeyEventPoster()
        hud = FakePromptOptimizerHUD()
        shortcuts = FakeKeyboardShortcutsClient()
        fallbackCopier = FakeSelectionCopier()
        serviceConfigured = true
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager(
        isFeatureAvailable: @escaping () -> Bool = { true },
        isAccessibilityGranted: @escaping () -> Bool = { true }
    ) -> PromptOptimizerManager {
        PromptOptimizerManager(
            userDefaults: defaults,
            isFeatureAvailable: isFeatureAvailable,
            isAccessibilityGranted: isAccessibilityGranted,
            stringsProvider: { .zhHans },
            reader: reader,
            fallbackCopier: fallbackCopier,
            serviceFactory: { [weak self] in self?.serviceConfigured == true ? self?.service : nil },
            writer: writer,
            keyPoster: poster,
            hud: hud,
            keyboardShortcuts: shortcuts
        )
    }

    /// 触发并等待一次 runOnce 完成（handleHotkey 是异步 Task）。
    private func runOnce(_ manager: PromptOptimizerManager) async {
        manager.handleHotkey()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.phase, .idle, "runOnce 完成后必须回到 idle")
    }

    // MARK: - 生命周期

    func test_syncWithAvailability_startsAndStopsListening() {
        let manager = makeManager()

        manager.syncWithPreferences()
        XCTAssertTrue(manager.isListening)
        let applied = shortcuts.appliedShortcuts[.promptOptimizer].flatMap { $0 }
        XCTAssertEqual(applied?.carbonKeyCode, HotkeyDefinition.defaultPromptOptimizer.keyCode)
        XCTAssertEqual(shortcuts.registeredHandlerCount, 1, "handler 只注册一次")

        let disabled = makeManager(isFeatureAvailable: { false })
        disabled.syncWithPreferences()
        XCTAssertFalse(disabled.isListening)
        XCTAssertNil(shortcuts.appliedShortcuts[.promptOptimizer].flatMap { $0 }, "停用后快捷键镜像清空")
    }

    func test_shortcutHandlerWiredThroughClient() async {
        let manager = makeManager()
        manager.syncWithPreferences()
        reader.stubbedResult = .success("选中文本")
        service.stubbedResult = "优化结果"

        shortcuts.fireKeyUp()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(service.receivedInputs, ["选中文本"])
    }

    func test_handleRecorderChange_persistsAndApplies() {
        let manager = makeManager()
        manager.syncWithPreferences()

        manager.handleRecorderChange(
            KeyboardShortcuts.Shortcut(carbonKeyCode: Int(kVK_ANSI_O), carbonModifiers: HotkeyModifiers([.option, .command]).carbonModifiers)
        )

        XCTAssertEqual(manager.hotkey.keyCode, Int(kVK_ANSI_O))
        XCTAssertEqual(defaults.integer(forKey: UserDefaultsKeys.promptOptimizerHotkeyKeyCode), Int(kVK_ANSI_O))
        XCTAssertEqual(shortcuts.appliedShortcuts[.promptOptimizer].flatMap { $0 }?.carbonKeyCode, Int(kVK_ANSI_O))
    }

    // MARK: - 成功路径

    func test_success_writesClipboardShowsOutcomeWithoutPaste() async {
        reader.stubbedResult = .success("原始提示词")
        service.stubbedResult = "优化后的提示词"
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(service.receivedInputs, ["原始提示词"])
        XCTAssertEqual(writer.clearedCount, 1)
        XCTAssertEqual(writer.writtenStrings, ["优化后的提示词"])
        XCTAssertEqual(poster.commandVCount, 0, "autoReplace 默认关：不注入粘贴")
        XCTAssertEqual(hud.runningTexts, ["优化中…"])
        XCTAssertEqual(hud.outcomes, [.init(text: "已复制优化结果", isFailure: false)])
    }

    func test_success_withAutoReplaceInjectsPaste() async {
        defaults.set(true, forKey: UserDefaultsKeys.promptOptimizerAutoReplace)
        reader.stubbedResult = .success("原始")
        service.stubbedResult = "优化后"
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(poster.commandVCount, 1)
        XCTAssertEqual(writer.writtenStrings, ["优化后"])
    }

    // MARK: - 预检失败路径

    func test_notConfigured_showsErrorWithoutRequest() async {
        serviceConfigured = false
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertTrue(service.receivedInputs.isEmpty, "未配置不发请求")
        XCTAssertTrue(writer.writtenStrings.isEmpty)
        XCTAssertEqual(hud.outcomes, [.init(text: "未配置模型，请到设置中填写", isFailure: true)])
        XCTAssertTrue(hud.runningTexts.isEmpty, "预检失败不闪「优化中」")
    }

    func test_accessibilityDenied_showsDedicatedError() async {
        let manager = makeManager(isAccessibilityGranted: { false })
        reader.stubbedResult = .success("文本")

        await runOnce(manager)

        XCTAssertEqual(hud.outcomes, [.init(text: "辅助功能权限未生效，请重启应用或到系统设置检查授权", isFailure: true)])
        XCTAssertTrue(service.receivedInputs.isEmpty)
    }

    func test_accessibilityFalsePositiveFromReader_mapsToAccessibilityError() async {
        // trusted 检查通过但 AX 调用失败（授权未生效的假阳性）——同样归为权限文案。
        reader.stubbedResult = .failure(.accessibilityInactive)
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(hud.outcomes, [.init(text: "辅助功能权限未生效，请重启应用或到系统设置检查授权", isFailure: true)])
        XCTAssertTrue(service.receivedInputs.isEmpty)
        XCTAssertTrue(hud.runningTexts.isEmpty, "预检失败不闪「优化中」")
    }

    func test_noSelection_showsErrorWithoutRequest() async {
        reader.stubbedResult = .failure(.noSelection)
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(hud.outcomes, [.init(text: "无法获取选中文本", isFailure: true)])
        XCTAssertTrue(service.receivedInputs.isEmpty)
    }

    // MARK: - ⌘C 兜底

    func test_axFails_fallbackRecoversAndProceeds() async {
        reader.stubbedResult = .failure(.noSelection)
        fallbackCopier.stubbedText = "兜底取得的选中文本"
        service.stubbedResult = "优化结果"
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(fallbackCopier.callCount, 1, "AX 无选区后必须尝试兜底")
        XCTAssertEqual(service.receivedInputs, ["兜底取得的选中文本"])
        XCTAssertEqual(writer.writtenStrings, ["优化结果"])
        // 兜底与优化各亮一次「优化中」（HUD 同窗更新幂等），首条必须出现在兜底等待期间。
        XCTAssertGreaterThanOrEqual(hud.runningTexts.count, 1)
        XCTAssertEqual(hud.runningTexts.first, "优化中…")
        XCTAssertEqual(hud.outcomes, [.init(text: "已复制优化结果", isFailure: false)])
    }

    func test_axFails_fallbackAlsoFails_showsNoSelection() async {
        reader.stubbedResult = .failure(.noSelection)
        fallbackCopier.stubbedText = nil
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(fallbackCopier.callCount, 1)
        XCTAssertEqual(hud.outcomes, [.init(text: "无法获取选中文本", isFailure: true)])
        XCTAssertTrue(service.receivedInputs.isEmpty)
    }

    func test_axSucceeds_fallbackNotCalled() async {
        reader.stubbedResult = .success("AX 取到的文本")
        service.stubbedResult = "优化结果"
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(fallbackCopier.callCount, 0, "AX 成功时不得动剪贴板")
        XCTAssertEqual(service.receivedInputs, ["AX 取到的文本"])
    }

    // MARK: - 服务错误映射

    func test_serviceErrorKind_mapsToDedicatedText() async {
        reader.stubbedResult = .success("文本")
        service.stubbedError = PromptOptimizerErrorKind.timeout
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(hud.outcomes, [.init(text: "请求超时", isFailure: true)])
        XCTAssertTrue(writer.writtenStrings.isEmpty)
    }

    func test_unexpectedServiceError_fallsBackToGeneric() async {
        reader.stubbedResult = .success("文本")
        struct Surprise: Error {}
        service.stubbedError = Surprise()
        let manager = makeManager()

        await runOnce(manager)

        XCTAssertEqual(hud.outcomes, [.init(text: "优化失败", isFailure: true)])
    }

    // MARK: - 状态机

    func test_runningPhaseIgnoresRepeatedTriggers() async {
        reader.stubbedResult = .success("文本")
        // 用未完成的优化请求占住 running 态。
        let gate = PromptOptimizerTestGate()
        let slowService = SlowGateService(gate: gate)
        let serviceHolder = ServiceHolder(service: slowService)
        let manager = PromptOptimizerManager(
            userDefaults: defaults,
            stringsProvider: { .zhHans },
            reader: reader,
            serviceFactory: { serviceHolder.service },
            writer: writer,
            keyPoster: poster,
            hud: hud,
            keyboardShortcuts: shortcuts
        )

        manager.handleHotkey()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(manager.phase, .running)

        manager.handleHotkey() // running 期间重复触发
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(slowService.callCount, 1, "重复触发被忽略，不发起第二次请求")

        gate.open()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.phase, .idle)
    }

    func test_teardownStopsListeningAndResetsPhase() {
        let manager = makeManager()
        manager.syncWithPreferences()

        manager.teardown()

        XCTAssertFalse(manager.isListening)
        XCTAssertNil(shortcuts.appliedShortcuts[.promptOptimizer].flatMap { $0 })
        XCTAssertEqual(manager.phase, .idle)
    }
}

// MARK: - 慢服务工具（占住 running 态）

private final class ServiceHolder {
    let service: PromptOptimizing
    init(service: PromptOptimizing) { self.service = service }
}

private final class SlowGateService: PromptOptimizing {
    private let gate: PromptOptimizerTestGate
    private(set) var callCount = 0

    init(gate: PromptOptimizerTestGate) {
        self.gate = gate
    }

    func optimize(selectedText: String) async throws -> String {
        callCount += 1
        await gate.wait()
        return "结果"
    }
}

private final class PromptOptimizerTestGate: @unchecked Sendable {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let lock = NSLock()

    func open() {
        lock.lock()
        isOpen = true
        let toResume = waiters
        waiters = []
        lock.unlock()
        toResume.forEach { $0.resume() }
    }

    func wait() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
