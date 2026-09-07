import XCTest
import OmniForgeSMC
@testable import OmniForge

final class FanSamplerTests: XCTestCase {

    /// 双风扇典型读数：全部 key 可读、valid 全真
    private func makeDualFanMock() -> MockFanSMCCommanding {
        let mock = MockFanSMCCommanding()
        mock.uint8Values["FNum"] = 2
        mock.uint8Values["F0Md"] = 0
        mock.uint8Values["F1Md"] = 1
        mock.doubleValues["F0Ac"] = 3200
        mock.doubleValues["F0Mn"] = 1200
        mock.doubleValues["F0Mx"] = 5800
        mock.doubleValues["F0Tg"] = 3200
        mock.doubleValues["F1Ac"] = 3400
        mock.doubleValues["F1Mn"] = 1200
        mock.doubleValues["F1Mx"] = 5900
        mock.doubleValues["F1Tg"] = 3500
        return mock
    }

    func test_sampleFans_twoFans_readsAllKeysWithValidFlags() throws {
        let sampler = FanSampler(smc: makeDualFanMock())

        let fans = try sampler.sampleFans()

        XCTAssertEqual(fans.count, 2)
        XCTAssertEqual(fans[0].currentRPM, 3200)
        XCTAssertEqual(fans[0].minRPM, 1200)
        XCTAssertEqual(fans[0].maxRPM, 5800)
        XCTAssertEqual(fans[0].isManualMode, false)
        XCTAssertTrue(fans[0].currentRPMValid)
        XCTAssertTrue(fans[0].targetRPMValid)
        XCTAssertTrue(fans[0].isManualModeValid)
        XCTAssertEqual(fans[1].isManualMode, true)
    }

    func test_sampleFans_failedRead_flaggedInvalidNotSilentZero() throws {
        let mock = makeDualFanMock()
        mock.doubleValues["F0Ac"] = nil
        mock.doubleValues["F0Tg"] = nil
        mock.uint8Values["F0Md"] = nil

        let fans = try FanSampler(smc: mock).sampleFans()

        XCTAssertEqual(fans[0].currentRPM, 0)
        XCTAssertFalse(fans[0].currentRPMValid, "读不到 ≠ 停转 0 RPM")
        XCTAssertFalse(fans[0].targetRPMValid)
        XCTAssertFalse(fans[0].isManualModeValid)
    }

    func test_sampleFans_minMaxFallback_whenUnreadableOrImplausible() throws {
        let mock = makeDualFanMock()
        mock.doubleValues["F0Mn"] = 50   // 异常小
        mock.doubleValues["F0Mx"] = nil  // 读不到

        let fans = try FanSampler(smc: mock).sampleFans()

        XCTAssertEqual(fans[0].minRPM, 1000, "异常最小转速回退保守默认")
        XCTAssertEqual(fans[0].maxRPM, 15000, "最大转速读不到回退保守默认")
    }

    func test_sampleFans_minMaxCached_acrossSamples() throws {
        let mock = makeDualFanMock()
        let sampler = FanSampler(smc: mock)
        _ = try sampler.sampleFans()

        // 第二轮 SMC 返回变化 — 硬件常量不应跟着变
        mock.doubleValues["F0Mn"] = 999
        mock.doubleValues["F0Mx"] = 999
        let fans = try sampler.sampleFans()

        XCTAssertEqual(fans[0].minRPM, 1200)
        XCTAssertEqual(fans[0].maxRPM, 5800)
    }

    func test_sampleFans_fanCountZero_returnsEmpty() throws {
        let mock = makeDualFanMock()
        mock.uint8Values["FNum"] = 0

        let fans = try FanSampler(smc: mock).sampleFans()

        XCTAssertTrue(fans.isEmpty, "无风扇机器返回空态而非错误")
    }

    func test_sampleFans_fanCountUnreadable_throws() {
        let mock = makeDualFanMock()
        mock.uint8Values["FNum"] = nil

        XCTAssertThrowsError(try FanSampler(smc: mock).sampleFans())
    }

    func test_sampleFans_outOfRangeRPM_clamped() throws {
        let mock = makeDualFanMock()
        mock.doubleValues["F0Ac"] = 999_999

        let fans = try FanSampler(smc: mock).sampleFans()

        XCTAssertEqual(fans[0].currentRPM, 20000, "解码毛刺钳到上限")
    }
}
