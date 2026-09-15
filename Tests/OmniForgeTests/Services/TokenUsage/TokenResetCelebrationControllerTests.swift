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

    /// 闪光与爆炸同为 `.onDeath`，必须按发射上限区分定位，不依赖子系统顺序。
    private func explosionSubsystem(in system: VortexSystem) -> VortexSystem? {
        system.secondarySystems.first {
            $0.spawnOccasion == .onDeath && $0.emissionLimit == fireworksExplosionEmissionLimit
        }
    }

    func test_fireworksSystem_explosionEmissionBoundedForLongFrameDelta() {
        let system = makeFireworksSystem()

        guard let explosion = explosionSubsystem(in: system) else {
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

    func test_fireworksSystem_burstFlashIsSingleShortWhiteBurst() {
        let system = makeFireworksSystem()

        guard let flash = system.secondarySystems.first(where: { $0.spawnOccasion == .onDeath && $0.emissionLimit == 1 }) else {
            XCTFail("缺少爆裂闪光子系统（onDeath 且单粒子）")
            return
        }

        XCTAssertLessThanOrEqual(flash.lifespan, 0.3, "闪光必须一闪而过，不能盖住火星")
        XCTAssertGreaterThan(flash.size, 0.3, "闪光须是大尺寸光球，与细火星形成对比")
        XCTAssertEqual(flash.birthRate, 60, accuracy: 0.001, "闪光 birthRate 须按 emissionLimit × 60 口径防长帧")
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
