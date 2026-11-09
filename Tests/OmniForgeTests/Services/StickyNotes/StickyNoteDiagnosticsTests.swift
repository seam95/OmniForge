import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class StickyNoteDiagnosticsTests: XCTestCase {
    func test_recordsOrderedEventsAsReadableJSONLines() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticky-trace-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var diagnostics: StickyNoteDiagnostics? = try StickyNoteDiagnostics(url: url)
        let id = UUID()

        diagnostics?.record("window.didBecomeKey", noteID: id, fields: ["level": 1])
        diagnostics?.record("window.didResignKey", noteID: id, fields: ["level": 0])
        diagnostics = nil // 释放时排空写队列，验证文件可直接读取且没有丢失尾部事件。

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let rows = try lines.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["event"] as? String, "window.didBecomeKey")
        XCTAssertEqual(rows[1]["event"] as? String, "window.didResignKey")
        XCTAssertEqual(rows[0]["noteID"] as? String, id.uuidString)
        XCTAssertEqual(rows[0]["seq"] as? Int, 1)
        XCTAssertEqual(rows[1]["seq"] as? Int, 2)
        XCTAssertNotNil(rows[0]["uptime"] as? Double)
        XCTAssertEqual(rows[1]["level"] as? Int, 0)
    }

    func test_windowStackPreservesOrderAndOmitsWindowTitles() throws {
        func window(_ id: Int, x: Double, title: String) -> [String: Any] {
            [
                kCGWindowNumber as String: id,
                kCGWindowOwnerPID as String: 123,
                kCGWindowLayer as String: 0,
                kCGWindowName as String: title,
                kCGWindowBounds as String: ["X": x, "Y": 0.0, "Width": 100.0, "Height": 100.0]
            ]
        }
        let stack = StickyNoteDiagnostics.windowStack([
            window(9, x: 0, title: "私密正文"),
            window(8, x: 500, title: "其他窗口标题"),
            window(7, x: 10, title: "不可记录")
        ], intersecting: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertEqual(stack.compactMap { $0["id"] as? Int }, [9, 7])
        let encoded = try JSONSerialization.data(withJSONObject: stack)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("私密正文"))
        XCTAssertFalse(text.contains("不可记录"))
        XCTAssertFalse(text.contains(kCGWindowName as String))
    }
}
