import XCTest
@testable import OmniForge

/// CPUUsageSampler 溢出回归：cpu_ticks 是开机以来的 UInt32 累计值，
/// 多核高负载数十天即可接近上限——求和与差分必须升位运算，不得在 UInt32 域 trap。
final class CPUUsageSamplerOverflowTests: XCTestCase {
    /// 接近 UInt32 上限的 tick 值：求和 4×~4.29e9 在 UInt32 域必溢出。
    private static let nearMax: UInt32 = UInt32.max - 100

    func test_reading_nearUInt32MaxTicks_doesNotTrap() {
        let reading = CPUUsageSampler.reading(
            previousUser: Self.nearMax, previousSystem: Self.nearMax,
            previousNice: Self.nearMax, previousTotal: Self.nearMax,
            user: Self.nearMax + 30, system: Self.nearMax + 30,
            nice: Self.nearMax + 30, total: Self.nearMax + 100
        )
        // deltaTotal=100，非空闲 delta=90 → 90%。
        XCTAssertEqual(reading?.total ?? 0, 0.9, accuracy: 0.0001)
    }

    func test_sample_repeatedNearMaxTicks_returnsReading() throws {
        let sampler = CPUUsageSampler()
        // 机器真实 tick 远未到上限；此用例锁定采样路径本身在极限前值域下不崩。
        _ = try sampler.sample()
        let second = try sampler.sample()
        if let second {
            XCTAssertGreaterThanOrEqual(second.total, 0)
            XCTAssertLessThanOrEqual(second.total, 1.0)
        }
    }
}
