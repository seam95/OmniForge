import XCTest
import AppKit
import Vortex
@testable import OmniForge

@MainActor
final class TokenResetCelebrationControllerTests: XCTestCase {

    func test_fireworksSystem_createsIndependentInstancePerCall() {
        // 每次庆祝必须持有私有系统：共享实例会让残留粒子按两次庆祝的完整间隔续跑，
        // 进而触发主线程海量迭代（见 makeFireworksSystem 注释）。
        let first = makeFireworksSystem()
        let second = makeFireworksSystem()

        XCTAssertFalse(first === second, "两次调用必须返回不同实例")
        XCTAssertNotEqual(first.id, second.id)
    }

    func test_fireworksSystem_containsSparkleAndExplosionSubsystems() {
        let system = makeFireworksSystem()

        let occasions = Set(system.secondarySystems.map(\.spawnOccasion))
        XCTAssertTrue(occasions.contains(.onUpdate), "缺少 sparkle 尾迹子系统（onUpdate）")
        XCTAssertTrue(occasions.contains(.onDeath), "缺少爆炸子系统（onDeath）")
    }

    func test_fireworksSystem_explosionEmissionBoundedForLongFrameDelta() {
        let system = makeFireworksSystem()

        guard let explosion = system.secondarySystems.first(where: { $0.spawnOccasion == .onDeath }) else {
            XCTFail("缺少爆炸子系统")
            return
        }

        XCTAssertEqual(explosion.emissionLimit, fireworksExplosionEmissionLimit, "爆炸发射上限应受常量约束")
        XCTAssertEqual(
            explosion.birthRate,
            Double(fireworksExplosionEmissionLimit * 60),
            accuracy: 0.001,
            "birthRate 必须等于 emissionLimit × 60，把长帧 delta 的迭代次数约束在每帧一个上限内"
        )
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
