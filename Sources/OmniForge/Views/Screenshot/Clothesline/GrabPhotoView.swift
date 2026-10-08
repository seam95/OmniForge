import AppKit
import SwiftUI

/// 桥接 AppKit 拖放：拖到应用 = 副本（留绳）；文件夹 = 移动（离绳）；
/// 废纸篓 = 删除；无效处 = 飞回。点 = 复制；双击 = 打开；长按 = Markup。
struct GrabArea: NSViewRepresentable {
    let item: PeggedPhoto
    @ObservedObject var manager: ClotheslineManager
    var menuProvider: ((PeggedPhoto) -> NSMenu)? = nil

    func makeNSView(context: Context) -> GrabPhotoView {
        let view = GrabPhotoView()
        configure(view)
        return view
    }

    func updateNSView(_ view: GrabPhotoView, context: Context) { configure(view) }

    private func configure(_ view: GrabPhotoView) {
        let id = item.id
        view.url = item.url
        view.dragImage = item.thumb
        view.onClick = { [weak manager] in manager?.copy(id) }
        view.onDoubleClick = { [weak manager] in manager?.openInDefaultApp(id) }
        view.onDragStart = { [weak manager] in manager?.draggingID = id }
        view.onDragEnd = { [weak manager] in manager?.prune() }
        view.onTrash = { [weak manager] in manager?.trash(id) }
        view.onDiscard = { [weak manager] in manager?.discard(id) }
        view.onLongPress = { [weak manager] in manager?.markup(id) }
        view.onPressChange = { [weak manager] pressed in manager?.pressedID = pressed ? id : nil }
        view.menuProvider = {
            // 有注入用注入菜单；无注入给空菜单（Task 12 装配时注入带 l10n 的真身）。
            menuProvider?(item) ?? GrabPhotoView.defaultMenu()
        }
    }
}

final class GrabPhotoView: NSView, NSDraggingSource {
    /// 拖拽进行中标志：显隐状态机据此判定「忙碌不收绳」。
    static var isDragging = false
    static let holdDuration: TimeInterval = 0.45
    static let crossHitSize: CGFloat = 26

    var url: URL?
    var dragImage: NSImage?
    var onClick: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    var onDragStart: () -> Void = {}
    var onDragEnd: () -> Void = {}
    var onTrash: () -> Void = {}
    var onDiscard: () -> Void = {}
    var onLongPress: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var downPoint: NSPoint?
    private var startedDrag = false
    private var holdTimer: Timer?
    private var didLongPress = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 默认空菜单：带 l10n 的完整菜单在装配层经 menuProvider 注入（Task 12）。
    static func defaultMenu() -> NSMenu { NSMenu() }

    private func isInCross(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        let corner = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - Self.crossHitSize,
                            width: Self.crossHitSize, height: Self.crossHitSize)
        return corner.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        if isInCross(event) { downPoint = nil; onDiscard(); return }
        if event.clickCount == 2 { downPoint = nil; onDoubleClick(); return }
        downPoint = event.locationInWindow
        startedDrag = false
        didLongPress = false
        onPressChange(true)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.downPoint != nil, !self.startedDrag else { return }
                self.didLongPress = true
                self.onPressChange(false)
                self.onLongPress()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !startedDrag, let url else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4, !didLongPress else { return }
        startedDrag = true
        endPress()
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(imageFrame(), contents: dragImage)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true   // 松手无效处飞回
        GrabPhotoView.isDragging = true
        onDragStart()
    }

    override func mouseUp(with event: NSEvent) {
        endPress()
        if downPoint != nil, !startedDrag, !didLongPress, event.clickCount == 1 { onClick() }
        downPoint = nil
        didLongPress = false
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        onPressChange(false)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 应用取 copy；Finder 取 move（文件夹保留文件）；.delete 让 Dock 废纸篓能接。
        context == .outsideApplication ? [.copy, .move, .delete] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        GrabPhotoView.isDragging = false
        startedDrag = false
        downPoint = nil
        if operation.contains(.delete) {
            onDragEnd()
            onTrash()
            return
        }
        onDragEnd()
        // Finder 的 move 稍后完成；复查让照片离绳。
        if operation.contains(.move) {
            let done = onDragEnd
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                done()
            }
        }
    }

    /// 拖拽预览保持卡片内纵横比。
    private func imageFrame() -> NSRect {
        guard let size = dragImage?.size, size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
