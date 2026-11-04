import AppKit
import XCTest
@testable import OmniForge

/// 选区阶段顶部提示的可见性、落点与绘制回归。
/// 提示只在未开始拖动、未进入编辑器、有文案时出现；顶部落点要避开菜单栏与刘海。
@MainActor
final class SelectionViewHintTests: XCTestCase {
    private var view: SelectionView!
    private let viewFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let hintText = "拖动选择区域"

    override func setUp() {
        super.setUp()
        view = SelectionView(frame: viewFrame)
        view.screenFrameProvider = { self.viewFrame }
        view.visibleFrameProvider = { NSRect(x: 0, y: 0, width: 1000, height: 775) }
        view.safeAreaTopInsetProvider = { 0 }
    }

    override func tearDown() {
        view = nil
        super.tearDown()
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func render(_ view: SelectionView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Int {
        var pixel = [Int](repeating: 0, count: 4)
        rep.getPixel(&pixel, atX: x, y: y)
        return pixel[3]
    }

    // MARK: - 可见性

    func test_空闲态有文案时可见() {
        view.hintText = hintText
        XCTAssertTrue(view.isHintVisible)
    }

    func test_无文案时不可见() {
        XCTAssertFalse(view.isHintVisible)
        view.hintText = ""
        XCTAssertFalse(view.isHintVisible)
    }

    func test_按下但未拖动时仍可见() {
        // 规格 4.2：按下鼠标但未超过拖拽阈值，仍视为未开始。
        view.hintText = hintText
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100)))
        XCTAssertTrue(view.isHintVisible)
    }

    func test_开始拖拽后不可见() {
        view.hintText = hintText
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100)))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: 260, y: 240)))
        XCTAssertFalse(view.isHintVisible)
    }

    func test_选区锁定后不可见() {
        view.hintText = hintText
        view.selectionLocked = true
        XCTAssertFalse(view.isHintVisible)
    }

    // MARK: - 落点

    func test_菜单栏常显时位于可见区顶部下方() {
        // frame 顶部 900、可见区顶部 875（菜单栏 25pt）、无刘海：875 - 28 = 847。
        XCTAssertEqual(
            SelectionView.hintTopY(
                screenFrameMaxY: 900,
                screenFrameMinY: 0,
                visibleFrameMaxY: 875,
                safeAreaTopInset: 0
            ),
            847
        )
    }

    func test_自动隐藏菜单栏时改用刘海安全区避让() {
        // 自动隐藏菜单栏：visibleFrame 等于 frame，必须退化到刘海安全区 32pt。
        XCTAssertEqual(
            SelectionView.hintTopY(
                screenFrameMaxY: 900,
                screenFrameMinY: 0,
                visibleFrameMaxY: 900,
                safeAreaTopInset: 32
            ),
            840
        )
    }

    func test_副屏负minY换算正确() {
        // 副屏 frame [-900, 0]、菜单栏 25pt：0 - (-900) - 25 - 28 = 847。
        XCTAssertEqual(
            SelectionView.hintTopY(
                screenFrameMaxY: 0,
                screenFrameMinY: -900,
                visibleFrameMaxY: -25,
                safeAreaTopInset: 0
            ),
            847
        )
    }

    // MARK: - 绘制

    func test_有提示时顶部胶囊带绘制暗色且渲染结果不同() throws {
        view.hintText = nil
        let empty = try render(view)
        view.hintText = hintText
        let withHint = try render(view)

        XCTAssertNotEqual(
            empty.tiffRepresentation,
            withHint.tiffRepresentation,
            "有提示时渲染结果必须变化，否则提示没有被绘制"
        )

        // 落点与绘制同源计算：菜单栏 25pt + 顶部内缩 28pt（bitmap 行 0 在顶部）。
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (hintText as NSString).size(withAttributes: attributes)
        let capsuleHeight = textSize.height + 16
        let capsuleWidth = textSize.width + 28
        let topY = SelectionView.hintTopY(
            screenFrameMaxY: viewFrame.maxY,
            screenFrameMinY: viewFrame.minY,
            visibleFrameMaxY: 775,
            safeAreaTopInset: 0
        )
        let centerY = topY - capsuleHeight / 2
        // 取左侧内边距区（避开文字）验证胶囊底确实绘制。
        let leftPaddingX = viewFrame.width / 2 - capsuleWidth / 2 + 4

        // bitmap 可能按 backing scale 放大，行/列需同比例换算。
        let scale = CGFloat(withHint.pixelsHigh) / viewFrame.height
        let sampleX = Int(leftPaddingX * scale)
        let sampleY = Int((viewFrame.height - centerY) * scale)

        // 无选区时视图已铺 0.45 暗罩（alpha≈115）；胶囊底 0.72 叠加后应接近不透明。
        XCTAssertGreaterThan(alpha(withHint, x: sampleX, y: sampleY), 200)
        XCTAssertLessThan(
            alpha(empty, x: sampleX, y: sampleY),
            alpha(withHint, x: sampleX, y: sampleY) - 60
        )
    }
}
