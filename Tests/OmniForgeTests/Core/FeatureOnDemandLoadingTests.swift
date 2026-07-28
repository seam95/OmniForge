import XCTest
@testable import OmniForge

@MainActor
final class FeatureOnDemandLoadingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
        UserDefaults.standard.set(true, forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        FeatureRuntime.shared.resetForTesting()
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.clipboardFeatureEnabled)
        super.tearDown()
    }

    func test_compose_skipsUnavailableHeavyFeatures() {
        UserDefaults.standard.set(false, forKey: AppFeature.clipboardHistory.availabilityKey)
        UserDefaults.standard.set(false, forKey: AppFeature.systemMonitor.availabilityKey)
        UserDefaults.standard.set(false, forKey: AppFeature.shelf.availabilityKey)
        UserDefaults.standard.set(false, forKey: AppFeature.quickPhrase.availabilityKey)

        let root = AppCompositionRoot.compose()

        XCTAssertNil(FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self))
        XCTAssertNil(FeatureRuntime.shared.manager(for: .systemMonitor, as: SystemMonitorManager.self))
        XCTAssertNil(FeatureRuntime.shared.manager(for: .shelf, as: ShelfService.self))
        XCTAssertNil(FeatureRuntime.shared.manager(for: .quickPhrase, as: QuickPhraseManager.self))
        XCTAssertNotNil(FeatureRuntime.shared.manager(for: .inputLock, as: LockStateManager.self))
        _ = root
    }

    func test_setAvailableTrue_installsClipboardManager() {
        UserDefaults.standard.set(false, forKey: AppFeature.clipboardHistory.availabilityKey)
        FeatureRuntime.shared.configureFactory(FeatureFactory(userDefaults: .standard))
        FeatureRuntime.shared.bootstrapInstalledFeatures()

        XCTAssertNil(FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self))

        FeatureRuntime.shared.setAvailable(.clipboardHistory, true)

        let manager = FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)
        XCTAssertNotNil(manager)
        XCTAssertTrue(manager?.isMonitoring == true)
    }

    func test_setAvailableFalse_tearsDownAndDropsClipboardManager() {
        FeatureRuntime.shared.configureFactory(FeatureFactory(userDefaults: .standard))
        FeatureRuntime.shared.bootstrapInstalledFeatures()

        var manager = FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self)
        XCTAssertNotNil(manager)
        weak var weakManager: ClipboardHistoryManager? = manager

        FeatureRuntime.shared.setAvailable(.clipboardHistory, false)

        XCTAssertNil(FeatureRuntime.shared.manager(for: .clipboardHistory, as: ClipboardHistoryManager.self))
        XCTAssertFalse(manager?.isMonitoring ?? true)
        manager = nil
        XCTAssertNil(weakManager)
    }

    func test_trueUnload_doesNotRequireRestart() {
        FeatureRuntime.shared.configureFactory(FeatureFactory(userDefaults: .standard))
        FeatureRuntime.shared.bootstrapInstalledFeatures()
        FeatureRuntime.shared.setAvailable(.quickPhrase, false)
        XCTAssertFalse(FeatureRuntime.shared.needsRestartToUnload)
    }

    func test_setAvailableFalse_stopsInputLockObservation() {
        FeatureRuntime.shared.configureFactory(FeatureFactory(userDefaults: .standard))
        FeatureRuntime.shared.bootstrapInstalledFeatures()

        let input = FeatureRuntime.shared.manager(for: .inputLock, as: InputMethodManager.self)
        XCTAssertNotNil(input)
        // 生产路径由 AppState 启动观察；这里显式启动以验证 teardown 会停掉
        input?.startObservingInputSourceChanges {}
        XCTAssertTrue(input?.isObservingInputSourceChanges == true)

        FeatureRuntime.shared.setAvailable(.inputLock, false)

        XCTAssertNil(FeatureRuntime.shared.manager(for: .inputLock, as: InputMethodManager.self))
        XCTAssertFalse(input?.isObservingInputSourceChanges ?? true)
    }
}
