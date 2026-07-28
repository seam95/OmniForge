import XCTest
@testable import OmniForge

@MainActor
final class FeatureRuntimeTests: XCTestCase {
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // AppFeature.isAvailable 读取 UserDefaults.standard，
        // 所以测试必须直接操作 standard 而非自定义 suite
        defaults = UserDefaults.standard
        for feature in AppFeature.allCases {
            defaults.set(true, forKey: feature.availabilityKey)
        }
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        defaults = nil
        super.tearDown()
    }

    func test_syncAtLaunch_runsBindingsForAvailableFeatures() {
        var bindingCalls: Set<AppFeature> = []
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.overrideBindingsForTesting { feature in
            bindingCalls.insert(feature)
        }

        FeatureRuntime.shared.syncAtLaunch()

        XCTAssertEqual(bindingCalls, Set(AppFeature.allCases))
    }

    func test_syncAtLaunch_skipsUnavailableFeatures() {
        defaults.set(false, forKey: AppFeature.clipboardHistory.availabilityKey)

        var bindingCalls: Set<AppFeature> = []
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.overrideBindingsForTesting { feature in
            bindingCalls.insert(feature)
        }

        FeatureRuntime.shared.syncAtLaunch()

        XCTAssertFalse(bindingCalls.contains(.clipboardHistory))
        XCTAssertTrue(bindingCalls.contains(.inputLock))
    }

    func test_setAvailable_bumpsRevision() {
        FeatureRuntime.shared.resetForTesting()
        let initialRevision = FeatureRuntime.shared.revision

        FeatureRuntime.shared.setAvailable(.clipboardHistory, false)

        XCTAssertEqual(FeatureRuntime.shared.revision, initialRevision + 1)
    }

    func test_setAvailable_sameValue_doesNotBumpRevision() {
        FeatureRuntime.shared.resetForTesting()
        let initialRevision = FeatureRuntime.shared.revision

        FeatureRuntime.shared.setAvailable(.clipboardHistory, true)

        XCTAssertEqual(FeatureRuntime.shared.revision, initialRevision)
    }

    func test_bootstrapInstalledFeatures_bumpsRevision() {
        // bootstrap 是批量 install 的对偶，装载 Manager 后必须 bump revision，
        // 让 AppState 等订阅方从 registry 重新拉取 Manager（与 install 事务一致）。
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.configureFactory(FeatureFactory(userDefaults: defaults))
        let initialRevision = FeatureRuntime.shared.revision

        FeatureRuntime.shared.bootstrapInstalledFeatures()

        XCTAssertEqual(FeatureRuntime.shared.revision, initialRevision + 1)
    }

    func test_setAvailable_false_makesFeatureUnavailable() {
        FeatureRuntime.shared.resetForTesting()

        FeatureRuntime.shared.setAvailable(.quickPhrase, false)

        XCTAssertFalse(FeatureRuntime.shared.isAvailable(.quickPhrase))
    }

    func test_setAvailableAsync_teardownThenPersistFalse() async {
        FeatureRuntime.shared.resetForTesting()
        let result = await FeatureRuntime.shared.setAvailableAsync(.clipboardHistory, false)
        if case .success = result {
            // ok
        } else {
            XCTFail("expected success, got \(result)")
        }
        XCTAssertFalse(FeatureRuntime.shared.isAvailable(.clipboardHistory))
        XCTAssertEqual(FeatureRuntime.shared.phase(for: .clipboardHistory), .idle)
    }

    func test_setAvailableAsync_sameValueIsSuccess() async {
        FeatureRuntime.shared.resetForTesting()
        let r1 = await FeatureRuntime.shared.setAvailableAsync(.shelf, false)
        let r2 = await FeatureRuntime.shared.setAvailableAsync(.shelf, false)
        if case .success = r1 {} else { XCTFail("\(r1)") }
        if case .success = r2 {} else { XCTFail("\(r2)") }
    }

    func test_sync_onlySyncsAvailableFeatures() {
        defaults.set(false, forKey: AppFeature.quickPhrase.availabilityKey)

        var bindingCalls: Set<AppFeature> = []
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.overrideBindingsForTesting { feature in
            bindingCalls.insert(feature)
        }

        FeatureRuntime.shared.sync([.quickPhrase, .inputLock])

        XCTAssertFalse(bindingCalls.contains(.quickPhrase))
        XCTAssertTrue(bindingCalls.contains(.inputLock))
    }

    func test_registerAndGetManager() {
        FeatureRuntime.shared.resetForTesting()

        let testValue = "test-manager-id"
        FeatureRuntime.shared.register(.inputLock, manager: testValue)

        let retrieved = FeatureRuntime.shared.manager(for: .inputLock, as: String.self)
        XCTAssertEqual(retrieved, testValue)
    }

    func test_needsRestartToUnload_falseWhenNoUninstall() {
        FeatureRuntime.shared.resetForTesting()
        XCTAssertFalse(FeatureRuntime.shared.needsRestartToUnload)
    }

    func test_needsRestartToUnload_trueAfterMidSessionUninstall() {
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.syncAtLaunch()

        FeatureRuntime.shared.setAvailable(.quickPhrase, false)

        XCTAssertTrue(FeatureRuntime.shared.needsRestartToUnload)
    }
}
