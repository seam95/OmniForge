import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 光标气泡定位契约：垂直上方悬挂 / 顶部翻转到下方，水平左/中/右三档防出界。
final class CursorBubbleLocatorTests: XCTestCase {

    private let size = CGSize(width: 300, height: 200)

    // MARK: - 垂直：上方悬挂

    func test_anchor_hangsAboveCursorByDefault() {
        let placed = CursorBubbleLocator.anchor(location: CGPoint(x: 150, y: 120), in: size)
        XCTAssertEqual(placed.anchor.x, 150)
        XCTAssertEqual(placed.anchor.y, 120 - CursorBubbleLocator.gap, accuracy: 0.01)
        XCTAssertEqual(placed.alignment, Alignment(horizontal: .center, vertical: .bottom))
    }

    func test_anchor_flipsBelowCursorNearTop() {
        // 顶部空间放不下预估气泡（36 + 12 = 48 阈值之下）→ 翻到光标下方
        let placed = CursorBubbleLocator.anchor(location: CGPoint(x: 150, y: 20), in: size)
        XCTAssertEqual(placed.anchor.y, 20 + CursorBubbleLocator.gap, accuracy: 0.01)
        XCTAssertEqual(placed.alignment, Alignment(horizontal: .center, vertical: .top))
    }

    func test_anchor_boundaryExactlyAtThresholdStaysAbove() {
        let y = CursorBubbleLocator.estimatedBubbleHeight + CursorBubbleLocator.gap
        let placed = CursorBubbleLocator.anchor(location: CGPoint(x: 150, y: y), in: size)
        XCTAssertEqual(placed.alignment, Alignment(horizontal: .center, vertical: .bottom))
    }

    // MARK: - 水平三档

    func test_anchor_leadsOnLeftThird() {
        let placed = CursorBubbleLocator.anchor(location: CGPoint(x: 50, y: 120), in: size)
        XCTAssertEqual(placed.alignment, Alignment(horizontal: .leading, vertical: .bottom))
    }

    func test_anchor_trailsOnRightThird() {
        let placed = CursorBubbleLocator.anchor(location: CGPoint(x: 250, y: 120), in: size)
        XCTAssertEqual(placed.alignment, Alignment(horizontal: .trailing, vertical: .bottom))
    }

    func test_anchor_customParametersRespected() {
        let placed = CursorBubbleLocator.anchor(
            location: CGPoint(x: 150, y: 40),
            in: size,
            gap: 8,
            estimatedBubbleHeight: 20
        )
        // 40 > 20 + 8 → 仍上方悬挂，间距用注入值
        XCTAssertEqual(placed.anchor.y, 32, accuracy: 0.01)
    }

    // MARK: - 容错

    func test_anchor_zeroSizeFallsBackToLocation() {
        let placed = CursorBubbleLocator.anchor(location: CGPoint(x: 10, y: 10), in: .zero)
        XCTAssertEqual(placed.anchor, CGPoint(x: 10, y: 10))
        XCTAssertEqual(placed.alignment, Alignment(horizontal: .center, vertical: .bottom))
    }
}

/// 锚挂组件渲染契约：alignment 悬挂语义 — .bottom 气泡整体在锚点上方、
/// .top 在锚点下方、水平档位不越过锚点（红底像素包围盒判定，验证「无需预知气泡尺寸」的悬挂）。
@MainActor
final class CursorBubbleAnchorRenderingTests: XCTestCase {

    /// 容器与锚点：200×120 红底，锚点 (100, 60)。
    private let anchorPoint = CGPoint(x: 100, y: 60)
    private let viewSize = CGSize(width: 200, height: 120)

    private func renderBubble(alignment: Alignment) throws -> NSBitmapImageRep {
        let content = ZStack {
            Color.red
            CursorBubbleAnchor(anchor: anchorPoint, alignment: alignment) {
                SparklineBubbleShell(colorScheme: .light) {
                    Text("12.3万 tokens")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: content.environment(\.colorScheme, .light))
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewSize.width), pixelsHigh: Int(viewSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = viewSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        window.orderOut(nil)
        return rep
    }

    /// 非红内容像素的包围盒（minX, maxX, minY, maxY），位图行 y=0 为顶部（与 SwiftUI 左上原点同向）。
    private func contentBoundingBox(_ rep: NSBitmapImageRep) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent * 255
                let g = color.greenComponent * 255
                let b = color.blueComponent * 255
                // 与纯红底（255,0,0）分量差异明显即内容：白底/灰描边/黑字
                if g > 60 || b > 60 || r < 180 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return (minX, maxX, minY, maxY)
    }

    func test_bottomAlignment_bubbleEntirelyAboveAnchor() throws {
        let rep = try renderBubble(alignment: Alignment(horizontal: .center, vertical: .bottom))
        let box = try XCTUnwrap(contentBoundingBox(rep), "应渲染出气泡内容")
        // 位图 y=0 顶部同向：气泡垂直中心须在锚点（60）之上
        let centerY = Double(box.minY + box.maxY) / 2
        XCTAssertLessThan(centerY, 60, ".bottom 应悬挂在锚点上方，实际包围盒 \(box)")
    }

    func test_topAlignment_bubbleEntirelyBelowAnchor() throws {
        let rep = try renderBubble(alignment: Alignment(horizontal: .center, vertical: .top))
        let box = try XCTUnwrap(contentBoundingBox(rep), "应渲染出气泡内容")
        let centerY = Double(box.minY + box.maxY) / 2
        XCTAssertGreaterThan(centerY, 60, ".top 应翻转到锚点下方，实际包围盒 \(box)")
    }

    func test_leadingAlignment_bubbleExpandsRightFromAnchor() throws {
        let rep = try renderBubble(alignment: Alignment(horizontal: .leading, vertical: .bottom))
        let box = try XCTUnwrap(contentBoundingBox(rep), "应渲染出气泡内容")
        // .leading = 气泡 leading 边贴锚点、向右展开（光标靠容器左缘时不出左界）
        XCTAssertGreaterThanOrEqual(Double(box.minX), 99, ".leading 气泡应从锚点向右展开，实际包围盒 \(box)")
    }

    func test_trailingAlignment_bubbleExpandsLeftFromAnchor() throws {
        let rep = try renderBubble(alignment: Alignment(horizontal: .trailing, vertical: .bottom))
        let box = try XCTUnwrap(contentBoundingBox(rep), "应渲染出气泡内容")
        // .trailing = 气泡 trailing 边贴锚点、向左展开（光标靠容器右缘时不出右界）
        XCTAssertLessThanOrEqual(Double(box.maxX), 101, ".trailing 气泡应从锚点向左展开，实际包围盒 \(box)")
    }
}
