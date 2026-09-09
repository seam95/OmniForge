import ApplicationServices
import Foundation

/// 选中文本读取边界（决策 D3：AX 直读，无 ⌘C 模拟兜底）。
protocol SelectedTextReading: AnyObject {
    /// 读取当前焦点应用的选中文本；无选中或无法读取 → nil。
    func readSelectedText() -> String?
}

/// 经辅助功能 API 直读其他应用（含本应用自身）的选中文本：
/// systemWide → focusedApplication → focusedUIElement，主路径读 `kAXSelectedTextAttribute`，
/// 为空时回退 selectedTextRange + 参数化属性取范围文本（覆盖部分只暴露 range 的编辑器）。
final class AXSelectedTextReader: SelectedTextReading {
    private let isTrusted: () -> Bool

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    func readSelectedText() -> String? {
        guard isTrusted() else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        ) == .success, let focusedAppValue else { return nil }
        let focusedApp = focusedAppValue as! AXUIElement

        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success, let focusedElementValue else { return nil }
        let element = focusedElementValue as! AXUIElement

        if let text = Self.selectedText(of: element), !text.isEmpty {
            return text
        }
        return Self.selectedTextInRange(of: element)
    }

    // MARK: - 私有

    /// 主路径：直接读选中文本属性。
    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    /// 回退路径：读选中 range，再用参数化属性换取该范围的字符串。
    private static func selectedTextInRange(of element: AXUIElement) -> String? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success, let rangeValue else { return nil }

        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue
        ) == .success else { return nil }
        guard let text = stringValue as? String else { return nil }
        return text.isEmpty ? nil : text
    }
}
