import ApplicationServices
import Foundation

/// 取词失败类别 — 区分「权限未生效」与「无可读选区」，驱动 HUD 文案与排查方向。
enum SelectedTextReadFailure: Error, Equatable {
    /// 辅助功能权限缺失或未生效（TCC 假阳性：trusted 检查通过但 AX 调用
    /// 返回 cannotComplete/apiDisabled——典型于授权后未重启应用）。
    case accessibilityInactive
    /// 链路可达但目标元素无选中文本或不支持该属性。
    case noSelection
}

/// 选中文本读取边界（决策 D3：AX 直读，无 ⌘C 模拟兜底）。
protocol SelectedTextReading: AnyObject {
    /// 读取当前焦点应用的选中文本；失败携带可判别类别。
    func readSelectedText() -> Result<String, SelectedTextReadFailure>
}

/// 经辅助功能 API 直读其他应用（含本应用自身）的选中文本：
/// systemWide → focusedApplication → focusedUIElement，主路径读 `kAXSelectedTextAttribute`，
/// 为空时回退 selectedTextRange + 参数化属性取范围文本（覆盖部分只暴露 range 的编辑器）。
final class AXSelectedTextReader: SelectedTextReading {
    private let isTrusted: () -> Bool

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    func readSelectedText() -> Result<String, SelectedTextReadFailure> {
        guard isTrusted() else {
            return .failure(.accessibilityInactive)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        let appError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        )
        guard appError == .success, let focusedAppValue else {
            // trusted 通过但链路级调用失败：权限假阳性（授权未生效），非「无选区」。
            if appError == .cannotComplete || appError == .apiDisabled {
                return .failure(.accessibilityInactive)
            }
            return .failure(.noSelection)
        }
        let focusedApp = focusedAppValue as! AXUIElement

        var focusedElementValue: CFTypeRef?
        let elementError = AXUIElementCopyAttributeValue(
            focusedApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )
        guard elementError == .success, let focusedElementValue else {
            if elementError == .cannotComplete || elementError == .apiDisabled {
                return .failure(.accessibilityInactive)
            }
            return .failure(.noSelection)
        }
        let element = focusedElementValue as! AXUIElement

        if let text = Self.selectedText(of: element), !text.isEmpty {
            return .success(text)
        }
        if let text = Self.selectedTextInRange(of: element), !text.isEmpty {
            return .success(text)
        }
        return .failure(.noSelection)
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
