import CoreGraphics
import XCTest
@testable import OmniForge

final class SnapOcclusionClipperTests: XCTestCase {
    /// 下层控件完整 frame 被上层盖住右半：可见左半（含鼠标点）应作为结果。
    func test_clip_rightHalfOccluded_keepsLeftVisibleContainingPoint() {
        let candidate = CGRect(x: 0, y: 0, width: 200, height: 100)
        let point = CGPoint(x: 40, y: 50)
        let occluders = [CGRect(x: 100, y: 0, width: 200, height: 100)]
        let visible = SnapOcclusionClipper.clip(
            candidate: candidate,
            containing: point,
            occluders: occluders
        )
        XCTAssertEqual(visible, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    /// 上层盖住左半，点在右侧 → 保留右半。
    func test_clip_leftHalfOccluded_keepsRightVisibleContainingPoint() {
        let candidate = CGRect(x: 0, y: 0, width: 200, height: 100)
        let point = CGPoint(x: 150, y: 40)
        let occluders = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let visible = SnapOcclusionClipper.clip(
            candidate: candidate,
            containing: point,
            occluders: occluders
        )
        XCTAssertEqual(visible, CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    /// 无遮挡 → 原 rect。
    func test_clip_noOccluders_returnsOriginal() {
        let candidate = CGRect(x: 10, y: 20, width: 80, height: 60)
        let point = CGPoint(x: 30, y: 40)
        let visible = SnapOcclusionClipper.clip(
            candidate: candidate,
            containing: point,
            occluders: []
        )
        XCTAssertEqual(visible, candidate)
    }

    /// 点不在候选内 → nil。
    func test_clip_pointOutsideCandidate_returnsNil() {
        let visible = SnapOcclusionClipper.clip(
            candidate: CGRect(x: 0, y: 0, width: 50, height: 50),
            containing: CGPoint(x: 100, y: 100),
            occluders: []
        )
        XCTAssertNil(visible)
    }

    /// 点落在遮挡窗内（语义上不应发生，但防御）→ nil。
    func test_clip_pointInsideOccluder_returnsNil() {
        let visible = SnapOcclusionClipper.clip(
            candidate: CGRect(x: 0, y: 0, width: 200, height: 100),
            containing: CGPoint(x: 150, y: 50),
            occluders: [CGRect(x: 100, y: 0, width: 200, height: 100)]
        )
        XCTAssertNil(visible)
    }

    /// 不与候选相交的遮挡窗忽略。
    func test_clip_nonIntersectingOccluder_ignored() {
        let candidate = CGRect(x: 0, y: 0, width: 100, height: 100)
        let point = CGPoint(x: 20, y: 20)
        let visible = SnapOcclusionClipper.clip(
            candidate: candidate,
            containing: point,
            occluders: [CGRect(x: 500, y: 500, width: 50, height: 50)]
        )
        XCTAssertEqual(visible, candidate)
    }

    /// 多层遮挡依次裁切：上盖右半、再盖上半中的可见剩余 → 取仍含点的块。
    func test_clip_multipleOccluders_iterative() {
        // 候选 0,0-200x200；遮挡1 右半 100,0-100x200；遮挡2 上半可见区中的 0,0-100x50
        // 点 (30,100) 在左下可见 0,50-100x150
        let candidate = CGRect(x: 0, y: 0, width: 200, height: 200)
        let point = CGPoint(x: 30, y: 100)
        let occluders = [
            CGRect(x: 100, y: 0, width: 100, height: 200),
            CGRect(x: 0, y: 0, width: 100, height: 50),
        ]
        let visible = SnapOcclusionClipper.clip(
            candidate: candidate,
            containing: point,
            occluders: occluders
        )
        XCTAssertEqual(visible, CGRect(x: 0, y: 50, width: 100, height: 150))
    }

    /// 裁切后边长过小（minSize）→ nil。
    func test_clip_resultBelowMinSize_returnsNil() {
        let candidate = CGRect(x: 0, y: 0, width: 30, height: 100)
        let point = CGPoint(x: 5, y: 50)
        // 遮挡后只剩宽 10
        let occluders = [CGRect(x: 10, y: 0, width: 100, height: 100)]
        let visible = SnapOcclusionClipper.clip(
            candidate: candidate,
            containing: point,
            occluders: occluders,
            minSize: 20
        )
        XCTAssertNil(visible)
    }
}
