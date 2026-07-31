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
        recordingCoordinator: RecordingSessionCoordinating? = nil
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
        wireRecordingSelection()
        reloadHotkeysFromDefaults()
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
        // Defensive: tearDown already clears this; keep manager session end explicit.
        overlayController.onDirectRegionSelection = nil
        pinnedScreenshotRegistry?.closeAll()
        isSessionRunning = false
        activeSession = nil
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
            // Task 4：选区确认后直出复制；本期仅完成注册/分发桩
            handleCopy()
        case .pin:
            // Task 4：选区确认后直出贴图；本期仅完成注册/分发桩
            handlePin()
        case .fullscreen:
            handleHotkey(mode: .fullScreen, intent: .copy)
        case .record:
            handleRecord()
        }
    }

    /// 截图并复制入口（Task 4 实现选区直出；Task 3 仅占位，不启动捕获）。
    func handleCopy() {
        // TODO(Task 4): preflight + busy + 全能选区 + pipeline.copy
    }

    /// 截图并贴图入口（Task 4 实现选区直出；Task 3 仅占位，不启动捕获）。
    func handlePin() {
        // TODO(Task 4): preflight + busy + 全能选区 + pipeline.pin
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
