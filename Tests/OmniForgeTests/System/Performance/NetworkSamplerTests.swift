import XCTest
@testable import OmniForge

final class NetworkSamplerTests: XCTestCase {
    func test_firstSampleHasNoRate() throws {
        let source = FakeNetworkCounterSource(values: [NetworkCounters(received: 100, sent: 50)])
        let sampler = NetworkSampler(counterSource: source)
        let reading = try sampler.sample(now: 10)
        XCTAssertNil(reading.downBytesPerSec)
        XCTAssertNil(reading.upBytesPerSec)
    }

    func test_secondSampleShowsRate() throws {
        let source = FakeNetworkCounterSource(values: [
            NetworkCounters(received: 100, sent: 50),
            NetworkCounters(received: 200, sent: 100)
        ])
        let sampler = NetworkSampler(counterSource: source)
        _ = try sampler.sample(now: 10)
        let reading = try sampler.sample(now: 12)
        let down = try XCTUnwrap(reading.downBytesPerSec)
        XCTAssertEqual(down, 50, accuracy: 0.001)
        let up = try XCTUnwrap(reading.upBytesPerSec)
        XCTAssertEqual(up, 25, accuracy: 0.001)
    }

    func test_shortIntervalReusesLastRatesWithoutSpike() throws {
        // 面板打开补采与定时 tick 可能背靠背（间隔远小于刷新周期），
        // 字节数除以极短 elapsed 会产生速率尖刺——短间隔样本应作废并沿用上次速率
        let source = FakeNetworkCounterSource(values: [
            NetworkCounters(received: 100, sent: 50),   // t=10 基线
            NetworkCounters(received: 200, sent: 100),  // t=12 → 50/25 B/s
            NetworkCounters(received: 210, sent: 105),  // t=12.1 短间隔 → 沿用 50/25
            NetworkCounters(received: 410, sent: 205),  // t=14 基线已前移 → 200/1.9
        ])
        let sampler = NetworkSampler(counterSource: source)
        _ = try sampler.sample(now: 10)
        let normal = try sampler.sample(now: 12)
        XCTAssertEqual(try XCTUnwrap(normal.downBytesPerSec), 50, accuracy: 0.001)

        let short = try sampler.sample(now: 12.1)
        XCTAssertEqual(try XCTUnwrap(short.downBytesPerSec), 50, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(short.upBytesPerSec), 25, accuracy: 0.001)

        let next = try sampler.sample(now: 14)
        XCTAssertEqual(try XCTUnwrap(next.downBytesPerSec), 200.0 / 1.9, accuracy: 0.001)
    }
}

// MARK: - Test Helpers

final class FakeNetworkCounterSource: NetworkCounterSource {
    private var values: [NetworkCounters]
    private var index = 0

    init(values: [NetworkCounters]) {
        self.values = values
    }

    func interfaceBytes() throws -> (received: UInt64, sent: UInt64) {
        guard index < values.count else {
            throw MetricSamplingError.systemCall("no more fake values")
        }
        let v = values[index]
        index += 1
        return (v.received, v.sent)
    }
}
