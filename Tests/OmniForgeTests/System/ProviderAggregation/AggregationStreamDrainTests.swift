import XCTest
@testable import OmniForge

/// 聚合流式写回排空状态：确保最后一个 chunk 写出后才关闭客户端连接。
final class AggregationStreamDrainTests: XCTestCase {
    func test_finishWaitsForPendingSends() {
        let drain = AggregationStreamDrain()
        drain.beginSend()
        drain.beginSend()
        XCTAssertFalse(drain.finish(), "还有在途发送时不得关闭")
        XCTAssertFalse(drain.endSend())
        XCTAssertTrue(drain.endSend(), "最后一个发送完成后才允许关闭")
    }

    func test_finishWithoutPendingSendsClosesImmediately() {
        let drain = AggregationStreamDrain()
        XCTAssertTrue(drain.finish())
    }

    func test_endSendBeforeFinishDoesNotClose() {
        let drain = AggregationStreamDrain()
        drain.beginSend()
        XCTAssertFalse(drain.endSend(), "上游未结束前不关闭")
        XCTAssertTrue(drain.finish())
    }

    func test_endSendWithoutFinishNeverCloses() {
        let drain = AggregationStreamDrain()
        drain.beginSend()
        XCTAssertFalse(drain.endSend())
        XCTAssertTrue(drain.finish(), "上游结束后才关闭")
    }

    func test_concurrentBeginEndKeepsCountBalanced() {
        let drain = AggregationStreamDrain()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "AggregationStreamDrainTests", attributes: .concurrent)
        for _ in 0..<100 {
            queue.async(group: group) {
                drain.beginSend()
                _ = drain.endSend()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(drain.finish(), "并发结束后计数应归零")
    }
}
