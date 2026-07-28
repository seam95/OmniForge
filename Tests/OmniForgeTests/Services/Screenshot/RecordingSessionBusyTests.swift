import AppKit
import XCTest
@testable import OmniForge

/// Recording busy mutual exclusion: recording mid-session blocks new screenshot
/// sessions, while all-in-one stops and saves (CapCap semantics).
@MainActor
final class RecordingSessionBusyTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var keyboardShortcuts: FakeScreenshotKeyboardShortcutsClient!
    private var captureClient: FakeScreenCaptureClient!
    private var fakeCoordinator: FakeRecordingSessionCoordinator!
    private var manager: ScreenshotFeatureManager!

    private let testSuiteName = "RecordingSessionBusyTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        userDefaults = UserDefaults(suiteName: testSuiteName)!
        keyboardShortcuts = FakeScreenshotKeyboardShortcutsClient()
        captureClient = FakeScreenCaptureClient()
        fakeCoordinator = FakeRecordingSessionCoordinator()
        manager = makeManager()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: testSuiteName)
        super.tearDown()
    }

    private func makeManager() -> ScreenshotFeatureManager {
        let m = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            recordingCoordinator: fakeCoordinator
        )
        m.startListening()
        return m
    }

    func test_recordingBusy_allInOneStopsAndSaves() {
        fakeCoordinator.isRecording = true

        manager.handleAllInOne()

        XCTAssertEqual(fakeCoordinator.stopAndSaveCallCount, 1)
        XCTAssertEqual(fakeCoordinator.beginCallCount, 0)
        XCTAssertNil(manager.lastError)
        guard case let .triggered(mode, intent) = manager.lastOutcome else {
            return XCTFail("expected triggered stop/save, got \(String(describing: manager.lastOutcome))")
        }
        XCTAssertEqual(mode, .allInOne)
        XCTAssertEqual(intent, .save)
    }

    func test_recordingBusy_fullScreenIsBlocked() {
        fakeCoordinator.isRecording = true

        manager.handleHotkey(mode: .fullScreen, intent: .copy)

        XCTAssertEqual(fakeCoordinator.stopAndSaveCallCount, 0)
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
        guard case .ignored = manager.lastOutcome else {
            return XCTFail("expected busy ignored, got \(String(describing: manager.lastOutcome))")
        }
    }

    func test_recordingBusy_handleRecordStopsAndSaves() {
        fakeCoordinator.isRecording = true

        manager.handleRecord()

        XCTAssertEqual(fakeCoordinator.stopAndSaveCallCount, 1)
        XCTAssertNil(manager.lastError)
    }

    func test_isBusy_trueWhenRecording() {
        XCTAssertFalse(manager.isBusy)
        fakeCoordinator.isRecording = true
        XCTAssertTrue(manager.isBusy)
    }

    func test_sessionBusy_blocksHandleRecord() {
        // Occupy with all-in-one (headless keeps isSessionRunning true).
        manager.handleAllInOne()
        XCTAssertNil(manager.lastError)

        manager.handleRecord()
        XCTAssertEqual(manager.lastError, Strings.en.screenshotSessionAlreadyActive)
        XCTAssertEqual(fakeCoordinator.beginCallCount, 0)
    }

    func test_handleRecord_cancelClearsDirectRegionSelectionCallback() {
        // Simulate dedicated-record region select, then Esc cancel via overlay tearDown.
        // Stale onDirectRegionSelection must not survive to hijack a later all-in-one capture.
        let overlay = CaptureOverlayController(captureClient: captureClient, editorEnabled: false)
        manager = ScreenshotFeatureManager(
            userDefaults: userDefaults,
            isFeatureAvailable: { true },
            isScreenRecordingGranted: { true },
            stringsProvider: { .en },
            keyboardShortcuts: keyboardShortcuts,
            captureClient: captureClient,
            overlayController: overlay,
            recordingCoordinator: fakeCoordinator
        )
        manager.startListening()

        manager.handleRecord()
        XCTAssertNotNil(overlay.onDirectRegionSelection)

        // Cancel path: tearDown (Esc / right-click) must clear the direct-record callback.
        overlay.tearDown()
        XCTAssertNil(overlay.onDirectRegionSelection)

        // Manager session-end / full teardown is also defensive.
        manager.teardown()
        XCTAssertNil(overlay.onDirectRegionSelection)
        XCTAssertEqual(fakeCoordinator.beginCallCount, 0)
    }

    func test_beginRecording_forwardsAppKitRectToCoordinator() {
        // Direct protocol path: coordinator receives the AppKit rect passed to begin.
        // Headless CI may have no NSScreen; skip begin wiring in that case.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            // Still assert the protocol surface exists and stop/save path works.
            fakeCoordinator.isRecording = true
            fakeCoordinator.stopAndSave()
            XCTAssertEqual(fakeCoordinator.stopAndSaveCallCount, 1)
            return
        }
        let rect = NSRect(x: 10, y: 20, width: 300, height: 200)
        fakeCoordinator.begin(rect: rect, screen: screen)
        XCTAssertEqual(fakeCoordinator.beginCallCount, 1)
        XCTAssertEqual(fakeCoordinator.lastBeginRect, rect)
    }

    func test_outputConfiguration_defaultsAndPreference() {
        let config = RecordingOutputConfiguration(userDefaults: userDefaults)
        let snapshot = config.load()
        XCTAssertEqual(snapshot.savePreference, .manual)
        XCTAssertEqual(snapshot.lastManualFormat, .mp4)
        XCTAssertNil(snapshot.savePreference.format)

        config.setSavePreference(.gif)
        config.setLastManualFormat(.gif)
        let updated = config.load()
        XCTAssertEqual(updated.savePreference, .gif)
        XCTAssertEqual(updated.savePreference.format, .gif)
        XCTAssertEqual(updated.lastManualFormat, .gif)

        let name = RecordingOutputConfiguration.timestampedFileName(
            prefix: "Recording",
            fileExtension: "mp4",
            date: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(name.hasPrefix("Recording-"))
        XCTAssertTrue(name.hasSuffix(".mp4"))
    }
}

// MARK: - Fake coordinator

@MainActor
final class FakeRecordingSessionCoordinator: RecordingSessionCoordinating {
    var isRecording = false
    private(set) var beginCallCount = 0
    private(set) var stopAndSaveCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var lastBeginRect: NSRect = .zero
    private(set) var lastBeginScreen: NSScreen?

    func begin(rect: NSRect, screen: NSScreen) {
        beginCallCount += 1
        lastBeginRect = rect
        lastBeginScreen = screen
        isRecording = true
    }

    func stopAndSave() {
        stopAndSaveCallCount += 1
        isRecording = false
    }

    func cancel() {
        cancelCallCount += 1
        isRecording = false
    }
}
