import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class SelectionViewSnapTests: XCTestCase {
    private var selectionView: SelectionView!
    private var delegate: RecordingSelectionDelegate!
    private let viewFrame = NSRect(x: 0, y: 0, width: 1000, height: 800)

    override func setUp() {
        super.setUp()
        selectionView = SelectionView(frame: viewFrame)
        delegate = RecordingSelectionDelegate()
        selectionView.delegate = delegate
        // SelectionView 在测试中无 window，注入固定屏 frame 供坐标转换。
        selectionView.screenFrameProvider = { self.viewFrame }
        // visibleFrame 退化为整屏（本测试套件不测边缘条带，直接喂普通候选）。
        selectionView.visibleFrameProvider = { self.viewFrame }
    }

    override func tearDown() {
        selectionView = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - trackingArea（跨屏非 key 窗口仍收 mouseMoved）

    func test_updateTrackingAreas安装activeAlways与mouseMoved() {
        selectionView.updateTrackingAreas()
        let area = selectionView.trackingAreas.first
        XCTAssertNotNil(area)
        guard let options = area?.options else {
            return XCTFail("missing tracking area")
        }
        XCTAssertTrue(options.contains(.activeAlways))
        XCTAssertTrue(options.contains(.mouseMoved))
        XCTAssertTrue(options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(options.contains(.inVisibleRect))
    }

    func test_mouseExited清除hoverRect() async {
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = SnapCandidate(
            rect: NSRect(x: 100, y: 100, width: 200, height: 150),
            windowID: nil
        )
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        XCTAssertNotNil(selectionView.hoverRectForTesting)

        // mouseExited 需 enterExitEvent；mouseEvent 不支持 .mouseExited 会 abort。
        let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: NSPoint(x: -1, y: -1),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
        selectionView.mouseExited(with: exitEvent)
        XCTAssertNil(selectionView.hoverRectForTesting)
    }

    // MARK: - mouseMoved / hover

    func test_mouseMoved有候选时更新hoverRect() async {
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = SnapCandidate(
            rect: NSRect(x: 100, y: 100, width: 200, height: 150),
            windowID: nil
        )
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 200, y: 200))
        await flushAsync()

        XCTAssertEqual(selectionView.hoverRectForTesting?.width, 200)
        XCTAssertEqual(selectionView.hoverRectForTesting?.height, 150)
    }

    func test_mouseMoved候选不包含鼠标点时不采用() async {
        // 候选 rect 不包含触发的鼠标点 → 回填校验失败 → hoverRect 清空。
        // 防止鼠标已移出但旧查询回填导致高亮残留。
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = SnapCandidate(
            rect: NSRect(x: 0, y: 0, width: 50, height: 50),  // 不包含 (200,200)
            windowID: nil
        )
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 200, y: 200))
        await flushAsync()

        XCTAssertNil(selectionView.hoverRectForTesting)
    }

    func test_mouseMoved无候选时hoverRect为nil() async {
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = nil
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 500, y: 500))
        await flushAsync()

        XCTAssertNil(selectionView.hoverRectForTesting)
    }

    func test_无provider时不查询() async {
        // snapProvider 为 nil：mouseMoved 直接返回，不触发任何查询。
        fireMouseMoved(at: NSPoint(x: 200, y: 200))
        await flushAsync()

        XCTAssertNil(selectionView.hoverRectForTesting)
    }

    func test_编辑器模式禁用吸附() async {
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = SnapCandidate(
            rect: NSRect(x: 100, y: 100, width: 200, height: 150),
            windowID: nil
        )
        selectionView.snapProvider = provider
        // 进入编辑器后 selectionLocked=true，不再做窗口吸附 hover。
        selectionView.selectionLocked = true

        fireMouseMoved(at: NSPoint(x: 200, y: 200))
        await flushAsync()

        XCTAssertNil(selectionView.hoverRectForTesting)
        XCTAssertNil(provider.lastQueryPoint)  // 根本没调 provider
    }

    func test_hover仅在idle态进行() async {
        // 已有选区（selected 态）时，mouseMoved 不应再查 hover（hoverRect 保持 nil）。
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = SnapCandidate(
            rect: NSRect(x: 100, y: 100, width: 200, height: 150),
            windowID: nil
        )
        selectionView.snapProvider = provider

        // 先 mouseDown 在无 hover 处画一个选区 → 进 selected
        fireMouseDown(at: NSPoint(x: 100, y: 100))
        fireMouseDragged(at: NSPoint(x: 300, y: 300))
        fireMouseUp(at: NSPoint(x: 300, y: 300))
        XCTAssertTrue(delegate.completedCalled)  // 已进 selected

        fireMouseMoved(at: NSPoint(x: 500, y: 500))
        await flushAsync()

        // selected 态 mouseMoved 不触发 hover 查询，hoverRect 保持 nil
        XCTAssertNil(selectionView.hoverRectForTesting)
    }

    // MARK: - 元素级细化（整窗高亮后移动应能落到内部控件）

    func test_鼠标在hoverRect内移动仍重新查询以细化元素() async {
        // 首次可能命中整窗；在窗内移动必须继续查询，才能落到按钮等内部控件。
        // 防抖只保留「同 rect 不重绘」，不再跳过查询。
        let provider = FakeSnapProvider()
        let windowRect = NSRect(x: 100, y: 100, width: 400, height: 300)
        provider.stubbedCandidate = SnapCandidate(rect: windowRect, windowID: nil)
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        XCTAssertEqual(selectionView.hoverRectForTesting, windowRect)
        let firstQueryPoint = provider.lastQueryPoint
        XCTAssertNotNil(firstQueryPoint)

        let buttonRect = NSRect(x: 180, y: 180, width: 80, height: 30)
        provider.stubbedCandidate = SnapCandidate(rect: buttonRect, windowID: nil)
        fireMouseMoved(at: NSPoint(x: 200, y: 200))
        await flushAsync()
        XCTAssertNotEqual(provider.lastQueryPoint, firstQueryPoint)
        XCTAssertEqual(selectionView.hoverRectForTesting, buttonRect)
    }

    func test_鼠标移出后重新查询() async {
        let provider = FakeSnapProvider()
        let hoverRect = NSRect(x: 100, y: 100, width: 200, height: 150)
        provider.stubbedCandidate = SnapCandidate(rect: hoverRect, windowID: nil)
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        let firstQueryPoint = provider.lastQueryPoint

        fireMouseMoved(at: NSPoint(x: 400, y: 400))
        await flushAsync()
        XCTAssertNotEqual(provider.lastQueryPoint, firstQueryPoint)
    }

    func test_候选rect不变时不触发重绘() async {
        // 去抖：连续两次查询返回相同 rect，第二次不应触发额外重绘开销
        // （通过 hoverRect 值稳定间接验证——同 rect 不重复设置）。
        let provider = FakeSnapProvider()
        let hoverRect = NSRect(x: 100, y: 100, width: 200, height: 150)
        provider.stubbedCandidate = SnapCandidate(rect: hoverRect, windowID: nil)
        selectionView.snapProvider = provider

        // 移出再移回，触发两次查询（都返回同 rect）
        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        XCTAssertEqual(selectionView.hoverRectForTesting, hoverRect)

        // 移出 → 移回（两次 mouseMoved，第二次因粘性不会查询，
        // 但移出那次的查询回填同 rect，hoverRect 应保持不变且无异常）
        fireMouseMoved(at: NSPoint(x: 500, y: 500))  // 移出 → 查询 → 候选仍含此点? 否(500,500不在hoverRect)
        await flushAsync()
        // (500,500) 不在 hoverRect 内，provider 返回同候选但 candidate.rect 不含 (500,500) → 清 hover
        XCTAssertNil(selectionView.hoverRectForTesting)
    }

    // MARK: - pending 机制（参照 capcap）

    func test_mouseDown命中hover存pending清hover() async {
        let provider = FakeSnapProvider()
        let hoverRect = NSRect(x: 100, y: 100, width: 200, height: 150)
        provider.stubbedCandidate = SnapCandidate(rect: hoverRect, windowID: 42)
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        XCTAssertNotNil(selectionView.hoverRectForTesting)

        // 按下：hover 转为 pending，hover 显示清空
        fireMouseDown(at: NSPoint(x: 150, y: 150))

        XCTAssertNil(selectionView.hoverRectForTesting)  // hover 已清
        XCTAssertEqual(selectionView.pendingRectForTesting, hoverRect)  // pending 已存
    }

    func test_阈值内拖拽不更新selectionRect() async {
        let provider = FakeSnapProvider()
        let hoverRect = NSRect(x: 100, y: 100, width: 200, height: 150)
        provider.stubbedCandidate = SnapCandidate(rect: hoverRect, windowID: nil)
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        fireMouseDown(at: NSPoint(x: 150, y: 150))

        // 阈值内（位移 2 < windowClickThreshold 4）拖拽：selectionRect 不更新
        fireMouseDragged(at: NSPoint(x: 152, y: 152))
        XCTAssertNotNil(selectionView.pendingRectForTesting)  // pending 仍在
        // selectionRect 保持 mouseDown 时设的零尺寸起点（未被 dragRect 更新成框）
        let sel = selectionView.currentSelectionRect
        XCTAssertEqual(sel?.width, 0)
        XCTAssertEqual(sel?.height, 0)
    }

    func test_超阈值拖拽丢弃pending走自由框选() async {
        let provider = FakeSnapProvider()
        let hoverRect = NSRect(x: 100, y: 100, width: 200, height: 150)
        provider.stubbedCandidate = SnapCandidate(rect: hoverRect, windowID: nil)
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        fireMouseDown(at: NSPoint(x: 150, y: 150))

        // 超阈值拖拽（位移 10 > 4）：丢弃 pending，走自由框选
        fireMouseDragged(at: NSPoint(x: 160, y: 160))
        XCTAssertNil(selectionView.pendingRectForTesting)  // pending 已丢弃
        XCTAssertNotNil(selectionView.currentSelectionRect)  // 已开始画框选
    }

    func test_mouseUp持有pending时确认为选区() async {
        let provider = FakeSnapProvider()
        let hoverRect = NSRect(x: 100, y: 100, width: 200, height: 150)
        provider.stubbedCandidate = SnapCandidate(rect: hoverRect, windowID: 42)
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        fireMouseDown(at: NSPoint(x: 150, y: 150))
        // 阈值内微小移动后松开 → 确认 pending
        fireMouseDragged(at: NSPoint(x: 151, y: 151))
        fireMouseUp(at: NSPoint(x: 151, y: 151))

        XCTAssertTrue(delegate.completedCalled)
        XCTAssertEqual(delegate.completedRect, hoverRect)
        XCTAssertNil(selectionView.pendingRectForTesting)  // 确认后清空
    }

    func test_超阈值拖拽后mouseUp按框选收尾() async {
        let provider = FakeSnapProvider()
        provider.stubbedCandidate = SnapCandidate(
            rect: NSRect(x: 100, y: 100, width: 200, height: 150),
            windowID: nil
        )
        selectionView.snapProvider = provider

        fireMouseMoved(at: NSPoint(x: 150, y: 150))
        await flushAsync()
        fireMouseDown(at: NSPoint(x: 150, y: 150))
        // 超阈值拖拽出一个大框 → mouseUp 按框选确认（不是 pending）
        fireMouseDragged(at: NSPoint(x: 500, y: 500))
        fireMouseUp(at: NSPoint(x: 500, y: 500))

        XCTAssertTrue(delegate.completedCalled)
        // 框选矩形应是 (150,150)-(500,500)，而非原 hover rect
        let completed = delegate.completedRect!
        XCTAssertEqual(completed.minX, 150)
        XCTAssertEqual(completed.minY, 150)
        XCTAssertEqual(completed.width, 350, accuracy: 0.001)
        XCTAssertEqual(completed.height, 350, accuracy: 0.001)
    }

    // MARK: - Helpers

    /// 等待 updateHover 内的 async Task 完成。
    private func flushAsync() async {
        for _ in 0..<5 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func fireMouseMoved(at point: NSPoint) {
        selectionView.mouseMoved(with: makeEvent(type: .mouseMoved, at: point))
    }

    private func fireMouseDown(at point: NSPoint) {
        selectionView.mouseDown(with: makeEvent(type: .leftMouseDown, at: point))
    }

    private func fireMouseDragged(at point: NSPoint) {
        selectionView.mouseDragged(with: makeEvent(type: .leftMouseDragged, at: point))
    }

    private func fireMouseUp(at point: NSPoint) {
        selectionView.mouseUp(with: makeEvent(type: .leftMouseUp, at: point))
    }

    private func makeEvent(type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}

/// 记录 selectionDidComplete / selectionDidChange / selectionDidCancel 调用的测试 delegate。
final class RecordingSelectionDelegate: SelectionViewDelegate {
    private(set) var completedCalled = false
    private(set) var completedRect: NSRect?
    private(set) var completedRects: [NSRect] = []
    private(set) var changedRects: [NSRect] = []
    private(set) var cancelledCalled = false

    func selectionDidComplete(rect: NSRect) {
        completedCalled = true
        completedRect = rect
        completedRects.append(rect)
    }

    func selectionDidChange(rect: NSRect) {
        changedRects.append(rect)
    }

    func selectionDidCancel() {
        cancelledCalled = true
    }
}
