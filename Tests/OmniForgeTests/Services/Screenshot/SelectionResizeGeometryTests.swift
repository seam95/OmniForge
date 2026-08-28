import AppKit
import XCTest
@testable import OmniForge

/// `SelectionView.resizedRect` 的几何回归：8 个手柄各自只移动所在边，
/// 对面边固定不动。此前 y 方向锚定边写反（按上中会把底线拉上来），
/// 本组用例逐方向锁定「移动边跟随 + 固定边不动 + 拖过头贴固定边」三要素。
final class SelectionResizeGeometryTests: XCTestCase {
    /// 基准选区：minX=50 minY=50 maxX=130 maxY=110（AppKit 非 flipped，y 向上）。
    private let original = NSRect(x: 50, y: 50, width: 80, height: 60)
    private let minSize: CGFloat = 5

    private struct Case {
        let name: String
        let handle: SelectionView.HandlePosition
        let point: NSPoint
        let expected: CGRect
    }

    /// 正常拖动：手柄所在边跟随鼠标，对面边与正交方向均不变。
    private let normalCases: [Case] = [
        // 上中：顶边跟随（maxY=90），底边 minY=50 固定
        Case(name: "topCenter", handle: .topCenter, point: NSPoint(x: 90, y: 90),
             expected: CGRect(x: 50, y: 50, width: 80, height: 40)),
        // 下中：底边跟随（minY=80），顶边 maxY=110 固定
        Case(name: "bottomCenter", handle: .bottomCenter, point: NSPoint(x: 90, y: 80),
             expected: CGRect(x: 50, y: 80, width: 80, height: 30)),
        // 左中：左边跟随（minX=70），右边 maxX=130 固定
        Case(name: "leftCenter", handle: .leftCenter, point: NSPoint(x: 70, y: 55),
             expected: CGRect(x: 70, y: 50, width: 60, height: 60)),
        // 右中：右边跟随（maxX=100），左边 minX=50 固定
        Case(name: "rightCenter", handle: .rightCenter, point: NSPoint(x: 100, y: 55),
             expected: CGRect(x: 50, y: 50, width: 50, height: 60)),
        // 左上：左边、顶边跟随；右边、底边固定
        Case(name: "topLeft", handle: .topLeft, point: NSPoint(x: 70, y: 90),
             expected: CGRect(x: 70, y: 50, width: 60, height: 40)),
        // 右上：右边、顶边跟随；左边、底边固定
        Case(name: "topRight", handle: .topRight, point: NSPoint(x: 100, y: 85),
             expected: CGRect(x: 50, y: 50, width: 50, height: 35)),
        // 左下：左边、底边跟随；右边、顶边固定
        Case(name: "bottomLeft", handle: .bottomLeft, point: NSPoint(x: 60, y: 70),
             expected: CGRect(x: 60, y: 70, width: 70, height: 40)),
        // 右下：右边、底边跟随；左边、顶边固定
        Case(name: "bottomRight", handle: .bottomRight, point: NSPoint(x: 120, y: 75),
             expected: CGRect(x: 50, y: 75, width: 70, height: 35)),
    ]

    func test_resizedRect_normalDrag_movesOwnEdgeKeepsOppositeFixed() {
        for c in normalCases {
            let rect = SelectionView.resizedRect(
                from: original, handle: c.handle, to: c.point, minSize: minSize
            )
            XCTAssertEqual(rect.minX, c.expected.minX, accuracy: 0.5, "[\(c.name)] minX")
            XCTAssertEqual(rect.minY, c.expected.minY, accuracy: 0.5, "[\(c.name)] minY")
            XCTAssertEqual(rect.maxX, c.expected.maxX, accuracy: 0.5, "[\(c.name)] maxX")
            XCTAssertEqual(rect.maxY, c.expected.maxY, accuracy: 0.5, "[\(c.name)] maxY")
        }
    }

    /// 拖动越过对面边：贴固定边内侧压缩到 minSize，固定边坐标不变、不翻转。
    private let overshootCases: [Case] = [
        // 上中向上拖过底边：贴底边（minY=50 固定），高 5
        Case(name: "topCenter overshoot up", handle: .topCenter, point: NSPoint(x: 90, y: 20),
             expected: CGRect(x: 50, y: 50, width: 80, height: 5)),
        // 下中向下拖过顶边：贴顶边（maxY=110 固定），高 5
        Case(name: "bottomCenter overshoot down", handle: .bottomCenter, point: NSPoint(x: 90, y: 200),
             expected: CGRect(x: 50, y: 105, width: 80, height: 5)),
        // 左中向右拖过右边：贴右边（maxX=130 固定），宽 5
        Case(name: "leftCenter overshoot right", handle: .leftCenter, point: NSPoint(x: 200, y: 55),
             expected: CGRect(x: 125, y: 50, width: 5, height: 60)),
        // 右中向左拖过左边：贴左边（minX=50 固定），宽 5
        Case(name: "rightCenter overshoot left", handle: .rightCenter, point: NSPoint(x: 10, y: 55),
             expected: CGRect(x: 50, y: 50, width: 5, height: 60)),
    ]

    func test_resizedRect_overshoot_clampsToMinSizeAlongFixedEdge() {
        for c in overshootCases {
            let rect = SelectionView.resizedRect(
                from: original, handle: c.handle, to: c.point, minSize: minSize
            )
            XCTAssertEqual(rect.minX, c.expected.minX, accuracy: 0.5, "[\(c.name)] minX")
            XCTAssertEqual(rect.minY, c.expected.minY, accuracy: 0.5, "[\(c.name)] minY")
            XCTAssertEqual(rect.maxX, c.expected.maxX, accuracy: 0.5, "[\(c.name)] maxX")
            XCTAssertEqual(rect.maxY, c.expected.maxY, accuracy: 0.5, "[\(c.name)] maxY")
        }
    }
}
