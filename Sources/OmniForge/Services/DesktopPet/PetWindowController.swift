import AppKit
import SwiftUI

/// 宠物窗口的鼠标事件承载视图。
/// 重写 `acceptsFirstMouse` 让非激活窗口内的第一次点击即响应（不先激活 App、不抢键盘焦点）。
final class PetHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 宠物窗口控制器：透明无边框置顶面板，承载 SwiftUI 宠物视图。
/// 一个控制器对应一只宠物（一宠物一窗口），天然支持二期多宠物。
/// 右键菜单由 SwiftUI 视图层提供，控制器只负责窗口与几何。
@MainActor
final class PetWindowController {
    private(set) var panel: NSPanel?

    /// 当前窗口尺寸（非正方形：按素材宽高比，高度为档位尺寸）。
    private(set) var petSize: CGSize

    init(petSize: CGSize) {
        self.petSize = petSize
    }

    // MARK: - 窗口生命周期

    /// 创建并显示窗口。`initialOrigin` 为窗口左下角坐标（nil 时落到主屏地面右侧）。
    func show(initialOrigin: CGPoint?, rootView: some View) {
        let origin = initialOrigin ?? defaultOrigin(size: petSize)
        let frame = NSRect(origin: origin, size: petSize)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 透明无边框置顶面板：不抢焦点、不激活 App、出现在所有 Space（含全屏）。
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = PetHostingView(rootView: AnyView(rootView))

        self.panel = panel
        panel.orderFrontRegardless()
    }

    /// 关闭窗口并释放视图。
    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }

    // MARK: - 尺寸与位置

    /// 更新窗口尺寸：保持左下角不动、按新尺寸改窗口大小。
    func apply(petSize newSize: CGSize) {
        guard let panel, newSize != petSize else {
            petSize = newSize
            return
        }
        petSize = newSize
        var frame = panel.frame
        frame.size = newSize
        panel.setFrame(frame, display: true)
        clampToVisibleScreen()
    }

    /// 读取当前窗口位置（左下角）。
    var currentOrigin: CGPoint? {
        panel.map { $0.frame.origin }
    }

    /// 移动到指定左下角位置。
    func move(to origin: CGPoint) {
        guard let panel else { return }
        var frame = panel.frame
        frame.origin = origin
        panel.setFrame(frame, display: true)
    }

    /// 把窗口夹回当前所在屏幕的可见区。
    func clampToVisibleScreen() {
        guard let panel else { return }
        let petSize = panel.frame.size
        let screens = Self.screenGeometries()
        guard let screen = PetPositionPlanner.screenContaining(
            position: panel.frame.origin,
            petSize: petSize,
            screens: screens
        ) else { return }
        let clamped = PetPositionPlanner.clamp(panel.frame.origin, petSize: petSize, to: screen)
        move(to: clamped)
    }

    // MARK: - 屏幕几何

    /// 当前所有屏幕的几何摘要（可见区 + 稳定标识）。
    static func screenGeometries() -> [PetScreenGeometry] {
        NSScreen.screens.map { screen in
            PetScreenGeometry(
                visibleFrame: screen.visibleFrame,
                identifier: identifier(for: screen)
            )
        }
    }

    /// 屏幕稳定标识：优先用系统分配的 displayID，回退到 frame 描述。
    static func identifier(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return "display-\(number.uint32Value)"
        }
        return "frame-\(screen.frame.origin.x)-\(screen.frame.origin.y)"
    }

    /// 主屏标识。
    static var mainScreenIdentifier: String? {
        NSScreen.main.map { identifier(for: $0) }
    }

    /// 默认落点：主屏可见区右下角内侧。
    private func defaultOrigin(size: CGSize) -> CGPoint {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: frame.maxX - size.width - 40, y: frame.minY)
    }
}
