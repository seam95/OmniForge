import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class AnnotationToolbarLayoutTests: XCTestCase {
    func test_layout_isSingleHorizontalRowWithSeparatorAndActions() {
        let items = AnnotationToolbarLayout.primary
        XCTAssertFalse(items.contains(.image))
        XCTAssertEqual(items.last, .confirm)
        XCTAssertEqual(Array(items.suffix(5)), [.separator, .save, .pin, .close, .confirm])
        XCTAssertTrue(items.contains(.moveSelection))
        XCTAssertTrue(items.contains(.scrollCapture))
        XCTAssertTrue(items.contains(.record))
        // 分隔应在 undo/redo 之后、动作区之前。
        guard let sepIdx = items.firstIndex(of: .separator),
              let undoIdx = items.firstIndex(of: .undo),
              let redoIdx = items.firstIndex(of: .redo),
              let saveIdx = items.firstIndex(of: .save) else {
            return XCTFail("missing separator/undo/redo/save")
        }
        XCTAssertLessThan(undoIdx, sepIdx)
        XCTAssertLessThan(redoIdx, sepIdx)
        XCTAssertLessThan(sepIdx, saveIdx)
    }

    func test_toolbarView_preferredWidth_accountsForSeparator() {
        let toolsOnly = AnnotationToolbarView(items: [.undo, .redo], orientation: .horizontal)
        let withSep = AnnotationToolbarView(
            items: [.undo, .redo, .separator, .save, .pin, .close, .confirm],
            orientation: .horizontal
        )
        XCTAssertGreaterThan(withSep.preferredSize.width, toolsOnly.preferredSize.width)
        // 动作四项 + 分隔宽应明显大于仅多 4 个按钮间距的量级。
        let expectedMinExtra =
            4 * AnnotationToolbarView.buttonSize
            + 4 * AnnotationToolbarView.buttonSpacing
            + 1
        XCTAssertGreaterThanOrEqual(
            withSep.preferredSize.width - toolsOnly.preferredSize.width,
            expectedMinExtra - 0.5
        )
    }

    func test_toolbarView_doesNotCreateButtonForSeparator() {
        let view = AnnotationToolbarView(
            items: [.undo, .separator, .confirm],
            orientation: .horizontal
        )
        XCTAssertTrue(view.contains(.undo))
        XCTAssertTrue(view.contains(.confirm))
        XCTAssertFalse(view.contains(.separator))
        XCTAssertNil(view.frame(for: .separator))
    }

    func test_textSubToolbar_preferredWidthContainsAllControlsForEnglishLabels() {
        let strokeLabel = "Outline"
        let calloutLabel = "Fill"
        let width = TextSubToolbar.preferredWidth(
            strokeLabel: strokeLabel,
            calloutLabel: calloutLabel
        )
        let toolbar = TextSubToolbar(
            frame: NSRect(x: 0, y: 0, width: width, height: 44),
            currentColor: EditorStyleDefaults.primaryColor,
            currentFontSize: EditorStyleDefaults.fontSize,
            strokeEnabled: false,
            calloutEnabled: false,
            strokeLabel: strokeLabel,
            calloutLabel: calloutLabel
        )

        XCTAssertTrue(toolbar.subviews.allSatisfy { $0.frame.maxX <= toolbar.bounds.maxX })
    }

    func test_textSubToolbar_preferredWidthExpandsForLongerLocalizedLabels() {
        let shortWidth = TextSubToolbar.preferredWidth(strokeLabel: "A", calloutLabel: "B")
        let longWidth = TextSubToolbar.preferredWidth(
            strokeLabel: "Longer Outline Label",
            calloutLabel: "Longer Fill Label"
        )

        XCTAssertGreaterThan(longWidth, shortWidth)
    }
}
