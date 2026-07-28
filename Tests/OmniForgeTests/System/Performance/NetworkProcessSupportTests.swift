import XCTest
@testable import OmniForge

final class NetworkProcessSupportTests: XCTestCase {
    func test_parseNettopCSVExtractsPidAndBytes() {
        let csv = """
        time,process,bytes_in,bytes_out
        00:00:01,Chrome.1234,1000,2000
        """
        let samples = NetworkProcessSupport.parseNettopCSV(csv)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].pid, 1234)
        XCTAssertEqual(samples[0].bytesIn, 1000)
        XCTAssertEqual(samples[0].bytesOut, 2000)
        XCTAssertEqual(samples[0].name, "Chrome")
    }

    func test_parseNettopCSVUsesLastSection() {
        let csv = """
        time,process,bytes_in,bytes_out
        00:00:01,Old.1,10,20
        time,process,bytes_in,bytes_out
        00:00:02,New.99,100,200
        """
        let samples = NetworkProcessSupport.parseNettopCSV(csv)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].pid, 99)
        XCTAssertEqual(samples[0].bytesIn, 100)
    }

    func test_parseNettopCSVSkipsZeroTraffic() {
        let csv = """
        time,process,bytes_in,bytes_out
        00:00:01,Idle.5,0,0
        00:00:01,Active.6,1,0
        """
        let samples = NetworkProcessSupport.parseNettopCSV(csv)
        XCTAssertEqual(samples.map(\.pid), [6])
    }

    func test_deltaTrackerFirstSampleIsEmptyBaseline() {
        var tracker = NetworkProcessDeltaTracker()
        let now = 10.0
        let first = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 1000, bytesOut: 500)],
            now: now
        )
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(tracker.hasBaseline(now: now + 1))

        let second = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 3000, bytesOut: 1500)],
            now: now + 2
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].bytesIn, 1000, accuracy: 0.001) // 2000 / 2s
        XCTAssertEqual(second[0].bytesOut, 500, accuracy: 0.001)
    }

    func test_deltaTrackerResetClearsBaseline() {
        var tracker = NetworkProcessDeltaTracker()
        _ = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 100, bytesOut: 0)],
            now: 1
        )
        tracker.reset()
        XCTAssertFalse(tracker.hasBaseline(now: 2))
        let again = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 200, bytesOut: 0)],
            now: 2
        )
        XCTAssertTrue(again.isEmpty)
    }

    func test_deltaTrackerExpiryWhenGapExceedsMaxGap() {
        // baseline 建立后，若两次采样间隔超过 maxGap（默认 30s），
        // 应自然过期返回空并重新建立 baseline，而非用过期基线算 delta。
        var tracker = NetworkProcessDeltaTracker(maxGap: 30)
        _ = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 1000, bytesOut: 0)],
            now: 10
        )
        // 正常间隔内有 delta
        let normal = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 2000, bytesOut: 0)],
            now: 12
        )
        XCTAssertEqual(normal.count, 1)

        // 间隔超过 maxGap → 过期，返回空
        let stale = tracker.rates(
            from: [NetworkProcessSample(pid: 1, name: "a", bytesIn: 9999, bytesOut: 0)],
            now: 50 // 12 + 38 > 30
        )
        XCTAssertTrue(stale.isEmpty)
    }

    func test_deltaTrackerDuplicatePIDsUsesLastWinsBaseline() {
        var tracker = NetworkProcessDeltaTracker()
        // First tick: duplicate PID entries must not trap when folding into the baseline map.
        let first = tracker.rates(
            from: [
                NetworkProcessSample(pid: 7, name: "old", bytesIn: 100, bytesOut: 10),
                NetworkProcessSample(pid: 7, name: "new", bytesIn: 1000, bytesOut: 100),
            ],
            now: 10
        )
        XCTAssertTrue(first.isEmpty)

        // Second tick: last-wins baseline (1000/100) drives the delta for pid 7.
        let second = tracker.rates(
            from: [
                NetworkProcessSample(pid: 7, name: "new", bytesIn: 3000, bytesOut: 500),
                NetworkProcessSample(pid: 7, name: "newer", bytesIn: 5000, bytesOut: 900),
            ],
            now: 12
        )
        // compactMap yields one rate per input sample that has a previous; both share pid 7.
        XCTAssertEqual(second.count, 2)
        // Against last-wins previous (1000, 100) over 2s:
        // first current: (3000-1000)/2 = 1000, (500-100)/2 = 200
        XCTAssertEqual(second[0].bytesIn, 1000, accuracy: 0.001)
        XCTAssertEqual(second[0].bytesOut, 200, accuracy: 0.001)
        // second current: (5000-1000)/2 = 2000, (900-100)/2 = 400
        XCTAssertEqual(second[1].bytesIn, 2000, accuracy: 0.001)
        XCTAssertEqual(second[1].bytesOut, 400, accuracy: 0.001)
    }

    func test_nettopArgumentsIncludeCSVLoggingFlags() {
        XCTAssertTrue(NetworkProcessSupport.nettopArguments.contains("-P"))
        XCTAssertTrue(NetworkProcessSupport.nettopArguments.contains("-L"))
        XCTAssertTrue(NetworkProcessSupport.nettopArguments.contains("bytes_in,bytes_out")
            || NetworkProcessSupport.nettopArguments.contains(where: { $0.contains("bytes_in") }))
    }
}
