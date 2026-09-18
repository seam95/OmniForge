import XCTest
@testable import OmniForge

/// 桌宠窗口事件穿透缓存复位契约：
/// close() 必须把 receivesMouseEvents 复位为 true，否则换宠/重启后
/// 新窗口（ignoresMouseEvents 默认 false）与残留缓存脱节，
/// 首个 tick 的 setReceivesMouseEvents 命中 guard 直接 return，
/// 透明区穿透失效、点击误触发抚摸。
@MainActor
final class PetWindowControllerHitRoutingTests: XCTestCase {
    func test_close_resetsReceivesMouseEventsCache() {
        let controller = PetWindowController(petSize: CGSize(width: 96, height: 96))
        XCTAssertTrue(controller.receivesMouseEvents, "初始态：接收事件")

        // 模拟 teardown 时指针停在透明区（缓存被写成 false）
        controller.setReceivesMouseEvents(false)
        XCTAssertFalse(controller.receivesMouseEvents)

        controller.close()
        XCTAssertTrue(controller.receivesMouseEvents, "close 必须复位缓存，与新窗口默认状态同源")

        // 复位后再次进入透明区：guard 不得吞掉这次写入（幂等路径）。
        controller.setReceivesMouseEvents(false)
        XCTAssertFalse(controller.receivesMouseEvents)
    }
}
