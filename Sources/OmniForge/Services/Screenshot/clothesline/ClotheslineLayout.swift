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

    /// 绳子中央给一键清理扫帚留的缺口宽（半格 + 两侧余量）。
    /// 150 保证：最近卡片中心距中央 162pt、卡片内缘距中央 90pt，
    /// 与扫帚钮（40pt 宽 + 阴影）之间仍有 ~60pt 净距——重叠不可能发生。
    static let centerGap: CGFloat = 150

    /// 第 displayIndex 张卡片的中心 x：照片分列扫帚左右（偶数张完全对称，
    /// 奇数张右侧多一张）。左半=较旧、右半=较新，与 items 顺序一致。
    /// displayIndex 是**展示段内**下标（0..<可见数），不是 items 下标。
    static func photoX(displayIndex: Int, count: Int, width: CGFloat) -> CGFloat {
        let center = width / 2
        let leftCount = count / 2
        if displayIndex < leftCount {
            let n = leftCount - displayIndex          // 距中央第 n 格（左）
            return center - centerGap / 2 - spacing * (CGFloat(n) - 0.5)
        }
        let n = displayIndex - leftCount              // 距中央第 n+1 格（右）
        return center + centerGap / 2 + spacing * (CGFloat(n) + 0.5)
    }

    /// 按屏宽算容量，钳在 3…12。
    static func capacity(width: CGFloat) -> Int {
        max(3, min(12, Int((width - 200) / spacing)))
    }

    /// 屏上可见张数 = min(总数, 屏宽可容纳数)：展示最新的一段（后缀）。
    static func visibleCount(total: Int, width: CGFloat) -> Int {
        min(total, capacity(width: width))
    }

    /// 隐藏数 = 总数 − 可见数；绳尾「+N」徽章的 N。
    static func hiddenCount(total: Int, width: CGFloat) -> Int {
        max(0, total - visibleCount(total: total, width: width))
    }
}
