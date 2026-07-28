import CoreGraphics
import XCTest
@testable import OmniForge

final class SnapOwnerPIDCollectorTests: XCTestCase {
    func test_collect_includesDockLayerAndNormalLayer() {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let entries: [[String: Any]] = [
            [kCGWindowOwnerPID as String: pid_t(101), kCGWindowLayer as String: 0],
            [kCGWindowOwnerPID as String: pid_t(202), kCGWindowLayer as String: dockLevel],
        ]
        let pids = Set(SnapOwnerPIDCollector.collect(from: entries, excludingPID: 1))
        XCTAssertEqual(pids, Set([101, 202]))
    }

    func test_collect_excludesSelfPIDEvenIfLayerZero() {
        let entries: [[String: Any]] = [
            [kCGWindowOwnerPID as String: pid_t(42), kCGWindowLayer as String: 0],
            [kCGWindowOwnerPID as String: pid_t(99), kCGWindowLayer as String: 0],
        ]
        let pids = SnapOwnerPIDCollector.collect(from: entries, excludingPID: 42)
        XCTAssertEqual(pids, [99])
    }

    func test_collect_includesMenuAndStatusLayers() {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let entries: [[String: Any]] = [
            [kCGWindowOwnerPID as String: pid_t(11), kCGWindowLayer as String: menuLevel],
            [kCGWindowOwnerPID as String: pid_t(12), kCGWindowLayer as String: statusLevel],
        ]
        let pids = Set(SnapOwnerPIDCollector.collect(from: entries, excludingPID: 1))
        XCTAssertEqual(pids, Set([11, 12]))
    }

    func test_collect_deduplicatesPIDs() {
        let entries: [[String: Any]] = [
            [kCGWindowOwnerPID as String: pid_t(7), kCGWindowLayer as String: 0],
            [kCGWindowOwnerPID as String: pid_t(7), kCGWindowLayer as String: 0],
        ]
        let pids = SnapOwnerPIDCollector.collect(from: entries, excludingPID: 1)
        XCTAssertEqual(pids, [7])
    }

    func test_collect_acceptsNSNumberPID() {
        let entries: [[String: Any]] = [
            [kCGWindowOwnerPID as String: NSNumber(value: Int32(55)), kCGWindowLayer as String: 0],
        ]
        let pids = SnapOwnerPIDCollector.collect(from: entries, excludingPID: 1)
        XCTAssertEqual(pids, [55])
    }
}
