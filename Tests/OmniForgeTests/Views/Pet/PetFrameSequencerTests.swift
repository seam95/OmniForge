import XCTest
@testable import OmniForge

/// 帧序号推导测试：循环动画挂钟取模、一次性动画从状态进入时刻起播。
/// 回归锚点：一次性动画不得定格首帧（曾经的 elapsed 只清零不递增缺陷）。
final class PetFrameSequencerTests: XCTestCase {
    /// 3 帧、6fps（单帧 1/6s，总时长 0.5s）的抚摸动画。
    private let petted = PetSpriteAsset.Animation(
        id: PetAnimationID.petted,
        frames: [24, 25, 26],
        fps: 6,
        loops: false,
        mirrorX: false
    )

    /// 4 帧、4fps（总时长 1s）的循环 idle 动画。
    private let idle = PetSpriteAsset.Animation(
        id: PetAnimationID.idle,
        frames: [0, 1, 2, 3],
        fps: 4,
        loops: true,
        mirrorX: false
    )

    private func date(after seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: 100).addingTimeInterval(seconds)
    }

    // MARK: - 一次性动画

    func test_oneShotStartsAtFirstFrame() {
        let entered = date(after: 0)
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: entered, stateEnteredAt: entered, animation: petted),
            24
        )
    }

    func test_oneShotAdvancesWithElapsedTime() {
        let entered = date(after: 0)
        // 0.2s → 第 2 帧；0.4s → 第 3 帧（回归断言：不得停在首帧）。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.2), stateEnteredAt: entered, animation: petted),
            25
        )
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.4), stateEnteredAt: entered, animation: petted),
            26
        )
    }

    func test_oneShotHoldsLastFrameAfterTotalDuration() {
        let entered = date(after: 0)
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 10), stateEnteredAt: entered, animation: petted),
            26
        )
    }

    func test_oneShotDefendsAgainstClockSkew() {
        // now 早于进入时刻（时钟回拨）：按 0 处理，不产生负相位。
        let entered = date(after: 5)
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0), stateEnteredAt: entered, animation: petted),
            24
        )
    }

    // MARK: - 循环动画

    func test_loopingUsesWallClockPhase() {
        let entered = date(after: 0)
        // 挂钟 100.25s 对 1s 周期取模 → 0.25s → 第 2 帧。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.25), stateEnteredAt: entered, animation: idle),
            1
        )
        // 0.75s → 第 4 帧；1.0s 整周期回绕到第 1 帧。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.75), stateEnteredAt: entered, animation: idle),
            3
        )
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 1.0), stateEnteredAt: entered, animation: idle),
            0
        )
    }

    // MARK: - 边界

    func test_emptyFramesReturnNil() {
        let empty = PetSpriteAsset.Animation(
            id: PetAnimationID.idle, frames: [], fps: 4, loops: true, mirrorX: false
        )
        XCTAssertNil(
            PetFrameSequencer.frameIndex(now: date(after: 0), stateEnteredAt: date(after: 0), animation: empty)
        )
    }

    func test_zeroFPSFallsBackToFirstFrameSafely() {
        // fps ≤ 0 时 frameDuration 兜底 0.25s，帧序号推导不崩溃。
        let weird = PetSpriteAsset.Animation(
            id: PetAnimationID.idle, frames: [0, 1], fps: 0, loops: false, mirrorX: false
        )
        XCTAssertNotNil(
            PetFrameSequencer.frameIndex(now: date(after: 1), stateEnteredAt: date(after: 0), animation: weird)
        )
    }
}
