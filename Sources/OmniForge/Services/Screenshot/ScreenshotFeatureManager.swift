import AppKit
import Combine
import Foundation
import KeyboardShortcuts
import os.log

extension KeyboardShortcuts.Name {
    static let screenshotAllInOne = Self("screenshotAllInOne")
    static let screenshotCopy = Self("screenshotCopy")
    static let screenshotPin = Self("screenshotPin")
    static let screenshotFullscreen = Self("screenshotFullscreen")
    static let screenshotRecord = Self("screenshotRecord")
}

/// 截图快捷键入口：全能 / 复制 / 贴图 / 全屏 / 录屏。
/// `allCases` 顺序驱动设置页展示，必须为 allInOne → copy → pin → fullscreen → record。
enum ScreenshotHotkeyEntry: String, CaseIterable, Equatable, Sendable {
    case allInOne
    case copy
    case pin
    case fullscreen
    case record

    var keyboardShortcutsName: KeyboardShortcuts.Name {
        switch self {
        case .allInOne: return .screenshotAllInOne
        case .copy: return .screenshotCopy
        case .pin: return .screenshotPin
        case .fullscreen: return .screenshotFullscreen
        case .record: return .screenshotRecord
        }
    }

    var keyCodeDefaultsKey: String {
        switch self {
        case .allInOne: return UserDefaultsKeys.screenshotHotkeyAllInOneKeyCode
        case .copy: return UserDefaultsKeys.screenshotHotkeyCopyKeyCode
        case .pin: return UserDefaultsKeys.screenshotHotkeyPinKeyCode
        case .fullscreen: return UserDefaultsKeys.screenshotHotkeyFullscreenKeyCode
        case .record: return UserDefaultsKeys.screenshotHotkeyRecordKeyCode
        }
    }

    var modifiersDefaultsKey: String {
        switch self {
        case .allInOne: return UserDefaultsKeys.screenshotHotkeyAllInOneModifiers
        case .copy: return UserDefaultsKeys.screenshotHotkeyCopyModifiers
        case .pin: return UserDefaultsKeys.screenshotHotkeyPinModifiers
        case .fullscreen: return UserDefaultsKeys.screenshotHotkeyFullscreenModifiers
        case .record: return UserDefaultsKeys.screenshotHotkeyRecordModifiers
        }
    }

    var defaultDefinition: HotkeyDefinition {
        switch self {
        case .allInOne: return .defaultScreenshotAllInOne
        case .copy: return .defaultScreenshotCopy
        case .pin: return .defaultScreenshotPin
        case .fullscreen: return .defaultScreenshotFullscreen
        case .record: return .defaultScreenshotRecord
        }
    }

    func label(in strings: Strings) -> String {
        switch self {
        case .allInOne: return strings.screenshotHotkeyAllInOne
        case .copy: return strings.screenshotHotkeyCopy
        case .pin: return strings.screenshotHotkeyPin
        case .fullscreen: return strings.screenshotHotkeyFullscreen
        case .record: return strings.screenshotHotkeyRecord
        }
    }
}

/// Hotkey entry outcome.
enum ScreenshotHotkeyOutcome: Equatable {
    case triggered(mode: ScreenshotMode, intent: ScreenshotEntryIntent)
    case denied(String)
    case ignored(String)
}

/// KeyboardShortcuts write surface.
protocol ScreenshotKeyboardShortcutsClient: AnyObject {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
}

/// Production KeyboardShortcuts adapter.
final class LiveScreenshotKeyboardShortcutsClient: ScreenshotKeyboardShortcutsClient {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }

    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: name, action: action)
    }
}

/// Screenshot feature lifecycle and hotkey entry points.
/// Manages session lifecycle and recording busy mutual exclusion.
@MainActor
final class ScreenshotFeatureManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "Screenshot")

    private let userDefaults: UserDefaults
    private let isFeatureAvailable: () -> Bool
    private let isScreenRecordingGranted: () -> Bool
    private let stringsProvider: () -> Strings
    private let keyboardShortcuts: ScreenshotKeyboardShortcutsClient
    private let captureClient: ScreenCaptureClient
    private let overlayController: CaptureOverlayController
    private let recordingCoordinator: RecordingSessionCoordinating
    /// 统一结果出口；copy/pin 直出与编辑器共用。可后置注入（FeatureFactory）。
    private var resultPipeline: ScreenshotResultRunning?

    var pinnedScreenshotRegistry: PinnedScreenshotRegistry?
    var pinPipelineBridge: PinnedScreenshotPipelineBridge?

    @Published private(set) var isListening = false
    @Published private(set) var lastOutcome: ScreenshotHotkeyOutcome?
    @Published private(set) var lastError: String?
    @Published private(set) var lastMenuError: String?

    private var hotkeys: [ScreenshotHotkeyEntry: HotkeyDefinition] = [:]
    private var registeredEntries = Set<ScreenshotHotkeyEntry>()
    private var isSessionRunning = false
    /// Active capture session. Kept alive until completion so weak self closures remain valid.
    private var activeSession: ScreenshotCaptureSession?
    /// True while a copy/pin direct-out session is open and has not yet settled
    /// (pipeline success/failure via `finishDirectCapture`, or capture/cancel via session completion).
    private var awaitingDirectCaptureResult = false

    /// Busy when a screenshot session or recording session is active.
    var isBusy: Bool { isSessionRunning || recordingCoordinator.isRecording }

    init(
        userDefaults: UserDefaults = .standard,
        isFeatureAvailable: @escaping () -> Bool = { true },
        isScreenRecordingGranted: @escaping () -> Bool = { false },
        stringsProvider: @escaping () -> Strings = { .en },
        keyboardShortcuts: ScreenshotKeyboardShortcutsClient = LiveScreenshotKeyboardShortcutsClient(),
        captureClient: ScreenCaptureClient = ScreenCaptureKitClient(),
        overlayController: CaptureOverlayController? = nil,
        recordingCoordinator: RecordingSessionCoordinating? = nil,
        resultPipeline: ScreenshotResultRunning? = nil
    ) {
        self.userDefaults = userDefaults
        self.isFeatureAvailable = isFeatureAvailable
        self.isScreenRecordingGranted = isScreenRecordingGranted
        self.stringsProvider = stringsProvider
        self.keyboardShortcuts = keyboardShortcuts
        self.captureClient = captureClient
        self.overlayController = overlayController ?? CaptureOverlayController(captureClient: captureClient)
        self.recordingCoordinator = recordingCoordinator
            ?? RecordingSessionCoordinator(
                userDefaults: userDefaults,
                stringsProvider: stringsProvider
            )
        self.resultPipeline = resultPipeline
        wireRecordingSelection()
        reloadHotkeysFromDefaults()
    }

    /// 注入共享结果管线（FeatureFactory 在装配 pinBridge 后设置）。
    func setResultPipeline(_ pipeline: ScreenshotResultRunning?) {
        resultPipeline = pipeline
    }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        let enabled = userDefaults.object(forKey: UserDefaultsKeys.screenshotEnabled) != nil
            ? userDefaults.bool(forKey: UserDefaultsKeys.screenshotEnabled)
            : false
        if isFeatureAvailable(), enabled {
            startListening()
        } else {
            stopListening()
        }
    }

    func startListening() {
        isListening = true
        applyAllHotkeysToKeyboardShortcuts()
        for entry in ScreenshotHotkeyEntry.allCases {
            registerHandlerIfNeeded(for: entry)
        }
    }

    func stopListening() {
        isListening = false
        clearAllKeyboardShortcuts()
    }

    func teardown() {
        stopListening()
        if recordingCoordinator.isRecording {
            recordingCoordinator.cancel()
        }
        overlayController.tearDown()
        // Defensive: tearDown already clears these; keep manager session end explicit.
        overlayController.onDirectRegionSelection = nil
        overlayController.onDirectCaptureResult = nil
        overlayController.entryIntent = nil
        pinnedScreenshotRegistry?.closeAll()
        isSessionRunning = false
        activeSession = nil
        awaitingDirectCaptureResult = false
        lastOutcome = nil
        lastError = nil
        lastMenuError = nil
    }

    // MARK: - Entry points

    func handleAllInOne() {
        // CapCap: while recording, all-in-one hotkey stops and saves.
        if recordingCoordinator.isRecording {
            Self.logger.info("[SSDBG] handleAllInOne: recording active -> stopAndSave")
            recordingCoordinator.stopAndSave()
            lastOutcome = .triggered(mode: .allInOne, intent: .save)
            lastError = nil
            return
        }
        guard preflightCheck() else {
            Self.logger.notice("[SSDBG] handleAllInOne: preflightCheck failed")
            return
        }
        guard !isSessionRunning else {
            Self.logger.notice("[SSDBG] handleAllInOne: blocked (isSessionRunning=true)")
            recordBusyError()
            return
        }

        Self.logger.info("[SSDBG] handleAllInOne: start session, isSessionRunning=true")
        isSessionRunning = true
        // Defensive: all-in-one is editor path; never leave copy/pin direct-out callbacks armed.
        overlayController.onDirectCaptureResult = nil
        overlayController.entryIntent = nil
        awaitingDirectCaptureResult = false
        let session = AllInOneCaptureSession(
            captureClient: captureClient,
            overlayController: overlayController
        ) { [weak self] _ in
            guard let self else { return }
            // Editor finished inside overlay; only reset session state here.
            // Record-from-editor also completes with nil, then coordinator owns busy.
            Self.logger.info("[SSDBG] handleAllInOne completion: isSessionRunning=false")
            self.isSessionRunning = false
            self.activeSession = nil
        }
        activeSession = session
        session.start()
    }

    func handleHotkey(mode: ScreenshotMode, intent: ScreenshotEntryIntent) {
        if recordingCoordinator.isRecording {
            // While recording: all-in-one stops+saves; other modes report busy.
            if mode == .allInOne {
                handleAllInOne()
                return
            }
            Self.logger.notice("[SSDBG] handleHotkey(\(mode.rawValue)): recording busy")
            recordBusyError()
            return
        }
        guard preflightCheck() else {
            Self.logger.notice("[SSDBG] handleHotkey(\(mode.rawValue)): preflightCheck failed")
            return
        }
        guard !isSessionRunning else {
            Self.logger.notice("[SSDBG] handleHotkey(\(mode.rawValue)): blocked (isSessionRunning=true)")
            recordBusyError()
            return
        }

        switch mode {
        case .allInOne:
            handleAllInOne()
        case .fullScreen:
            Self.logger.info("[SSDBG] handleHotkey(fullScreen): start session, isSessionRunning=true")
            isSessionRunning = true
            let session = FullscreenCaptureSession(
                captureClient: captureClient,
                overlayController: overlayController
            ) { [weak self] _ in
                guard let self else { return }
                Self.logger.info("[SSDBG] handleHotkey(fullScreen) completion: isSessionRunning=false")
                self.isSessionRunning = false
                self.activeSession = nil
            }
            activeSession = session
            session.start()
        }
    }

    /// Dedicated record entry: region select then begin recording (no editor).
    func handleRecord() {
        if recordingCoordinator.isRecording {
            Self.logger.info("[SSDBG] handleRecord: recording active -> stopAndSave")
            recordingCoordinator.stopAndSave()
            lastError = nil
            return
        }
        guard preflightCheck() else {
            Self.logger.notice("[SSDBG] handleRecord: preflightCheck failed")
            return
        }
        guard !isSessionRunning else {
            Self.logger.notice("[SSDBG] handleRecord: blocked (isSessionRunning=true)")
            recordBusyError()
            return
        }

        Self.logger.info("[SSDBG] handleRecord: start region selection session")
        isSessionRunning = true
        // 与 copy/pin 直出互斥：录屏只走 rect-only 回调。
        overlayController.entryIntent = nil
        overlayController.onDirectCaptureResult = nil
        overlayController.onDirectRegionSelection = { [weak self] screenRect, screen in
            self?.beginRecording(rect: screenRect, screen: screen)
        }
        overlayController.startCapture(screenSnapshots: [:]) { [weak self] _ in
            guard let self else { return }
            Self.logger.info("[SSDBG] handleRecord selection completion: isSessionRunning=false")
            // Defensive: cancel/tearDown also nils this; clear again when session ends.
            self.overlayController.onDirectRegionSelection = nil
            self.isSessionRunning = false
            // If recording started, busy continues via recordingCoordinator.isRecording.
        }
    }

    // MARK: - Preflight / busy

    private func preflightCheck() -> Bool {
        guard isListening else {
            let reason = stringsProvider().screenshotHotkeyIgnoredNotListening
            lastError = reason
            lastOutcome = .ignored(reason)
            return false
        }
        guard isFeatureAvailable() else {
            let reason = stringsProvider().screenshotHotkeyIgnoredUnavailable
            lastError = reason
            lastOutcome = .ignored(reason)
            return false
        }
        guard isScreenRecordingGranted() else {
            let reason = stringsProvider().screenshotPermissionDenied
            lastError = reason
            lastOutcome = .denied(reason)
            return false
        }
        return true
    }

    private func recordBusyError() {
        let reason = stringsProvider().screenshotSessionAlreadyActive
        lastError = reason
        lastOutcome = .ignored(reason)
    }

    private func wireRecordingSelection() {
        overlayController.onRecordingSelection = { [weak self] rect, screen in
            self?.beginRecording(rect: rect, screen: screen)
        }
    }

    private func beginRecording(rect: NSRect, screen: NSScreen) {
        // Overlay/editor must be torn down before recording so chrome is not captured.
        recordingCoordinator.begin(rect: rect, screen: screen)
    }

    // MARK: - Hotkeys

    func hotkey(for entry: ScreenshotHotkeyEntry) -> HotkeyDefinition {
        hotkeys[entry] ?? entry.defaultDefinition
    }

    func handleRecorderChange(_ entry: ScreenshotHotkeyEntry, shortcut: KeyboardShortcuts.Shortcut?) {
        guard let definition = HotkeyDefinition(shortcut: shortcut) else {
            if isListening {
                applyHotkey(hotkey(for: entry), to: entry)
            }
            return
        }
        setHotkey(definition, for: entry)
    }

    func recordMenuError(_ message: String) {
        lastMenuError = message
        lastError = message
    }

    // MARK: - Internals

    private func setHotkey(_ definition: HotkeyDefinition, for entry: ScreenshotHotkeyEntry) {
        hotkeys[entry] = definition
        userDefaults.set(definition.keyCode, forKey: entry.keyCodeDefaultsKey)
        userDefaults.set(definition.modifiers.rawValue, forKey: entry.modifiersDefaultsKey)
        if isListening {
            applyHotkey(definition, to: entry)
        }
    }

    private func reloadHotkeysFromDefaults() {
        var loaded: [ScreenshotHotkeyEntry: HotkeyDefinition] = [:]
        for entry in ScreenshotHotkeyEntry.allCases {
            loaded[entry] = Self.loadHotkey(for: entry, from: userDefaults)
        }
        hotkeys = loaded
    }

    private func applyAllHotkeysToKeyboardShortcuts() {
        for entry in ScreenshotHotkeyEntry.allCases {
            applyHotkey(hotkey(for: entry), to: entry)
        }
    }

    private func clearAllKeyboardShortcuts() {
        for entry in ScreenshotHotkeyEntry.allCases {
            keyboardShortcuts.setShortcut(nil, for: entry.keyboardShortcutsName)
        }
    }

    private func applyHotkey(_ definition: HotkeyDefinition, to entry: ScreenshotHotkeyEntry) {
        keyboardShortcuts.setShortcut(definition.keyboardShortcut, for: entry.keyboardShortcutsName)
    }

    private func registerHandlerIfNeeded(for entry: ScreenshotHotkeyEntry) {
        guard !registeredEntries.contains(entry) else { return }
        keyboardShortcuts.onKeyDown(for: entry.keyboardShortcutsName) { [weak self] in
            if Thread.isMainThread {
                guard let self, self.isListening else { return }
                self.invokeHotkeyEntry(entry)
            } else {
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    self.invokeHotkeyEntry(entry)
                }
            }
        }
        registeredEntries.insert(entry)
    }

    private func invokeHotkeyEntry(_ entry: ScreenshotHotkeyEntry) {
        switch entry {
        case .allInOne:
            handleAllInOne()
        case .copy:
            handleCopy()
        case .pin:
            handlePin()
        case .fullscreen:
            handleHotkey(mode: .fullScreen, intent: .copy)
        case .record:
            handleRecord()
        }
    }

    /// 截图并复制：全能选区 → 确认一次 → pipeline.copy，不进编辑器。
    func handleCopy() {
        startDirectCapture(intent: .copy)
    }

    /// 截图并贴图：全能选区 → 确认一次 → pipeline.pin（原位钉），不进编辑器。
    func handlePin() {
        startDirectCapture(intent: .pin)
    }

    /// copy/pin 共用入口：preflight + busy 互斥后启动带 entryIntent 的全能选区会话。
    /// 录屏进行中仅拒绝（不 stopAndSave）；与 `handleAllInOne` / `handleRecord` 语义不同。
    private func startDirectCapture(intent: ScreenshotEntryIntent) {
        // copy/pin 不承担 stopAndSave：录屏中一律 busy。
        if recordingCoordinator.isRecording {
            Self.logger.notice("[SSDBG] startDirectCapture(\(intent.rawValue)): recording busy")
            recordBusyError()
            return
        }
        guard preflightCheck() else {
            Self.logger.notice("[SSDBG] startDirectCapture(\(intent.rawValue)): preflightCheck failed")
            return
        }
        guard !isSessionRunning else {
            Self.logger.notice("[SSDBG] startDirectCapture(\(intent.rawValue)): blocked (isSessionRunning=true)")
            recordBusyError()
            return
        }

        Self.logger.info("[SSDBG] startDirectCapture(\(intent.rawValue)): start session")
        isSessionRunning = true
        // Do not mark `.triggered` until pipeline succeeds — crop/capture/cancel must not look like success.
        awaitingDirectCaptureResult = true

        // 独立直出回调，严禁复用 onDirectRegionSelection（rect-only 录屏语义）。
        overlayController.onDirectRegionSelection = nil
        overlayController.onDirectCaptureResult = { [weak self] result, captureIntent, pinOrigin in
            self?.finishDirectCapture(result: result, intent: captureIntent, pinOrigin: pinOrigin)
        }

        let session = AllInOneCaptureSession(
            captureClient: captureClient,
            overlayController: overlayController,
            entryIntent: intent
        ) { [weak self] _ in
            guard let self else { return }
            Self.logger.info("[SSDBG] startDirectCapture(\(intent.rawValue)) completion: isSessionRunning=false")
            // Capture-path failure / cancel: overlay ends with onComplete(nil) and never calls
            // onDirectCaptureResult. Record non-success before clearing session flags.
            if self.awaitingDirectCaptureResult {
                self.recordDirectCaptureFailure()
            }
            self.awaitingDirectCaptureResult = false
            self.isSessionRunning = false
            self.activeSession = nil
            // 防御清空直出状态（overlay.tearDown 已清；manager 侧再清一次）。
            self.overlayController.onDirectCaptureResult = nil
            self.overlayController.entryIntent = nil
        }
        activeSession = session
        session.start()
    }

    /// 选区直出完成后执行 pipeline，更新 lastOutcome / lastError。
    /// Must run before session `onComplete` so `awaitingDirectCaptureResult` is settled first.
    private func finishDirectCapture(
        result: ScreenshotResult,
        intent: ScreenshotEntryIntent,
        pinOrigin: NSPoint?
    ) {
        awaitingDirectCaptureResult = false
        do {
            let pipeline = resolvedResultPipeline()
            // pin 用选区左下原点；copy 忽略 pinOrigin。
            let origin: NSPoint? = (intent == .pin) ? pinOrigin : nil
            _ = try pipeline.run(result: result, intent: intent, pinOrigin: origin)
            lastOutcome = .triggered(mode: .allInOne, intent: intent)
            lastError = nil
            Self.logger.info("[SSDBG] finishDirectCapture: pipeline \(intent.rawValue) ok")
        } catch {
            let message = error.localizedDescription
            lastError = message
            lastOutcome = .ignored(message)
            Self.logger.notice("[SSDBG] finishDirectCapture: pipeline 失败 \(message)")
        }
    }

    /// Crop / captureRegion / buildResult / cancel ended without a successful direct-out result.
    private func recordDirectCaptureFailure() {
        let detail = "capture ended without result"
        let message = String(
            format: stringsProvider().screenshotCaptureFailedFormat,
            detail
        )
        lastError = message
        lastOutcome = .ignored(message)
        Self.logger.notice("[SSDBG] recordDirectCaptureFailure: \(message)")
    }

    private func resolvedResultPipeline() -> ScreenshotResultRunning {
        if let resultPipeline { return resultPipeline }
        return ScreenshotResultPipeline(userDefaults: userDefaults)
    }

    private static func loadHotkey(
        for entry: ScreenshotHotkeyEntry,
        from userDefaults: UserDefaults
    ) -> HotkeyDefinition {
        guard userDefaults.object(forKey: entry.keyCodeDefaultsKey) != nil,
              userDefaults.object(forKey: entry.modifiersDefaultsKey) != nil else {
            return entry.defaultDefinition
        }
        let keyCode = userDefaults.integer(forKey: entry.keyCodeDefaultsKey)
        let modifiersRaw = userDefaults.integer(forKey: entry.modifiersDefaultsKey)
        return HotkeyDefinition(keyCode: keyCode, modifiers: HotkeyModifiers(rawValue: modifiersRaw))
    }
}
