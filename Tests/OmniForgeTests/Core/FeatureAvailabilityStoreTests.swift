import XCTest
@testable import OmniForge

final class FeatureAvailabilityStoreTests: XCTestCase {
    private var suiteNames: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteNames = []
    }

    override func tearDownWithError() throws {
        for name in suiteNames {
            UserDefaults().removePersistentDomain(forName: name)
        }
        try super.tearDownWithError()
    }

    func test_setAvailable_mirrorsIntoAppGroupDefaults() throws {
        let primary = makeIsolatedDefaults()
        let mirror = makeIsolatedDefaults()
        let store = UserDefaultsFeatureAvailabilityStore(defaults: primary, mirroredDefaults: mirror)

        try store.setAvailable(.rightClickEnhancement, false)

        XCTAssertFalse(store.isAvailable(.rightClickEnhancement))
        // 镜像域持有同一键值，沙盒内的 FinderSync 扩展据此读取
        XCTAssertEqual(
            mirror.object(forKey: AppFeature.rightClickEnhancement.availabilityKey) as? Bool,
            false
        )
    }

    func test_setAvailable_trueIsAlsoMirrored() throws {
        let primary = makeIsolatedDefaults()
        let mirror = makeIsolatedDefaults()
        let store = UserDefaultsFeatureAvailabilityStore(defaults: primary, mirroredDefaults: mirror)

        try store.setAvailable(.rightClickEnhancement, true)

        XCTAssertTrue(store.isAvailable(.rightClickEnhancement))
        XCTAssertEqual(
            mirror.object(forKey: AppFeature.rightClickEnhancement.availabilityKey) as? Bool,
            true
        )
    }

    func test_setAvailable_survivesNilMirroredDefaults() throws {
        let primary = makeIsolatedDefaults()
        let store = UserDefaultsFeatureAvailabilityStore(defaults: primary, mirroredDefaults: nil)

        try store.setAvailable(.rightClickEnhancement, false)

        XCTAssertFalse(store.isAvailable(.rightClickEnhancement))
    }

    // MARK: - 辅助

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "FeatureAvailabilityStoreTests.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }
}
