import XCTest
import Combine
@testable import OmniForge

@MainActor
final class PermissionsSyncTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FeatureRuntime.shared.resetForTesting()
        Permissions.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        Permissions.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        super.tearDown()
    }

    func test_accessibilityChange_syncsOnlyDependentFeatures() {
        let expectation = XCTestExpectation(description: "inputLock synced after accessibility change")
        var syncedFeatures: Set<AppFeature> = []
        FeatureRuntime.shared.overrideBindingsForTesting { feature in
            syncedFeatures.insert(feature)
            if feature == .inputLock {
                expectation.fulfill()
            }
        }

        // 权限订阅现由 AppDelegate 负责（从 AppState 迁移）
        let delegate = AppDelegate()
        delegate.setupPermissionSubscriptions()

        withExtendedLifetime(delegate) {
            // 模拟权限变化：false -> true
            Permissions.shared.setAccessibilityForTesting(true)

            // 等待 .receive(on: DispatchQueue.main) 派发的 sink 执行
            wait(for: [expectation], timeout: 2.0)
        }

        // inputLock 依赖 accessibility，应被 sync
        XCTAssertTrue(syncedFeatures.contains(.inputLock))
        // clipboardHistory 不依赖 accessibility，不应被 sync
        XCTAssertFalse(syncedFeatures.contains(.clipboardHistory))
    }
}
