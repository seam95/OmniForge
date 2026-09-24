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
        mirrorX: false,
        frameDurations: nil
    )

    /// 4 帧、4fps（总时长 1s）的循环 idle 动画。
    private let idle = PetSpriteAsset.Animation(
        id: PetAnimationID.idle,
        frames: [0, 1, 2, 3],
        fps: 4,
        loops: true,
        mirrorX: false,
        frameDurations: nil
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

    // MARK: - 非均匀逐帧时长

    /// 参考实现的 idle 节奏：首帧慢起、中段快呼吸、尾帧慢收。
    private let uneven = PetSpriteAsset.Animation(
        id: PetAnimationID.idle,
        frames: [10, 11, 12, 13, 14, 15],
        fps: 4,
        loops: false,
        mirrorX: false,
        frameDurations: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]
    )

    func test_unevenDurationsAdvanceByCumulativeTime() {
        let entered = date(after: 0)
        // 累计边界：0.28 / 0.39 / 0.50 / 0.64 / 0.78 / 1.10。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.10), stateEnteredAt: entered, animation: uneven),
            10, "0.10s 仍在首帧（首帧长 280ms）"
        )
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.30), stateEnteredAt: entered, animation: uneven),
            11, "0.30s 已过首帧边界 0.28s"
        )
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.40), stateEnteredAt: entered, animation: uneven),
            12, "0.40s 过第二边界 0.39s"
        )
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.70), stateEnteredAt: entered, animation: uneven),
            14, "0.70s 过第四边界 0.64s"
        )
        // 播完停在最后一帧。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 2.0), stateEnteredAt: entered, animation: uneven),
            15, "超过总时长 1.10s 停尾帧"
        )
    }

    func test_unevenLoopingWrapsAtUnevenTotal() {
        // 循环动画按非均匀总时长取模：周期为 1.10s 而非 6 × 0.25 = 1.5s。
        // 基准 reference date 100 对 1.10s 取模余 1.0，故 t 的相位为 (1.0 + t) mod 1.10。
        let looping = PetSpriteAsset.Animation(
            id: PetAnimationID.idle,
            frames: [10, 11, 12, 13, 14, 15],
            fps: 4,
            loops: true,
            mirrorX: false,
            frameDurations: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]
        )
        let entered = date(after: 0)
        // t=1.40 → 相位 0.20s：仍在首帧内（首帧长 280ms）。若周期误按 1.5s 算，
        // 相位会是 1.40 - 1.50 = 负值被夹到 0，同样落在首帧——故用第二个断言区分。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 1.40), stateEnteredAt: entered, animation: looping),
            10, "1.40s 取模后相位 0.20s，落在首帧"
        )
        // t=1.60 → 相位 0.40s：落在第三帧（累计边界 0.28 / 0.39 / 0.50）。
        // 按 1.5s 周期时相位会是 0.10s → 首帧，故此断言能真正区分两种周期。
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 1.60), stateEnteredAt: entered, animation: looping),
            12, "1.60s 取模后相位 0.40s，落在第三帧"
        )
    }

    func test_uniformFallbackKeepsPreviousBehavior() {
        // frameDurations 为 nil 时行为与引入该字段前完全一致（均匀 fps）。
        let entered = date(after: 0)
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.2), stateEnteredAt: entered, animation: petted),
            25
        )
        XCTAssertEqual(
            PetFrameSequencer.frameIndex(now: date(after: 0.25), stateEnteredAt: entered, animation: idle),
            1
        )
    }

    // MARK: - 边界

    func test_emptyFramesReturnNil() {
        let empty = PetSpriteAsset.Animation(
            id: PetAnimationID.idle, frames: [], fps: 4, loops: true, mirrorX: false,
            frameDurations: nil
        )
        XCTAssertNil(
            PetFrameSequencer.frameIndex(now: date(after: 0), stateEnteredAt: date(after: 0), animation: empty)
        )
    }

    func test_zeroFPSFallsBackToFirstFrameSafely() {
        // fps ≤ 0 时 frameDuration 兜底 0.25s，帧序号推导不崩溃。
        let weird = PetSpriteAsset.Animation(
            id: PetAnimationID.idle, frames: [0, 1], fps: 0, loops: false, mirrorX: false,
            frameDurations: nil
        )
        XCTAssertNotNil(
            PetFrameSequencer.frameIndex(now: date(after: 1), stateEnteredAt: date(after: 0), animation: weird)
        )
    }
}
