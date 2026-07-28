import XCTest
@testable import OmniForge

final class AnnotationGeometryTests: XCTestCase {

    func test_distanceFromPoint_toSegment_returnsZeroForPointOnSegment() {
        let result = distanceFromPoint(CGPoint(x: 5, y: 5), toSegment: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10))
        XCTAssertEqual(result, 0, accuracy: 0.001)
    }

    func test_distanceFromPoint_toSegment_returnsPerpendicularDistance() {
        let result = distanceFromPoint(CGPoint(x: 0, y: 5), toSegment: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))
        XCTAssertEqual(result, 5, accuracy: 0.001)
    }

    func test_distanceFromPoint_toSegment_clampsToEndpoints() {
        let result = distanceFromPoint(CGPoint(x: 20, y: 0), toSegment: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 0))
        XCTAssertEqual(result, 10, accuracy: 0.001)
    }

    func test_distanceFromPoint_toZeroLengthSegment() {
        let result = distanceFromPoint(CGPoint(x: 3, y: 4), toSegment: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 0))
        XCTAssertEqual(result, 5, accuracy: 0.001)
    }

    func test_strokedPathContains_returnsTrueForPointOnPath() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(strokedPathContains(CGPoint(x: 50, y: 0), path: path, lineWidth: 2))
    }

    func test_strokedPathContains_returnsFalseForPointOutsidePath() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(strokedPathContains(CGPoint(x: 50, y: 50), path: path, lineWidth: 2))
    }
}
