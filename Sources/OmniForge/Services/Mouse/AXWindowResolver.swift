import ApplicationServices
import CoreGraphics

/// 将辅助功能窗口元素解析为其 WindowServer id。由 ApplicationServices 导出，
/// 被 macOS 窗口切换器使用；此映射无私有替代方案。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AXWindowResolver {
    static func windowID(for element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
