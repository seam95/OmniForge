import XCTest
@testable import OmniForge

@MainActor
final class UpdateManagerTests: XCTestCase {

    /// 共享实例可访问，且 updater 已接线（非 nil、属主 bundle 为当前应用）。
    func test_shared_exposesStartedUpdater() {
        let manager = UpdateManager.shared

        XCTAssertNotNil(manager.updater)
        // 非沙盒、标准 UI 接入下，updater 面向主 bundle。
        XCTAssertEqual(manager.updater.hostBundle.bundleIdentifier, Bundle.main.bundleIdentifier)
    }

    /// start() 幂等：重复调用不崩溃、不抛错。
    func test_start_isIdempotent() {
        let manager = UpdateManager.shared
        manager.start()
        manager.start()

        XCTAssertNotNil(manager.updater)
    }
}
