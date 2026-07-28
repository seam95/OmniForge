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
