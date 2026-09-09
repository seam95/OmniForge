import ApplicationServices
import Foundation
import os.log

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

/// 经辅助功能 API 直读其他应用（含本应用自身）的选中文本。
///
/// 焦点元素解析按可靠性顺序尝试两条路径（对 Electron 系应用尤为关键）：
/// B. systemWide 直取 `kAXFocusedUIElementAttribute`（首选——不依赖应用侧焦点转发的正确性）
/// A. systemWide → focusedApplication → `kAXFocusedUIElementAttribute`（回退）
/// 任一路径取得元素后：主路径读 `kAXSelectedTextAttribute`，
/// 为空时回退 selectedTextRange + 参数化属性取范围文本。
final class AXSelectedTextReader: SelectedTextReading {
    private static let logger = Logger(subsystem: "com.omniforge.app", category: "PromptOptimizer")

    private let isTrusted: () -> Bool

    init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
    }

    func readSelectedText() -> Result<String, SelectedTextReadFailure> {
        guard isTrusted() else {
            Self.logger.notice("取词失败：AXIsProcessTrusted=false")
            return .failure(.accessibilityInactive)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var sawPermissionLevelError = false
        var candidates: [AXUIElement] = []

        // 路径 B：systemWide 直取焦点元素（Electron 等应用上比经 app 中转更可靠）。
        var elementBRef: CFTypeRef?
        let elementBError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &elementBRef
        )
        Self.logger.notice("路径B systemWide.focusedUIElement = \(elementBError.rawValue, privacy: .public)")
        if elementBError == .success, let elementBRef {
            candidates.append(elementBRef as! AXUIElement)
        } else if Self.isPermissionLevelError(elementBError) {
            sawPermissionLevelError = true
        }

        // 路径 A：经焦点应用中转。
        var appRef: CFTypeRef?
        let appError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        )
        Self.logger.notice("路径A1 systemWide.focusedApplication = \(appError.rawValue, privacy: .public)")
        if appError == .success, let appRef {
            let app = appRef as! AXUIElement
            var elementARef: CFTypeRef?
            let elementAError = AXUIElementCopyAttributeValue(
                app,
                kAXFocusedUIElementAttribute as CFString,
                &elementARef
            )
            Self.logger.notice("路径A2 app.focusedUIElement = \(elementAError.rawValue, privacy: .public)")
            if elementAError == .success, let elementARef {
                let elementA = elementARef as! AXUIElement
                // 两条路径常返回同一元素；CFEqual 去重后仍逐路径读取（防 B 路径元素残缺）。
                if !candidates.contains(where: { CFEqual($0, elementA) }) {
                    candidates.append(elementA)
                }
            } else if Self.isPermissionLevelError(elementAError) {
                sawPermissionLevelError = true
            }
        } else if Self.isPermissionLevelError(appError) {
            sawPermissionLevelError = true
        }

        guard !candidates.isEmpty else {
            if sawPermissionLevelError {
                Self.logger.notice("取词失败：trusted 通过但 AX 调用权限级错误（授权未生效假阳性）")
                return .failure(.accessibilityInactive)
            }
            Self.logger.notice("取词失败：两条路径均未取得焦点元素")
            return .failure(.noSelection)
        }

        for element in candidates {
            if let text = Self.selectedText(of: element), !text.isEmpty {
                Self.logger.notice("取词成功：kAXSelectedTextAttribute 主路径，长度 \(text.count, privacy: .public)")
                return .success(text)
            }
            if let text = Self.selectedTextInRange(of: element), !text.isEmpty {
                Self.logger.notice("取词成功：range+参数化回退路径，长度 \(text.count, privacy: .public)")
                return .success(text)
            }
        }
        Self.logger.notice("取词失败：焦点元素不含可读选中文本（候选 \(candidates.count, privacy: .public) 个）")
        return .failure(.noSelection)
    }

    // MARK: - 私有

    private static func isPermissionLevelError(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .apiDisabled
    }

    /// 主路径：直接读选中文本属性。
    private static func selectedText(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        )
        guard error == .success else {
            logger.notice("selectedText 主路径 = \(error.rawValue, privacy: .public)")
            return nil
        }
        return value as? String
    }

    /// 回退路径：读选中 range，再用参数化属性换取该范围的字符串。
    private static func selectedTextInRange(of element: AXUIElement) -> String? {
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeError == .success, let rangeValue else {
            logger.notice("selectedTextRange = \(rangeError.rawValue, privacy: .public)")
            return nil
        }

        var stringValue: CFTypeRef?
        let stringError = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &stringValue
        )
        guard stringError == .success else {
            logger.notice("stringForRange 参数化 = \(stringError.rawValue, privacy: .public)")
            return nil
        }
        guard let text = stringValue as? String else { return nil }
        return text.isEmpty ? nil : text
    }
}
