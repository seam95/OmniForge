// Sources/OmniForge/Services/Screenshot/clothesline/ClotheslineLayout.swift
import CoreGraphics

/// 绳子几何：面板高度、卡片间距、抛物线绳形与容量。纯函数，视图与面板共用。
enum ClotheslineLayout {
    static let panelHeight: CGFloat = 210
    static let ropeTop: CGFloat = 10
    static let spacing: CGFloat = 174
    static let cardWidth: CGFloat = 150
    /// 卡片顶（衣夹下缘）距绳线的上偏移。
    static let pinAbove: CGFloat = 9.5

    /// 绳子两端固定、中间下垂，最大 30pt。
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    /// 绳上 x 处的 y（视图顶部坐标）。
    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// 第 index 张卡片的中心 x（整体居中）。
    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let total = CGFloat(max(count - 1, 0)) * spacing
        return width / 2 - total / 2 + CGFloat(index) * spacing
    }

    /// 按屏宽算容量，钳在 3…12。
    static func capacity(width: CGFloat) -> Int {
        max(3, min(12, Int((width - 200) / spacing)))
    }
}
