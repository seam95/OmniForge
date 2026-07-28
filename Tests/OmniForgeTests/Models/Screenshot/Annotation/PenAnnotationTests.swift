import XCTest
@testable import OmniForge

final class PenAnnotationTests: XCTestCase {

    func test_penAnnotation_containsPoint_onPath() {
        let pen = PenAnnotation(path: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)], color: .black, lineWidth: 4)
        // 点应该在路径附近
        XCTAssertTrue(pen.containsPoint(CGPoint(x: 10, y: 10)))
    }

    func test_penAnnotation_doesNotContainPoint_farFromPath() {
        let pen = PenAnnotation(path: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], color: .black, lineWidth: 2)
        XCTAssertFalse(pen.containsPoint(CGPoint(x: 50, y: 50)))
    }

    func test_penAnnotation_translated_shiftsPath() {
        let pen = PenAnnotation(path: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)], color: .black, lineWidth: 2)
        let moved = pen.translated(by: CGPoint(x: 10, y: 20))
        guard let movedPen = moved as? PenAnnotation else {
            XCTFail("Expected PenAnnotation")
            return
        }
        XCTAssertEqual(movedPen.path[0], CGPoint(x: 10, y: 20))
        XCTAssertEqual(movedPen.path[1], CGPoint(x: 110, y: 120))
    }

    func test_penAnnotation_boundingRect_includesMargin() {
        let pen = PenAnnotation(path: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)], color: .black, lineWidth: 4)
        let bounds = pen.boundingRect
        XCTAssertLessThanOrEqual(bounds.minX, 10 - 4)
        XCTAssertLessThanOrEqual(bounds.minY, 10 - 4)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 20 + 4)
        XCTAssertGreaterThanOrEqual(bounds.maxY, 20 + 4)
    }
}

final class LineAnnotationTests: XCTestCase {

    func test_lineAnnotation_containsPoint_onSegment() {
        let line = LineAnnotation(uuid: UUID(), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: .black, lineWidth: 4)
        XCTAssertTrue(line.containsPoint(CGPoint(x: 50, y: 0)))
    }

    func test_lineAnnotation_containsPoint_nearSegment() {
        let line = LineAnnotation(uuid: UUID(), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: .black, lineWidth: 4)
        // 命中半径 = (lineWidth + 4) / 2 = 4（参照 capcap strokedPathContains 语义）。
        // 点距线段 3 在命中半径内。
        XCTAssertTrue(line.containsPoint(CGPoint(x: 50, y: 3)))
    }

    func test_lineAnnotation_boundingRect() {
        let line = LineAnnotation(uuid: UUID(), start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 50), color: .black, lineWidth: 2)
        let bounds = line.boundingRect
        // margin = max(2/2 + 8, 8) = 9
        XCTAssertEqual(bounds.origin.x, -9, accuracy: 1)
        XCTAssertEqual(bounds.width, 118, accuracy: 1)
    }
}

final class RectAnnotationTests: XCTestCase {

    func test_rectAnnotation_containsPoint_onBorder() {
        let rect = RectAnnotation(uuid: UUID(), rect: CGRect(x: 0, y: 0, width: 100, height: 100), lineWidth: 4)
        // 点在边框上应命中（默认 fillMode = .none）
        XCTAssertTrue(rect.containsPoint(CGPoint(x: 0, y: 50)))
        XCTAssertTrue(rect.containsPoint(CGPoint(x: 50, y: 0)))
    }

    func test_rectAnnotation_containsPoint_outside() {
        let rect = RectAnnotation(uuid: UUID(), rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(rect.containsPoint(CGPoint(x: 150, y: 150)))
    }

    func test_rectAnnotation_withColor_keepsSameUUID() {
        let uuid = UUID()
        let rect = RectAnnotation(uuid: uuid, rect: CGRect(x: 0, y: 0, width: 100, height: 100), color: .red)
        let modified = rect.withColor(.blue) as! RectAnnotation
        XCTAssertEqual(rect.color, NSColor.red)
        XCTAssertEqual(modified.color, NSColor.blue)
        XCTAssertEqual(rect.uuid, uuid)
        XCTAssertEqual(modified.uuid, uuid) // UUID 不变，标识同一标注
    }
}
