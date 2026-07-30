import AppKit

/// 选区视图协议。
protocol SelectionViewDelegate: AnyObject {
    func selectionDidComplete(rect: NSRect)
    func selectionDidCancel()
    /// 选区拖动/缩放过程中的中间态（external 与内部 drag 均可调用）。
    func selectionDidChange(rect: NSRect)
}

extension SelectionViewDelegate {
    func selectionDidChange(rect: NSRect) {}
}

/// 选区交互与绘制视图。
/// 管理状态机（idle/drawing/selected）+ 八方向调整 handle + even-odd 暗化 + 宽高比约束。
class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?

    // MARK: - 状态

    private enum State {
        case idle
        case drawing
        case selected
    }

    enum HandlePosition: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        case topCenter, bottomCenter, leftCenter, rightCenter
    }

    private enum DragAction {
        case none
        case drawNew
        case move
        case resize(HandlePosition)
    }

    private var state: State = .idle
    private var dragAction: DragAction = .none
    private var selectionRect: NSRect?
    private var dragStart: NSPoint = .zero
    private var dragOriginalRect: NSRect = .zero
    private var mouseDownPoint: NSPoint = .zero

    /// 底图快照（遮罩出现前预抓；显示后亦可注入，didSet 触发重绘）。
    var backgroundSnapshot: CGImage? {
        didSet { needsDisplay = true }
    }

    /// 宽高比约束（nil 为自由）。
    var aspectRatio: CGFloat?

    /// 窗口吸附 provider（nil 时禁用吸附）。
    var snapProvider: WindowSnapProvider?
    /// 视图所在屏 frame 来源（用于视图↔CG 全局坐标转换）。
    /// 生产用 `window?.screen?.frame`；测试可注入固定值。
    var screenFrameProvider: (() -> NSRect?)?
    /// 视图所在屏 visibleFrame 来源（已扣除菜单栏/Dock，用于边缘条带吸附）。
    /// 生产用 `window?.screen?.visibleFrame`；测试可注入固定值。
    var visibleFrameProvider: (() -> NSRect?)?
    /// 主屏高度来源（CG 全局 Y 翻转基准）。生产用 `NSScreen.screens.first?.frame.maxY`。
    var primaryDisplayHeightProvider: (() -> CGFloat?)?
    /// 当前悬停高亮矩形（视图坐标，仅 idle 态有效）。
    private var hoverRect: NSRect?
    /// 当前悬停查询任务（取消前一个未完成的查询，避免并发竞态）。
    private var hoverTask: Task<Void, Never>?
    /// 跨屏非 key 窗口也要收 mouseMoved：靠 activeAlways trackingArea。
    private var snapTrackingArea: NSTrackingArea?
    /// 待确认的窗口选区：mouseDown 在 hover 上时存入，mouseUp 确认；
    /// 拖拽超过 windowClickThreshold 则丢弃转自由框选。参照 capcap。
    private var pendingRect: NSRect?
    private var pendingWindowID: CGWindowID?
    /// 待确认选区的拖拽阈值（pt）：阈值内 mouseDragged 不更新视觉。
    private let windowClickThreshold: CGFloat = 4

    /// 编辑器已打开：点选区外不重新框选；仍绘制虚线边框与暗化。
    var selectionLocked: Bool = false {
        didSet { needsDisplay = true }
    }
    /// 是否允许选区交互，以及在 selected 态绘制 8 点与尺寸标签。
    var selectionInteractionEnabled: Bool = true {
        didSet { needsDisplay = true }
    }
    /// 标注工具激活时，选区内部点击让给画布，不走内部 move。
    var annotationToolActive: Bool = false {
        didSet { needsDisplay = true }
    }
    /// 长截图进行中（绘制红边等；本任务仅占位）。
    var scrollCaptureActive: Bool = false {
        didSet { needsDisplay = true }
    }

    // MARK: - 常量

    private let handleSize: CGFloat = 8
    private let handleHitSize: CGFloat = 12
    private let borderWidth: CGFloat = 2
    private let dimmingAlpha: CGFloat = 0.45
    private let minSelectionSize: CGFloat = 5

    // MARK: - 初始化

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    // MARK: - Tracking（多屏跨屏关键）

    /// 多屏时只有一个 key overlay，副屏 panel 收不到依赖 key 的 mouseMoved。
    /// activeAlways + mouseMoved 保证任意屏上悬停都能更新吸附。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let snapTrackingArea {
            removeTrackingArea(snapTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        snapTrackingArea = area
    }

    override func mouseExited(with event: NSEvent) {
        if selectionLocked { return }
        hoverTask?.cancel()
        clearHover()
        NSCursor.crosshair.set()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 绘制底图。滚动捕获期间跳过冻结快照，让选区 dig-out 露出底层实时页面
        //（对齐 CapCap：!scrollCaptureActive 才画 snapshot）。
        if let snapshot = backgroundSnapshot, !scrollCaptureActive {
            ctx.draw(snapshot, in: bounds)
        } else if backgroundSnapshot == nil {
            // 无底图时清空背景
            ctx.setFillColor(NSColor.clear.cgColor)
            ctx.fill(bounds)
        }

        // 悬停高亮：仅 idle 态绘制，视觉等同"准选区"——even-odd 暗化（挖去 hover 区）
        // + 绿色实线边框（线宽 borderWidth+1，外扩 1.5pt）+ 尺寸 label。参照 capcap。
        if state == .idle, let hover = hoverRect {
            drawDimmingMask(cutoutRect: hover, in: ctx)
            ctx.setStrokeColor(accentColor.cgColor)
            ctx.setLineWidth(borderWidth + 1)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.stroke(hover.insetBy(dx: -1.5, dy: -1.5))
            drawSizeLabel(rect: hover, in: ctx)
            return
        }

        // 选区暗化遮罩：编辑器（selectionLocked）同样保留；
        // 边框始终绘制；8 点与尺寸标签仅在 interaction 开启时绘制。
        if let selRect = selectionRect {
            // 滚动捕获时 dig-out 外扩 0.5pt，避免 cutout 边缘抗锯齿烤进每帧底部/侧边。
            let cutout = scrollCaptureActive ? selRect.insetBy(dx: -0.5, dy: -0.5) : selRect
            drawDimmingMask(cutoutRect: cutout, in: ctx)

            if scrollCaptureActive {
                // 红边必须完全落在捕获区外：SCK 排除 host 后仍可能因边框像素渗入帧内
                // 在左右边缘与拼接缝留下细线（对齐 CapCap）。
                let strokeWidth = borderWidth + 1
                let outerInset = -(strokeWidth / 2 + 1)
                ctx.setStrokeColor(NSColor.systemRed.cgColor)
                ctx.setLineWidth(strokeWidth)
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.stroke(selRect.insetBy(dx: outerInset, dy: outerInset))
            } else {
                // 选区边框：绿色虚线 [6,4]，向外扩 1pt（对比度最高）。
                ctx.setStrokeColor(accentColor.cgColor)
                ctx.setLineWidth(borderWidth)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.stroke(selRect.insetBy(dx: -1, dy: -1))
                ctx.setLineDash(phase: 0, lengths: [])
            }

            if selectionInteractionEnabled {
                drawSizeLabel(rect: selRect, in: ctx)
                if state == .selected {
                    drawHandles(rect: selRect, in: ctx)
                }
            }
        } else {
            // 无选区时全屏暗化
            ctx.setFillColor(NSColor.black.withAlphaComponent(dimmingAlpha).cgColor)
            ctx.fill(bounds)
        }
    }

    /// even-odd 填充实现挖洞暗化：bounds 全填暗色，挖去 cutoutRect。
    private func drawDimmingMask(cutoutRect: NSRect, in ctx: CGContext) {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(cutoutRect)
        ctx.setFillColor(NSColor.black.withAlphaComponent(dimmingAlpha).cgColor)
        ctx.addPath(path)
        ctx.fillPath(using: .evenOdd)
    }

    private func drawSizeLabel(rect: NSRect, in ctx: CGContext) {
        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        // 参照 capcap：标签左对齐到选区左上角上方 4pt
        let labelRect = CGRect(
            x: rect.origin.x,
            y: rect.maxY + 4,
            width: size.width + 8,
            height: size.height + 4
        )

        // 背景
        let bgPath = CGPath(roundedRect: labelRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()

        // 文字
        let textPoint = CGPoint(x: labelRect.origin.x + 4, y: labelRect.origin.y + 2)
        (label as NSString).draw(at: textPoint, withAttributes: attributes)
    }

    private func drawHandles(rect: NSRect, in ctx: CGContext) {
        ctx.setFillColor(accentColor.cgColor)
        let halfHandle = handleSize / 2
        for (_, center) in Self.handlePositions(for: rect) {
            let handleRect = CGRect(
                x: center.x - halfHandle,
                y: center.y - halfHandle,
                width: handleSize,
                height: handleSize
            )
            ctx.fillEllipse(in: handleRect)
        }
    }

    // MARK: - Handle 几何（静态，供 chrome 复用）

    /// 8 个控制点中心（AppKit 非 flipped：top = maxY，bottom = minY）。
    static func handlePositions(for rect: NSRect) -> [(HandlePosition, NSPoint)] {
        HandlePosition.allCases.map { ($0, handleCenter(for: $0, in: rect)) }
    }

    static func handleCenter(for position: HandlePosition, in rect: NSRect) -> NSPoint {
        switch position {
        case .topLeft: return NSPoint(x: rect.minX, y: rect.maxY)
        case .topRight: return NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomLeft: return NSPoint(x: rect.minX, y: rect.minY)
        case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
        case .topCenter: return NSPoint(x: rect.midX, y: rect.maxY)
        case .bottomCenter: return NSPoint(x: rect.midX, y: rect.minY)
        case .leftCenter: return NSPoint(x: rect.minX, y: rect.midY)
        case .rightCenter: return NSPoint(x: rect.maxX, y: rect.midY)
        }
    }

    /// 角优先命中检测。
    static func hitTestHandle(point: NSPoint, rect: NSRect, hitSize: CGFloat = 12) -> HandlePosition? {
        let halfHit = hitSize / 2
        let corners: [HandlePosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        for pos in corners {
            let center = handleCenter(for: pos, in: rect)
            let hitRect = CGRect(x: center.x - halfHit, y: center.y - halfHit, width: hitSize, height: hitSize)
            if hitRect.contains(point) { return pos }
        }
        let edges: [HandlePosition] = [.topCenter, .bottomCenter, .leftCenter, .rightCenter]
        for pos in edges {
            let center = handleCenter(for: pos, in: rect)
            let hitRect = CGRect(x: center.x - halfHit, y: center.y - halfHit, width: hitSize, height: hitSize)
            if hitRect.contains(point) { return pos }
        }
        return nil
    }

    static func setCursorForHandle(_ handle: HandlePosition) {
        switch handle {
        case .topLeft, .bottomRight, .topRight, .bottomLeft:
            NSCursor.crosshair.set()
        case .topCenter, .bottomCenter:
            NSCursor.resizeUpDown.set()
        case .leftCenter, .rightCenter:
            NSCursor.resizeLeftRight.set()
        }
    }

    /// 按 handle 与当前点计算新选区（最小边 minSize）。
    static func resizedRect(
        from original: NSRect,
        handle: HandlePosition,
        to point: NSPoint,
        minSize: CGFloat = 5
    ) -> NSRect {
        var r = original
        switch handle {
        case .topLeft:
            r.origin.x = min(point.x, original.maxX)
            r.origin.y = min(point.y, original.maxY)
            r.size.width = max(original.maxX - r.origin.x, minSize)
            r.size.height = max(original.maxY - r.origin.y, minSize)
        case .topRight:
            r.origin.y = min(point.y, original.maxY)
            r.size.width = max(point.x - original.minX, minSize)
            r.size.height = max(original.maxY - r.origin.y, minSize)
        case .bottomLeft:
            r.origin.x = min(point.x, original.maxX)
            r.size.width = max(original.maxX - r.origin.x, minSize)
            r.size.height = max(point.y - original.minY, minSize)
        case .bottomRight:
            r.size.width = max(point.x - original.minX, minSize)
            r.size.height = max(point.y - original.minY, minSize)
        case .topCenter:
            let dy = original.maxY - point.y
            r.origin.y = original.minY + (original.height - max(dy, minSize))
            r.size.height = max(dy, minSize)
        case .bottomCenter:
            r.size.height = max(point.y - original.minY, minSize)
        case .leftCenter:
            let dx = original.maxX - point.x
            r.origin.x = original.minX + (original.width - max(dx, minSize))
            r.size.width = max(dx, minSize)
        case .rightCenter:
            r.size.width = max(point.x - original.minX, minSize)
        }
        return r
    }

    // MARK: - 鼠标事件

    override func mouseMoved(with event: NSEvent) {
        // 编辑器锁定后不做窗口吸附 hover。
        if selectionLocked { return }
        // hover 仅在 idle 态进行（参照 capcap）：一旦开始 drawing/selected 即停止。
        guard state == .idle else { return }
        guard snapProvider != nil else {
            NSCursor.crosshair.set()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        // 必须持续查询：首次常命中整窗，窗内移动要能落到按钮等内部控件。
        // 防抖只在回填时「同 rect 不重绘」，这里不再跳过查询。
        updateHover(at: point)
    }

    /// 由多屏 hover 路由器调用：用已换算好的本屏局部点更新吸附（不依赖本窗 mouseMoved）。
    func updateHoverFromRouter(at localPoint: NSPoint) {
        if selectionLocked { return }
        guard state == .idle else { return }
        guard snapProvider != nil else {
            clearHover()
            return
        }
        updateHover(at: localPoint)
    }

    /// 路由器判定鼠标已离开本屏时清除本屏悬停。
    func clearHoverFromRouter() {
        hoverTask?.cancel()
        clearHover()
    }

    /// 异步查询吸附候选并更新高亮。
    /// 每次发起查询前取消前一个未完成的 Task，避免乱序回填。
    private func updateHover(at point: NSPoint) {
        // 屏 frame 来源：优先注入的 provider，否则取 window 所在屏。
        guard let screenFrame = screenFrameProvider?() ?? self.window?.screen?.frame else {
            clearHover()
            NSCursor.crosshair.set()
            return
        }
        // visibleFrame：无可见区信息时退化为整屏（边缘吸附不触发）。
        let visibleFrame = visibleFrameProvider?()
            ?? self.window?.screen?.visibleFrame
            ?? screenFrame
        let primaryHeight = primaryDisplayHeightProvider?()
            ?? NSScreen.screens.first?.frame.maxY
            ?? screenFrame.maxY
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            guard let self, let provider = self.snapProvider else { return }
            let candidate = await provider.candidate(
                at: point,
                in: self.bounds,
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                primaryDisplayHeight: primaryHeight
            )
            guard !Task.isCancelled else { return }
            // 鼠标可能已移动，校验候选 rect 仍包含该查询对应的点，避免残留高亮。
            if let candidate, candidate.rect.contains(point) {
                // 候选变化才重绘（参照 capcap L446）：同 rect 反复重绘会闪烁。
                if self.hoverRect != candidate.rect {
                    self.hoverRect = candidate.rect
                    self.needsDisplay = true
                }
                NSCursor.pointingHand.set()
            } else {
                self.clearHover()
                NSCursor.crosshair.set()
            }
        }
    }

    /// 清除悬停高亮（仅在状态变化时触发重绘）。
    private func clearHover() {
        if hoverRect != nil {
            hoverRect = nil
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        // 交互关闭时完全不处理（交给上层）。
        guard selectionInteractionEnabled else { return }

        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point

        // idle 态命中悬停窗口：存为待确认选区，清掉 hover 显示，进入 drawNew。
        // mouseUp 时若仍持有 pending 则确认；mouseDragged 超阈值则丢弃转自由框选。参照 capcap。
        if state == .idle, let hover = hoverRect {
            pendingRect = hover
            pendingWindowID = nil
            hoverRect = nil
            hoverTask?.cancel()
            selectionRect = NSRect(origin: point, size: .zero)
            dragStart = point
            state = .drawing
            dragAction = .drawNew
            needsDisplay = true
            return
        }

        // 进入其他操作前，清掉残留 hover（state 已非 idle）。
        clearHover()

        guard let selRect = selectionRect else {
            // 无选区：开始绘制新选区
            state = .drawing
            dragAction = .drawNew
            selectionRect = NSRect(origin: point, size: .zero)
            dragStart = point
            needsDisplay = true
            return
        }

        // 检查是否命中 handle（interaction 开启时始终可缩放）
        if let handle = Self.hitTestHandle(point: point, rect: selRect, hitSize: handleHitSize) {
            state = .selected
            dragAction = .resize(handle)
            dragStart = point
            dragOriginalRect = selRect
            return
        }

        // 选区内：编辑器态（selectionLocked）按住即拖动选区；
        // 非编辑器态且标注工具激活时才让给上层画布。
        if selRect.contains(point) {
            if annotationToolActive && !selectionLocked { return }
            state = .selected
            dragAction = .move
            dragStart = point
            dragOriginalRect = selRect
            return
        }

        // 选区外：锁定后忽略（不重新框选）
        if selectionLocked { return }

        // 选区外：开始新选区
        state = .drawing
        dragAction = .drawNew
        selectionRect = NSRect(origin: point, size: .zero)
        dragStart = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch dragAction {
        case .none:
            break

        case .drawNew:
            // 持有待确认窗口选区时：阈值内完全不更新视觉（等 mouseUp 确认或更多移动）；
            // 超过阈值则丢弃 pending，转自由框选。参照 capcap。
            if pendingRect != nil {
                let dx = abs(point.x - mouseDownPoint.x)
                let dy = abs(point.y - mouseDownPoint.y)
                if dx < windowClickThreshold, dy < windowClickThreshold {
                    return  // 阈值内：不更新视觉
                }
                pendingRect = nil
                pendingWindowID = nil
            }
            NSCursor.crosshair.set()
            let newRect = dragRect(from: dragStart, to: point)
            selectionRect = constrainToBounds(newRect)
            needsDisplay = true

        case .move:
            NSCursor.closedHand.set()
            let delta = CGPoint(x: point.x - dragStart.x, y: point.y - dragStart.y)
            let movedRect = dragOriginalRect.offsetBy(dx: delta.x, dy: delta.y)
            selectionRect = clampMove(rect: movedRect)
            if let rect = selectionRect {
                delegate?.selectionDidChange(rect: rect)
            }
            needsDisplay = true

        case .resize(let handle):
            let newRect = Self.resizedRect(
                from: dragOriginalRect,
                handle: handle,
                to: point,
                minSize: minSelectionSize
            )
            selectionRect = constrainToBounds(newRect)
            if let rect = selectionRect {
                delegate?.selectionDidChange(rect: rect)
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragAction = .none
        }

        switch dragAction {
        case .none:
            break

        case .drawNew:
            // 持有待确认窗口选区（mouseDown 时命中 hover 且未拖出阈值）→ 确认为最终选区。参照 capcap。
            if let pending = pendingRect {
                pendingRect = nil
                pendingWindowID = nil
                selectionRect = pending
                state = .selected
                delegate?.selectionDidComplete(rect: pending)
                needsDisplay = true
                return
            }
            guard let rect = selectionRect, rect.width >= minSelectionSize, rect.height >= minSelectionSize else {
                // 过小选区：取消
                selectionRect = nil
                state = .idle
                delegate?.selectionDidCancel()
                needsDisplay = true
                return
            }
            state = .selected
            delegate?.selectionDidComplete(rect: rect)
            needsDisplay = true

        case .move, .resize:
            state = .selected
            if let rect = selectionRect {
                delegate?.selectionDidComplete(rect: rect)
            }
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // 编辑器锁定后不在此层取消（由编辑器 ESC/X 关闭）。
        if selectionLocked { return }
        // 右键取消
        selectionRect = nil
        state = .idle
        delegate?.selectionDidCancel()
        needsDisplay = true
    }

    // MARK: - 几何计算

    /// 从起始点到当前点计算选区。
    private func dragRect(from start: NSPoint, to end: NSPoint) -> NSRect {
        var rect = NSRect.zero
        rect.origin.x = min(start.x, end.x)
        rect.origin.y = min(start.y, end.y)
        rect.size.width = abs(end.x - start.x)
        rect.size.height = abs(end.y - start.y)

        if let ratio = aspectRatio {
            rect = aspectLockedRect(rect, ratio: ratio, from: start, to: end)
        }
        return rect
    }

    /// 带宽高比约束的选区。
    private func aspectLockedRect(_ rect: NSRect, ratio: CGFloat, from start: NSPoint, to end: NSPoint) -> NSRect {
        var r = rect
        let isWider = abs(end.x - start.x) > abs(end.y - start.y)
        if isWider {
            r.size.height = r.size.width / ratio
        } else {
            r.size.width = r.size.height * ratio
        }
        // 固定起始点方向的锚点
        r.origin.x = min(start.x, start.x + (end.x > start.x ? r.size.width : -r.size.width))
        r.origin.y = min(start.y, start.y + (end.y > start.y ? r.size.height : -r.size.height))
        return r
    }

    /// 将选区约束在视图边界内（可缩小宽高以塞入）。
    private func constrainToBounds(_ rect: NSRect) -> NSRect {
        var r = rect
        if r.minX < bounds.minX { r.origin.x = bounds.minX }
        if r.minY < bounds.minY { r.origin.y = bounds.minY }
        if r.maxX > bounds.maxX { r.size.width = max(0, bounds.maxX - r.origin.x) }
        if r.maxY > bounds.maxY { r.size.height = max(0, bounds.maxY - r.origin.y) }
        return r
    }

    /// 平移约束：保持宽高不变，仅夹取 origin 使整框落在 bounds 内。
    private func clampMove(rect: NSRect) -> NSRect {
        var r = rect
        let maxOriginX = max(bounds.minX, bounds.maxX - r.width)
        let maxOriginY = max(bounds.minY, bounds.maxY - r.height)
        r.origin.x = min(max(r.origin.x, bounds.minX), maxOriginX)
        r.origin.y = min(max(r.origin.y, bounds.minY), maxOriginY)
        return r
    }

    // MARK: - 颜色

    private var accentColor: NSColor {
        NSColor(red: 0, green: 212.0 / 255.0, blue: 106.0 / 255.0, alpha: 1)
    }

    // MARK: - 首次点击

    // overlay 唤起时 app 通常非 active，首次点击默认被系统吞掉用于激活窗口，
    // 不会转发给 mouseDown。返回 true 让首次点击即进入框选。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - 公开方法

    /// 清除选区。
    func clearSelection() {
        hoverTask?.cancel()
        hoverRect = nil
        pendingRect = nil
        pendingWindowID = nil
        selectionRect = nil
        state = .idle
        dragAction = .none
        needsDisplay = true
    }

    /// 获取当前选区（视图坐标）。
    var currentSelectionRect: NSRect? {
        selectionRect
    }

    /// 测试用：当前是否持有 hover 高亮（draw 的 hover 分支据此绘制绿色边框）。
    /// 用于回归多屏编辑器嵌入后副屏 hover 残留的清除。
    var hasHoverForTesting: Bool {
        hoverRect != nil
    }

    /// 测试用：直接注入一个 hover 高亮矩形，模拟路由器残留。
    func setHoverForTesting(_ rect: NSRect?) {
        hoverRect = rect
        needsDisplay = true
    }

    /// 外部设置选区（进入编辑器、chrome 同步等）。
    func updateSelectionRect(_ rect: NSRect) {
        selectionRect = constrainToBounds(rect)
        state = .selected
        dragAction = .none
        clearHover()
        needsDisplay = true
    }

    /// 工具栏手柄等外部拖动：相对 originalRect 平移并夹取 bounds（保持尺寸）。
    func moveByExternalDrag(deltaFromOriginal: CGSize, originalRect: NSRect) {
        let moved = originalRect.offsetBy(dx: deltaFromOriginal.width, dy: deltaFromOriginal.height)
        selectionRect = clampMove(rect: moved)
        state = .selected
        if let rect = selectionRect {
            delegate?.selectionDidChange(rect: rect)
        }
        needsDisplay = true
    }

    func finalizeExternalDrag() {
        state = .selected
        dragAction = .none
        if let rect = selectionRect {
            delegate?.selectionDidComplete(rect: rect)
        }
        needsDisplay = true
    }

    /// chrome 8 点外部缩放。
    func resizeByExternalDrag(handle: HandlePosition, originalRect: NSRect, currentPoint: NSPoint) {
        let newRect = Self.resizedRect(
            from: originalRect,
            handle: handle,
            to: currentPoint,
            minSize: minSelectionSize
        )
        selectionRect = constrainToBounds(newRect)
        state = .selected
        if let rect = selectionRect {
            delegate?.selectionDidChange(rect: rect)
        }
        needsDisplay = true
    }

    func finalizeExternalResize() {
        state = .selected
        dragAction = .none
        if let rect = selectionRect {
            delegate?.selectionDidComplete(rect: rect)
        }
        needsDisplay = true
    }

    /// 仅测试用：暴露 hoverRect 供断言。
    internal var hoverRectForTesting: NSRect? { hoverRect }
    /// 仅测试用：暴露 pendingRect 供断言。
    internal var pendingRectForTesting: NSRect? { pendingRect }
}
