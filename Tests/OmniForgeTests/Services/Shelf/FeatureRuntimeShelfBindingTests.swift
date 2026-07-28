import XCTest
@testable import OmniForge

@MainActor
final class FeatureRuntimeShelfBindingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // AppFeature.isAvailable and bindings read UserDefaults.standard.
        for feature in AppFeature.allCases {
            UserDefaults.standard.set(true, forKey: feature.availabilityKey)
        }
        FeatureRuntime.shared.resetForTesting()
    }

    override func tearDown() {
        FeatureRuntime.shared.resetForTesting()
        for feature in AppFeature.allCases {
            UserDefaults.standard.removeObject(forKey: feature.availabilityKey)
        }
        super.tearDown()
    }

    func test_shelfBinding_invokesSyncWhenAvailable() {
        let service = ShelfService()
        FeatureRuntime.shared.register(.shelf, manager: service)

        FeatureRuntime.shared.sync([.shelf])

        XCTAssertEqual(service.syncWithPreferencesCallCount, 1)
    }

    func test_shelfBinding_skipsWhenUnavailable() {
        let service = ShelfService()
        FeatureRuntime.shared.register(.shelf, manager: service)
        UserDefaults.standard.set(false, forKey: AppFeature.shelf.availabilityKey)

        FeatureRuntime.shared.sync([.shelf])

        XCTAssertEqual(service.syncWithPreferencesCallCount, 0)
    }

    func test_shelfBinding_noManager_doesNotCrash() {
        FeatureRuntime.shared.sync([.shelf])
        FeatureRuntime.shared.syncAtLaunch()
    }

    func test_shelfBinding_setAvailableTrue_invokesSync() {
        let service = ShelfService()
        FeatureRuntime.shared.register(.shelf, manager: service)
        UserDefaults.standard.set(false, forKey: AppFeature.shelf.availabilityKey)
        FeatureRuntime.shared.resetForTesting()
        FeatureRuntime.shared.register(.shelf, manager: service)

        FeatureRuntime.shared.setAvailable(.shelf, true)

        XCTAssertEqual(service.syncWithPreferencesCallCount, 1)
    }
}
