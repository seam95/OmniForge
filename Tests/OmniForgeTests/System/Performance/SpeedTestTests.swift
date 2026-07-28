import XCTest
import Combine
@testable import OmniForge

final class SpeedTestTests: XCTestCase {
    func test_initialStateIdle() {
        let test = SpeedTest()
        XCTAssertEqual(test.state, .idle)
    }

    func test_startTransitionsToRunningThenTerminalState() async {
        let exp = expectation(description: "terminal")
        let test = SpeedTest(
            sessionConfig: .ephemeral,
            endpoint: URL(string: "https://example.com")!
        )
        var sawRunning = false
        let sub = test.$state.sink { state in
            if case .running = state { sawRunning = true }
            if case .finished = state { exp.fulfill() }
            if case .failed = state { exp.fulfill() }
        }
        test.start()
        await fulfillment(of: [exp], timeout: 15)
        XCTAssertTrue(sawRunning)
        _ = sub
    }
}
