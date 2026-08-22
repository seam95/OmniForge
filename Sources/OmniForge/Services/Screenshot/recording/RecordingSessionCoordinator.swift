import AppKit
import Foundation
import os.log

/// Testable surface for recording session lifecycle (busy mutex + hotkey stop).
@MainActor
protocol RecordingSessionCoordinating: AnyObject {
    var isRecording: Bool { get }
    func begin(rect: NSRect, screen: NSScreen)
    func stopAndSave()
    func cancel()
}

/// Owns Border/HUD UI + RecordingEngine + save/export flow.
/// Aligns with CapCap `AppDelegate` recording helpers; keeps chrome out of the capture stream.
@MainActor
final class RecordingSessionCoordinator: RecordingSessionCoordinating {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "RecordingSession")

    private let userDefaults: UserDefaults
    private let stringsProvider: () -> Strings
    private let engineFactory: () -> RecordingEngine
    private let fileManager: FileManager

    private var engine: RecordingEngine?
    private var borderPanel: RecordingBorderPanel?
    private var hudPanel: RecordingHUDPanel?
    private var recordingScreenRect: NSRect = .zero
    private var recordingScreen: NSScreen?
    private var cancelRequested = false
    private var cancelLocalMonitor: Any?
    private var cancelGlobalMonitor: Any?
    private var statusToast: EditorInfoToastWindow?

    /// Optional observation for tests / manager busy state.
    var onRecordingStateChanged: ((Bool) -> Void)?

    var isRecording: Bool { engine != nil }

    let suppressesWindowDisplay: Bool

    init(
        userDefaults: UserDefaults = .standard,
        stringsProvider: @escaping () -> Strings = { .en },
        engineFactory: @escaping () -> RecordingEngine = { RecordingEngine() },
        fileManager: FileManager = .default,
        suppressesWindowDisplay: Bool = (NSClassFromString("XCTestCase") != nil)
    ) {
        self.userDefaults = userDefaults
        self.stringsProvider = stringsProvider
        self.engineFactory = engineFactory
        self.fileManager = fileManager
        self.suppressesWindowDisplay = suppressesWindowDisplay
    }

    func begin(rect: NSRect, screen: NSScreen) {
        guard engine == nil else { return }
        guard rect.width > 0, rect.height > 0 else {
            presentStatus(stringsProvider().recordingFailedFormat.replacingOccurrences(
                of: "%@",
                with: RecordingEngine.RecordingError.invalidSelection.localizedDescription
            ), duration: 3.5)
            return
        }

        recordingScreenRect = rect
        recordingScreen = screen
        cancelRequested = false

        let strings = stringsProvider()
        let border = RecordingBorderPanel(screen: screen)
        border.setSelectionRect(rect)
        if !suppressesWindowDisplay {
            border.orderFrontRegardless()
        }
        borderPanel = border

        let hud = RecordingHUDPanel(
            stopToolTip: strings.recordingStop,
            pauseToolTip: strings.recordingPause,
            resumeToolTip: strings.recordingResume
        )
        hud.update(elapsedSeconds: 0)
        hud.positionOnScreen(relativeTo: rect, screen: screen)
        hud.onStopRecording = { [weak self] in
            self?.stopAndSave()
        }
        hud.onPauseRecording = { [weak self] in
            self?.engine?.pauseRecording()
        }
        hud.onResumeRecording = { [weak self] in
            self?.engine?.resumeRecording()
        }
        if !suppressesWindowDisplay {
            hud.orderFrontRegardless()
        }
        hudPanel = hud

        let recordingEngine = engineFactory()
        recordingEngine.onProgress = { [weak self] seconds in
            Task { @MainActor in
                self?.updateHUD(seconds: seconds)
            }
        }
        recordingEngine.onPauseChanged = { [weak self] paused in
            Task { @MainActor in
                self?.hudPanel?.setPaused(paused)
            }
        }
        recordingEngine.onCompletion = { [weak self] url, error in
            Task { @MainActor in
                self?.finishRecording(url: url, error: error)
            }
        }
        engine = recordingEngine
        installCancelMonitors()
        onRecordingStateChanged?(true)

        let excludedWindows = [
            borderPanel.map { CGWindowID($0.windowNumber) },
            hudPanel.map { CGWindowID($0.windowNumber) },
            statusToast.map { CGWindowID($0.windowNumber) },
        ].compactMap { $0 }
        recordingEngine.startRecording(rect: rect, screen: screen, excludeWindowNumbers: excludedWindows)
        Self.logger.info("Recording started rect=\(NSStringFromRect(rect), privacy: .public)")
    }

    func stopAndSave() {
        guard let engine else { return }
        engine.stopRecording()
    }

    func cancel() {
        guard let engine, !cancelRequested else { return }
        // Read state via synchronized query — never touch engine.state off recordingQueue.
        guard engine.isActive else { return }
        cancelRequested = true
        engine.cancelRecording()
    }

    // MARK: - Private

    private func updateHUD(seconds: Int) {
        hudPanel?.update(elapsedSeconds: seconds)
        if let screen = recordingScreen, hudPanel?.userHasDragged != true {
            hudPanel?.positionOnScreen(relativeTo: recordingScreenRect, screen: screen)
        }
    }

    private func finishRecording(url: URL?, error: Error?) {
        let wasCancelled = cancelRequested
        cancelRequested = false
        stopUI()

        if wasCancelled {
            if let url {
                try? fileManager.removeItem(at: url)
            }
            presentStatus(stringsProvider().recordingCancelled)
            return
        }

        if let error {
            presentStatus(
                String(format: stringsProvider().recordingFailedFormat, error.localizedDescription),
                duration: 3.5
            )
            return
        }

        guard let url else {
            presentStatus(
                String(
                    format: stringsProvider().recordingFailedFormat,
                    RecordingEngine.RecordingError.noFrames.localizedDescription
                ),
                duration: 3.5
            )
            return
        }

        promptToSave(tmpURL: url)
    }

    private func stopUI() {
        removeCancelMonitors()
        hudPanel?.close()
        hudPanel = nil
        borderPanel?.close()
        borderPanel = nil
        engine = nil
        recordingScreenRect = .zero
        recordingScreen = nil
        onRecordingStateChanged?(false)
    }

    private func installCancelMonitors() {
        removeCancelMonitors()
        cancelLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isPlainEscape(event) {
                self?.cancel()
                return nil
            }
            return event
        }
        cancelGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Self.isPlainEscape(event) {
                self?.cancel()
            }
        }
    }

    private func removeCancelMonitors() {
        if let cancelLocalMonitor {
            NSEvent.removeMonitor(cancelLocalMonitor)
            self.cancelLocalMonitor = nil
        }
        if let cancelGlobalMonitor {
            NSEvent.removeMonitor(cancelGlobalMonitor)
            self.cancelGlobalMonitor = nil
        }
    }

    private static func isPlainEscape(_ event: NSEvent) -> Bool {
        let activeModifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return event.keyCode == 53 && activeModifiers.isEmpty
    }

    private func promptToSave(tmpURL: URL) {
        let preference = RecordingOutputConfiguration(userDefaults: userDefaults).load().savePreference
        if let format = preference.format {
            saveToConfiguredDirectory(tmpURL: tmpURL, format: format)
            return
        }
        promptToChooseFormat(tmpURL: tmpURL)
    }

    private func promptToChooseFormat(tmpURL: URL) {
        let strings = stringsProvider()
        var selectedFormat = RecordingOutputConfiguration(userDefaults: userDefaults).load().lastManualFormat
        let alert = NSAlert()
        alert.messageText = strings.recordingFormatChoiceTitle
        alert.informativeText = strings.recordingFormatChoiceMessage
        alert.alertStyle = .informational
        alert.addButton(withTitle: strings.recordingSavePrompt)
        alert.addButton(withTitle: strings.recordingCancelPrompt)
        alert.accessoryView = RecordingSaveAccessoryView(
            initialFormat: selectedFormat,
            formatLabel: strings.recordingFormatLabel,
            formatTitles: (
                mp4: strings.recordingFormatMP4,
                gif: strings.recordingFormatGIF
            )
        ) { format in
            selectedFormat = format
        }

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            try? fileManager.removeItem(at: tmpURL)
            presentStatus(strings.recordingCancelled)
            return
        }

        RecordingOutputConfiguration(userDefaults: userDefaults).setLastManualFormat(selectedFormat)
        saveToConfiguredDirectory(tmpURL: tmpURL, format: selectedFormat)
    }

    private func saveToConfiguredDirectory(tmpURL: URL, format: ScreenRecordingFormat) {
        do {
            let config = RecordingOutputConfiguration(userDefaults: userDefaults).load()
            let directory = config.saveDirectory
                ?? URL(fileURLWithPath: (RecordingOutputConfiguration.defaultDirectoryPath as NSString).expandingTildeInPath,
                       isDirectory: true)
            try ensureDirectory(directory)
            let fileName = RecordingOutputConfiguration.timestampedFileName(
                prefix: config.fileNamePrefix,
                fileExtension: format.fileExtension,
                date: Date()
            )
            let destination = try uniqueFileURL(in: directory, fileName: fileName)
            saveRecording(tmpURL: tmpURL, destination: destination, format: format)
        } catch {
            try? fileManager.removeItem(at: tmpURL)
            presentStatus(
                String(format: stringsProvider().recordingFailedFormat, error.localizedDescription),
                duration: 3.5
            )
        }
    }

    private func saveRecording(tmpURL: URL, destination: URL, format: ScreenRecordingFormat) {
        switch format {
        case .mp4:
            do {
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: tmpURL, to: destination)
                presentStatus(String(format: stringsProvider().recordingSavedFormat, destination.deletingLastPathComponent().path))
            } catch {
                presentStatus(
                    String(format: stringsProvider().recordingFailedFormat, error.localizedDescription),
                    duration: 3.5
                )
            }
        case .gif:
            presentStatus(stringsProvider().recordingExportingGIF, duration: 600)
            RecordingExporter.exportGIF(from: tmpURL, to: destination) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.dismissStatusToast()
                    switch result {
                    case .success:
                        try? self.fileManager.removeItem(at: tmpURL)
                        self.presentStatus(
                            String(
                                format: self.stringsProvider().recordingSavedFormat,
                                destination.deletingLastPathComponent().path
                            )
                        )
                    case .failure(let error):
                        self.presentStatus(
                            String(format: self.stringsProvider().recordingFailedFormat, error.localizedDescription),
                            duration: 3.5
                        )
                        NSWorkspace.shared.activateFileViewerSelecting([tmpURL])
                    }
                }
            }
        }
    }

    private func ensureDirectory(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func uniqueFileURL(in directory: URL, fileName: String) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        if !fileManager.fileExists(atPath: url.path) {
            return url
        }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for index in 1..<10_000 {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func presentStatus(_ message: String, duration: TimeInterval = 2.0) {
        let toast = statusToast ?? EditorInfoToastWindow()
        statusToast = toast
        toast.present(message, near: recordingScreen ?? NSScreen.main, duration: duration)
    }

    private func dismissStatusToast() {
        statusToast?.dismiss()
        statusToast = nil
    }
}

// MARK: - Format accessory

private final class RecordingSaveAccessoryView: NSView {
    private static let labelTrailingInset: CGFloat = 170
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onFormatChanged: (ScreenRecordingFormat) -> Void

    init(
        initialFormat: ScreenRecordingFormat,
        formatLabel: String,
        formatTitles: (mp4: String, gif: String),
        onFormatChanged: @escaping (ScreenRecordingFormat) -> Void
    ) {
        self.onFormatChanged = onFormatChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 32))

        let label = NSTextField(labelWithString: formatLabel)
        label.translatesAutoresizingMaskIntoConstraints = false

        popup.translatesAutoresizingMaskIntoConstraints = false
        for format in ScreenRecordingFormat.allCases {
            let title: String
            switch format {
            case .mp4: title = formatTitles.mp4
            case .gif: title = formatTitles.gif
            }
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = format.rawValue
            if format == initialFormat {
                popup.select(popup.lastItem)
            }
        }
        popup.target = self
        popup.action = #selector(formatDidChange)

        addSubview(label)
        addSubview(popup)

        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: leadingAnchor, constant: Self.labelTrailingInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func formatDidChange() {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let format = ScreenRecordingFormat(rawValue: raw)
        else { return }
        onFormatChanged(format)
    }
}
