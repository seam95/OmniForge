import Foundation
import AppKit

/// 菜单栏指标布局配置
enum MenuBarMetricLayout {
    static let minItemWidth: CGFloat = 28
    // 块间 spacer：对齐参考实现（Stats）的 widget 间距 2pt
    static let compactSpacing: CGFloat = 2
    static let standardSpacing: CGFloat = 2

    /// compact 模式至少预留的数字位数（覆盖 0–99，避免 9%↔10% 抖动）
    static let compactMinimumDigits = 2

    /// 会话内各 label 的最高位数水位（主线程访问）
    private static var digitHighWater: [String: Int] = [:]

    static func totalWidth(groups: [NSAttributedString], spacing: MenuBarMetricSpacing) -> CGFloat {
        let gap = spacing == .compact ? compactSpacing : standardSpacing
        let total = groups.reduce(CGFloat(0)) { $0 + $1.size().width }
        let gaps = CGFloat(max(0, groups.count - 1)) * gap
        return total + gaps
    }

    /// 位数高水位预留：当前 value 形状 + 至少 2 位 + 会话高水位。
    /// 两种间距模式共用（仅 spacer 不同）；块宽只在位数首次跨越时变一次。
    static func compactReserve(label: String, value: String) -> String {
        let digits = value.filter(\.isNumber).count
        let floor = compactFloor(currentDigits: digits, highWater: digitHighWater[label])
        digitHighWater[label] = floor
        return digitMatchedReserve(for: value, minimumDigits: floor)
    }

    static func compactFloor(currentDigits: Int, highWater: Int?) -> Int {
        max(currentDigits, compactMinimumDigits, highWater ?? 0)
    }

    /// 同形占位（数字换成 8），并在首个数字前补齐到 minimumDigits
    static func digitMatchedReserve(for value: String, minimumDigits: Int = 0) -> String {
        var out = ""
        var digitCount = value.filter(\.isNumber).count
        var padded = false
        for character in value {
            if character.isNumber, !padded {
                while digitCount < minimumDigits {
                    out.append("8")
                    digitCount += 1
                }
                padded = true
            }
            out.append(character.isNumber ? "8" : character)
        }
        return out
    }

    /// 测试辅助：清空会话水位
    static func resetCompactHighWaterForTesting() {
        digitHighWater = [:]
    }
}
