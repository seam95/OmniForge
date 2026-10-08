import AppKit
import SwiftUI

/// 屏幕顶部的透明横条：跨所有 Space（全屏 Space 除外由协调器抑制）、永不抢焦点、
/// 默认鼠标穿透，仅照片命中区接收点击。建窗必须 animationBehavior = .none（macOS 26）。
final class ClotheslinePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        // macOS 26 起 orderFront/orderOut 默认附加系统淡入淡出，绳子要求即时显隐。
        animationBehavior = .none
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// 贴某屏顶边占满宽度。
    func placeOnScreen(_ screen: NSScreen?) {
        guard let visible = (screen ?? Self.screenUnderPointer())?.visibleFrame else { return }
        let target = NSRect(x: visible.minX, y: visible.maxY - ClotheslineLayout.panelHeight,
                            width: visible.width, height: ClotheslineLayout.panelHeight)
        if frame != target { setFrame(target, display: true) }
    }
}
