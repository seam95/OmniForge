import XCTest
@testable import OmniForge

@MainActor
final class UpdateManagerTests: XCTestCase {

    /// 共享实例可访问，且 updater 已接线（非 nil、属主 bundle 为当前应用）。
    /// 测试进程不启动 updater：避免 Sparkle 在无有效 appcast 的测试宿主里检查更新并弹错误框。
    func test_shared_exposesUpdaterWithoutStartingInTests() {
        let manager = UpdateManager.shared

        XCTAssertNotNil(manager.updater)
        // 非沙盒、标准 UI 接入下，updater 面向主 bundle。
        XCTAssertEqual(manager.updater.hostBundle.bundleIdentifier, Bundle.main.bundleIdentifier)
        XCTAssertFalse(manager.canCheckForUpdates, "测试进程不启动 updater（不触发检查更新与错误弹窗）")
    }

    /// start() 幂等：测试进程下为 no-op，重复调用不崩溃、不抛错、不启动 updater。
    func test_start_isIdempotent() {
        let manager = UpdateManager.shared
        manager.start()
        manager.start()

        XCTAssertNotNil(manager.updater)
        XCTAssertFalse(manager.canCheckForUpdates, "重复 start 也不得在测试进程启动 updater")
    }
}
