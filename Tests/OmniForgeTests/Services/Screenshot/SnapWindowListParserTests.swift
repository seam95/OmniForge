import CoreGraphics
import XCTest
@testable import OmniForge

final class SnapWindowListParserTests: XCTestCase {
    func test_parse_readsBoundsPIDAndLayer() {
        let entries: [[String: Any]] = [
            [
                kCGWindowNumber as String: 42,
                kCGWindowOwnerPID as String: pid_t(77),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 10.0, "Y": 20.0, "Width": 300.0, "Height": 200.0,
                ] as [String: CGFloat],
            ],
        ]
        let windows = SnapWindowListParser.parse(entries, excludingWindowIDs: [])
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].windowID, 42)
        XCTAssertEqual(windows[0].ownerPID, 77)
        XCTAssertEqual(windows[0].bounds, CGRect(x: 10, y: 20, width: 300, height: 200))
        XCTAssertEqual(windows[0].layer, 0)
    }

    func test_parse_excludesOverlayWindowIDsAndEmptyBounds() {
        let entries: [[String: Any]] = [
            [
                kCGWindowNumber as String: 1,
                kCGWindowOwnerPID as String: pid_t(99),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 0.0, "Y": 0.0, "Width": 100.0, "Height": 100.0,
                ] as [String: CGFloat],
            ],
            [
                kCGWindowNumber as String: 2,
                kCGWindowOwnerPID as String: pid_t(50),
                kCGWindowLayer as String: 0,
                kCGWindowBounds as String: [
                    "X": 0.0, "Y": 0.0, "Width": 0.0, "Height": 0.0,
                ] as [String: CGFloat],
            ],
            [
                kCGWindowNumber as String: 3,
                kCGWindowOwnerPID as String: pid_t(50),
                kCGWindowLayer as String: Int(CGWindowLevelForKey(.dockWindow)),
                kCGWindowBounds as String: [
                    "X": 0.0, "Y": 900.0, "Width": 800.0, "Height": 60.0,
                ] as [String: CGFloat],
            ],
        ]
        let windows = SnapWindowListParser.parse(entries, excludingWindowIDs: [1])
        XCTAssertEqual(windows.map(\.windowID), [3])
    }

    /// 排除粒度回归：同 pid 的非遮罩窗口必须保留。
    /// 整进程排除会把自有业务窗口（控制中心/剪贴板/钉图）一并丢掉，
    /// 导致悬停自家窗口永远无吸附候选。
    func test_parse_keepsSameOwnerWindowsWhenOnlyOverlayIDExcluded() {
        let entries: [[String: Any]] = [
            windowEntry(id: 7, pid: 99, x: 0),
            windowEntry(id: 8, pid: 99, x: 100),
        ]
        let windows = SnapWindowListParser.parse(entries, excludingWindowIDs: [7])
        XCTAssertEqual(windows.map(\.windowID), [8])
    }

    func test_parse_preservesFrontToBackOrder() {
        let entries: [[String: Any]] = [
            windowEntry(id: 10, pid: 1, x: 0),
            windowEntry(id: 20, pid: 2, x: 10),
            windowEntry(id: 30, pid: 3, x: 20),
        ]
        let windows = SnapWindowListParser.parse(entries, excludingWindowIDs: [20])
        XCTAssertEqual(windows.map(\.windowID), [10, 30])
    }

    private func windowEntry(id: Int, pid: pid_t, x: CGFloat) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: [
                "X": x, "Y": 0.0, "Width": 50.0, "Height": 50.0,
            ] as [String: CGFloat],
        ]
    }
}
