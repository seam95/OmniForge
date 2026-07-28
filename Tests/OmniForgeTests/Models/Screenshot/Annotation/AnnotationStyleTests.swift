import XCTest
@testable import OmniForge

/// 阶段 1 标注模型层重写后的契约测试，覆盖 capcap 对齐的关键能力。
final class AnnotationStyleTests: XCTestCase {

    // MARK: - SeededRandom 确定性

    func test_seededRandom_sameSeedProducesSameSequence() {
        var a = SeededRandom(seed: 42)
        var b = SeededRandom(seed: 42)
        for _ in 0..<10 {
            XCTAssertEqual(a.next(), b.next(), accuracy: 1e-9)
        }
    }

    func test_seededRandom_zeroSeedUsesFallback() {
        // seed=0 应映射到非零 fallback，不崩溃且可产出序列。
        var rng = SeededRandom(seed: 0)
        let first = rng.next()
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertLessThanOrEqual(first, 1)
    }

    func test_seededRandom_range_staysWithinBounds() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<50 {
            let value = rng.range(-5, 5)
            XCTAssertGreaterThanOrEqual(value, -5)
            XCTAssertLessThanOrEqual(value, 5)
        }
    }

    // MARK: - RoughShapeStyle

    func test_roughShapeStyle_make_usesRectAndLineWidth() {
        let large = RoughShapeStyle.make(seed: 1, rect: NSRect(x: 0, y: 0, width: 500, height: 500), lineWidth: 20)
        let small = RoughShapeStyle.make(seed: 1, rect: NSRect(x: 0, y: 0, width: 10, height: 10), lineWidth: 1)
        // 粗糙度应在 [0.15, 0.55] 区间内。
        XCTAssertGreaterThanOrEqual(large.roughness, 0.15)
        XCTAssertLessThanOrEqual(large.roughness, 0.55)
        XCTAssertGreaterThanOrEqual(small.roughness, 0.15)
    }

    func test_roughShapeStyle_clampsRoughness() {
        let tooHigh = RoughShapeStyle(seed: 1, roughness: 10, passes: 1)
        let tooLow = RoughShapeStyle(seed: 1, roughness: -5, passes: 1)
        XCTAssertEqual(tooHigh.roughness, 4, accuracy: 0.001)
        XCTAssertEqual(tooLow.roughness, 0, accuracy: 0.001)
    }

    func test_roughShapeStyle_clampsPasses() {
        let style = RoughShapeStyle(seed: 1, roughness: 0.3, passes: 10)
        XCTAssertEqual(style.passes, 3)
    }

    // MARK: - RectAnnotation strokeStyle 分支

    func test_rectAnnotation_handDrawn_strokeStyleStored() {
        let rect = RectAnnotation(rect: NSRect(x: 0, y: 0, width: 100, height: 80), strokeStyle: .handDrawn)
        XCTAssertEqual(rect.strokeStyle, .handDrawn)
        XCTAssertNotNil(rect.roughStyle)
    }

    func test_rectAnnotation_withShapeStrokeStyle_changesStyle() {
        let rect = RectAnnotation(rect: NSRect(x: 0, y: 0, width: 100, height: 80), strokeStyle: .standard)
        let rounded = rect.withShapeStrokeStyle(.rounded) as! RectAnnotation
        XCTAssertEqual(rounded.strokeStyle, .rounded)
        XCTAssertEqual(rect.strokeStyle, .standard)
    }

    func test_rectAnnotation_filled_containsInterior() {
        let rect = RectAnnotation(rect: NSRect(x: 0, y: 0, width: 100, height: 100), fillMode: .opaque)
        XCTAssertTrue(rect.containsPoint(CGPoint(x: 50, y: 50)))
    }

    // MARK: - EllipseAnnotation

    func test_ellipseAnnotation_filled_containsCenter() {
        let ellipse = EllipseAnnotation(rect: NSRect(x: 0, y: 0, width: 100, height: 100), fillMode: .opaque)
        XCTAssertTrue(ellipse.containsPoint(CGPoint(x: 50, y: 50)))
    }

    // MARK: - MarkerAnnotation

    func test_markerAnnotation_brushScale_scalesEffectiveWidth() {
        let marker = MarkerAnnotation(path: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], color: .yellow, lineWidth: 5)
        // 命中宽度按 brushScale 放大，点距线段 10 应在命中半径内。
        XCTAssertTrue(marker.containsPoint(CGPoint(x: 50, y: 10)))
    }

    func test_markerAnnotation_colorNormalizedToFullAlpha() {
        let marker = MarkerAnnotation(path: [CGPoint(x: 0, y: 0)], color: NSColor.yellow.withAlphaComponent(0.2), lineWidth: 5)
        XCTAssertEqual(marker.color.alphaComponent, 1.0, accuracy: 0.001)
    }

    // MARK: - LineAnnotation adjust helpers

    func test_lineAnnotation_withStart_replacesStartPoint() {
        let line = LineAnnotation(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let moved = line.withStart(CGPoint(x: 10, y: 10))
        XCTAssertEqual(moved.start, CGPoint(x: 10, y: 10))
        XCTAssertEqual(moved.end, CGPoint(x: 100, y: 0))
    }

    func test_lineAnnotation_withRotation_bakesIntoEndpoints() {
        let line = LineAnnotation(start: CGPoint(x: -10, y: 0), end: CGPoint(x: 10, y: 0))
        // 绕中点 (0,0) 旋转 90°：start→(0,-10)，end→(0,10)（旋转方向由实现定）。
        let rotated = line.withRotation(.pi / 2) as! LineAnnotation
        // 中点应保持原位。
        let midX = (rotated.start.x + rotated.end.x) / 2
        let midY = (rotated.start.y + rotated.end.y) / 2
        XCTAssertEqual(midX, 0, accuracy: 0.001)
        XCTAssertEqual(midY, 0, accuracy: 0.001)
        // 长度不变。
        let len = hypot(rotated.end.x - rotated.start.x, rotated.end.y - rotated.start.y)
        XCTAssertEqual(len, 20, accuracy: 0.001)
    }

    // MARK: - ArrowAnnotation

    func test_arrowAnnotation_curveHandlePoint_defaultsToMid() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let handle = arrow.curveHandlePoint
        XCTAssertEqual(handle.x, 50, accuracy: 0.001)
        XCTAssertEqual(handle.y, 0, accuracy: 0.001)
    }

    func test_arrowAnnotation_withControlPoint_setsCurve() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0))
        let curved = arrow.withControlPoint(CGPoint(x: 50, y: 50))
        XCTAssertEqual(curved.controlPoint, CGPoint(x: 50, y: 50))
    }

    func test_arrowAnnotation_translated_shiftsAllPoints() {
        let arrow = ArrowAnnotation(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), controlPoint: CGPoint(x: 50, y: 50))
        let moved = arrow.translated(by: CGPoint(x: 10, y: 20)) as! ArrowAnnotation
        XCTAssertEqual(moved.start, CGPoint(x: 10, y: 20))
        XCTAssertEqual(moved.end, CGPoint(x: 110, y: 20))
        XCTAssertEqual(moved.controlPoint, CGPoint(x: 60, y: 70))
    }

    // MARK: - NumberAnnotation

    func test_numberAnnotation_hasArrow_onlyWhenTipBeyondMinDistance() {
        let badge = NumberAnnotation(center: CGPoint(x: 0, y: 0), number: 1, color: .red)
        XCTAssertFalse(badge.hasArrow)
        // tip 距 center = 1（小于 arrowMinDistance = radius+6 = 20）。
        let tooClose = NumberAnnotation(center: CGPoint(x: 0, y: 0), number: 1, color: .red, tip: CGPoint(x: 1, y: 0))
        XCTAssertFalse(tooClose.hasArrow)
        // tip 距 center = 100。
        let far = NumberAnnotation(center: CGPoint(x: 0, y: 0), number: 1, color: .red, tip: CGPoint(x: 100, y: 0))
        XCTAssertTrue(far.hasArrow)
    }

    func test_numberAnnotation_contrastingTextColor_darkBadgeWhiteText() {
        let textColor = NumberAnnotation.contrastingTextColor(for: .black)
        XCTAssertEqual(textColor, .white)
        let onWhite = NumberAnnotation.contrastingTextColor(for: .white)
        XCTAssertEqual(onWhite, .black)
    }

    func test_numberAnnotation_containsBadgeCircle() {
        let badge = NumberAnnotation(center: CGPoint(x: 50, y: 50), number: 1, color: .red)
        XCTAssertTrue(badge.containsPoint(CGPoint(x: 50, y: 50)))
        XCTAssertTrue(badge.containsPoint(CGPoint(x: 50, y: 60))) // 距 10 < radius 14
    }

    func test_numberAnnotation_withNumber_changesNumber() {
        let badge = NumberAnnotation(center: CGPoint(x: 0, y: 0), number: 1, color: .red)
        XCTAssertEqual(badge.withNumber(5).number, 5)
    }

    // MARK: - MagnifierAnnotation

    func test_magnifierAnnotation_effectiveSourceCenter_defaultsToCenter() {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let lens = MagnifierAnnotation(center: CGPoint(x: 50, y: 50), radius: 30, color: .red, lineWidth: 2, zoom: 2, sourceImage: image)
        XCTAssertEqual(lens.effectiveSourceCenter, CGPoint(x: 50, y: 50))
    }

    func test_magnifierAnnotation_withZoom_clampsToRange() {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let lens = MagnifierAnnotation(center: CGPoint(x: 50, y: 50), radius: 30, color: .red, lineWidth: 2, zoom: 2, sourceImage: image)
        XCTAssertEqual(lens.withZoom(100).zoom, MagnifierAnnotation.maxZoom)
        XCTAssertEqual(lens.withZoom(0).zoom, MagnifierAnnotation.minZoom)
    }

    func test_magnifierAnnotation_containsLensCircle() {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let lens = MagnifierAnnotation(center: CGPoint(x: 50, y: 50), radius: 30, color: .red, lineWidth: 2, zoom: 2, sourceImage: image)
        XCTAssertTrue(lens.containsPoint(CGPoint(x: 50, y: 50)))
        XCTAssertTrue(lens.containsPoint(CGPoint(x: 70, y: 50))) // 距 20 < 30
        XCTAssertFalse(lens.containsPoint(CGPoint(x: 90, y: 50))) // 距 40 > 30
    }

    // MARK: - MosaicTool

    func test_mosaicTool_returnsNilForZeroSizeRect() {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        let region = MosaicTool.createMosaicRegion(rect: NSRect(x: 0, y: 0, width: 0, height: 0), imageSize: NSSize(width: 100, height: 100), baseImage: image)
        XCTAssertNil(region)
    }

    // MARK: - TextAnnotation

    func test_textAnnotation_strokeColor_contrasts() {
        // 白色填充应配黑色描边。
        XCTAssertEqual(TextAnnotation.strokeColor(for: .white), .black)
        // 黑色填充应配白色描边。
        XCTAssertEqual(TextAnnotation.strokeColor(for: .black), .white)
    }

    func test_textAnnotation_withCallout_enablesBubble() {
        let text = TextAnnotation(text: "hi", origin: CGPoint(x: 10, y: 10))
        XCTAssertFalse(text.hasCallout)
        XCTAssertTrue(text.withCallout(true).hasCallout)
    }

    func test_textAnnotation_lines_splitsNewlines() {
        XCTAssertEqual(TextAnnotation.lines(for: "a\nb\nc"), ["a", "b", "c"])
        XCTAssertEqual(TextAnnotation.lines(for: "a\r\nb"), ["a", "b"])
    }

    // MARK: - ImageAnnotation / EmojiAnnotation

    func test_imageAnnotation_containsRectInflated() {
        let image = NSImage(size: NSSize(width: 40, height: 40))
        let annotation = ImageAnnotation(image: image, rect: NSRect(x: 10, y: 10, width: 40, height: 40))
        // insetBy(dx: -8) 扩展命中区到 (2,2,56,56)。
        XCTAssertTrue(annotation.containsPoint(CGPoint(x: 5, y: 5)))
    }

    func test_emojiAnnotation_withRect_changesRect() {
        let annotation = EmojiAnnotation(emoji: "😀", rect: NSRect(x: 0, y: 0, width: 44, height: 44))
        let resized = annotation.withRect(NSRect(x: 10, y: 10, width: 60, height: 60))
        XCTAssertEqual(resized.rect.width, 60)
    }
}
