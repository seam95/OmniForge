import AppKit
import XCTest
@testable import OmniForge

/// 子工具栏选项按钮（箭头/形状填充/描边样式）点击后，
/// 实际样式经回调生效的同时，按钮 UI 选中态必须同步高亮。
@MainActor
final class AnnotationSubToolbarSelectionTests: XCTestCase {

    // MARK: - 辅助

    private func miniButtons(in view: NSView) -> [MiniChoiceButton] {
        view.subviews.compactMap { $0 as? MiniChoiceButton }
    }

    /// 以与真实点击相同的 target/action 派发路径触发按钮手势。
    private func fireClick(on button: NSView) {
        guard let recognizer = button.gestureRecognizers.first,
              let target = recognizer.target,
              let action = recognizer.action else {
            return XCTFail("选项按钮缺少点击手势")
        }
        _ = target.perform(action, with: recognizer)
    }

    private func makeRectEllipseToolbar(
        fillMode: ShapeFillMode = .none,
        strokeStyle: ShapeStrokeStyle = .standard
    ) -> ColorSizeSubToolbar {
        ColorSizeSubToolbar(
            frame: NSRect(x: 0, y: 0, width: 800, height: 44),
            sizes: EditorStyleDefaults.standardLineSizes,
            currentColor: EditorStyleDefaults.primaryColor,
            currentSize: EditorStyleDefaults.standardLineWidth,
            sizeMin: EditorStyleDefaults.standardLineWidthMin,
            sizeMax: EditorStyleDefaults.standardLineWidthMax,
            shapeFillMode: fillMode,
            shapeStrokeStyle: strokeStyle
        )
    }

    // MARK: - 初始选中态

    func test_initialSelection_matchesPassedStyles() {
        let sub = makeRectEllipseToolbar(fillMode: .translucent, strokeStyle: .rounded)
        let buttons = miniButtons(in: sub)
        XCTAssertEqual(buttons.count, 6, "填充 3 项 + 描边 3 项")
        XCTAssertTrue(buttons[2].isSelected, "半透明填充初始应选中")
        XCTAssertTrue(buttons[4].isSelected, "圆角描边初始应选中")
        XCTAssertFalse(buttons[0].isSelected)
        XCTAssertFalse(buttons[3].isSelected)
    }

    // MARK: - 填充模式（实心/空心）

    func test_tapFillMode_updatesSelectedHighlight() {
        let sub = makeRectEllipseToolbar(fillMode: .none, strokeStyle: .standard)
        var received: [ShapeFillMode] = []
        sub.onShapeFillModeChanged = { received.append($0) }
        let buttons = miniButtons(in: sub)
        let fillButtons = Array(buttons.prefix(3))

        fireClick(on: fillButtons[1]) // ▣ 实心

        XCTAssertEqual(received, [.opaque], "回调应收到实心填充")
        XCTAssertTrue(fillButtons[1].isSelected, "实心按钮应高亮选中")
        XCTAssertFalse(fillButtons[0].isSelected, "空心按钮应取消选中")
        XCTAssertFalse(fillButtons[2].isSelected)
    }

    func test_tapFillModeTwice_keepsSelectionStable() {
        let sub = makeRectEllipseToolbar(fillMode: .none, strokeStyle: .standard)
        let fillButtons = Array(miniButtons(in: sub).prefix(3))

        fireClick(on: fillButtons[2])
        fireClick(on: fillButtons[2])

        XCTAssertTrue(fillButtons[2].isSelected, "重复点击同一项应保持选中")
    }

    // MARK: - 描边样式（边角弧度）

    func test_tapStrokeStyle_updatesSelectedHighlight() {
        let sub = makeRectEllipseToolbar(fillMode: .none, strokeStyle: .standard)
        var received: [ShapeStrokeStyle] = []
        sub.onShapeStrokeStyleChanged = { received.append($0) }
        let buttons = miniButtons(in: sub)
        let strokeButtons = Array(buttons.suffix(3))

        fireClick(on: strokeButtons[1]) // ◜ 圆角

        XCTAssertEqual(received, [.rounded], "回调应收到圆角描边")
        XCTAssertTrue(strokeButtons[1].isSelected, "圆角按钮应高亮选中")
        XCTAssertFalse(strokeButtons[0].isSelected, "标准描边应取消选中")
        XCTAssertFalse(strokeButtons[2].isSelected)
        XCTAssertTrue(buttons[0].isSelected, "填充区选中态不应被误改")
    }

    // MARK: - 箭头样式

    func test_tapArrowStyle_updatesSelectedHighlight() {
        let sub = ColorSizeSubToolbar(
            frame: NSRect(x: 0, y: 0, width: 800, height: 44),
            sizes: EditorStyleDefaults.standardLineSizes,
            currentColor: EditorStyleDefaults.primaryColor,
            currentSize: EditorStyleDefaults.standardLineWidth,
            sizeMin: EditorStyleDefaults.standardLineWidthMin,
            sizeMax: EditorStyleDefaults.standardLineWidthMax,
            arrowStyle: .tapered
        )
        var received: [ArrowStyle] = []
        sub.onArrowStyleChanged = { received.append($0) }
        let buttons = miniButtons(in: sub)
        XCTAssertEqual(buttons.count, 4)
        XCTAssertTrue(buttons[0].isSelected, "初始 tapered 应选中")

        fireClick(on: buttons[2]) // → 细线箭头

        XCTAssertEqual(received, [.line])
        XCTAssertTrue(buttons[2].isSelected, "被点击的箭头样式应高亮")
        XCTAssertFalse(buttons[0].isSelected, "旧箭头样式应取消选中")
    }

    // MARK: - 宽度估值

    func test_preferredWidth_accountsForAllShapeSectionButtons() {
        let base = ColorSizeSubToolbar.preferredWidth(
            sizes: EditorStyleDefaults.standardLineSizes,
            dynamicColor: nil
        )
        // 区段实际布局：分隔 6 + 1 + 8 + 3 按钮 × 27 + 2 间距 × 4。
        let buttonsWidth: CGFloat = 3 * 27 + 2 * 4
        let sectionWidth: CGFloat = 6 + 1 + 8 + buttonsWidth

        let withFill = ColorSizeSubToolbar.preferredWidth(
            sizes: EditorStyleDefaults.standardLineSizes,
            dynamicColor: nil,
            showsShapeFill: true
        )
        XCTAssertEqual(withFill - base, sectionWidth, "填充区宽度应覆盖全部 3 个按钮")

        let withStroke = ColorSizeSubToolbar.preferredWidth(
            sizes: EditorStyleDefaults.standardLineSizes,
            dynamicColor: nil,
            showsShapeStroke: true
        )
        XCTAssertEqual(withStroke - base, sectionWidth, "描边区宽度应覆盖全部 3 个按钮")
    }
}
