import XCTest
import AppKit
@testable import OmniForge

@MainActor
final class TokenResetCelebrationControllerTests: XCTestCase {

    func test_confettiEmitter_isFlipped_isTrue() {
        let view = ConfettiEmitterNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(view.isFlipped, "必须为翻转坐标系，确保原点在左上角且 Y 轴正方向向下")
    }

    func test_confettiEmitter_cells_configuredWithGravityAndDownwardEmission() {
        let view = ConfettiEmitterNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let cells = view.emitter.emitterCells, !cells.isEmpty else {
            XCTFail("emitterCells 不能为空")
            return
        }

        XCTAssertEqual(cells.count, 8, "包含 8 种调色板颜色")
        for cell in cells {
            XCTAssertEqual(cell.emissionLongitude, .pi / 2, accuracy: 0.001, "发射角度应为向下（+pi/2）")
            XCTAssertGreaterThanOrEqual(cell.yAcceleration, 100, "应配置重力下落加速度")
            XCTAssertGreaterThanOrEqual(cell.velocity, 150, "应配置充足的初速度")
            XCTAssertGreaterThanOrEqual(cell.lifetime, 6.0, "粒子寿命需支持穿透全屏")
            XCTAssertGreaterThan(cell.birthRate, 0, "粒子产生速率需大于 0")
        }
    }

    func test_confettiEmitter_layout_positionsAtTopAndFullWidth() {
        let width: CGFloat = 1440
        let height: CGFloat = 900
        let view = ConfettiEmitterNSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.layout()

        XCTAssertEqual(view.emitter.emitterPosition.x, width / 2, accuracy: 0.1)
        XCTAssertEqual(view.emitter.emitterPosition.y, -20, accuracy: 0.1, "发射线位于屏幕顶部上方 20pt")
        XCTAssertEqual(view.emitter.emitterSize.width, width, accuracy: 0.1, "发射宽度覆盖全屏")
    }

    func test_celebrationController_lifecycle() {
        let controller = TokenResetCelebrationController()
        // 双关时直接忽略
        controller.play(
            message: "测试重置",
            provider: .codex,
            showsToast: false,
            showsConfetti: false
        )
        controller.dismiss()
    }
}
