import Foundation

/// 气泡载置纯函数：默认在宠物上方居中，顶部放不下翻到下方，水平 clamp 在屏内。
/// 反应期间宠物不位移、拖拽会打断反应清气泡，故定位一次即可，无需跟踪。
enum PetBubblePlacement {
    /// 气泡与宠物之间的间距（点）。
    static let gap: CGFloat = 8
    /// 水平 clamp 的屏内边距（点）。
    static let horizontalInset: CGFloat = 2

    /// - Parameters:
    ///   - petFrame: 宠物窗口帧（AppKit 坐标，origin 为左下角）。
    ///   - bubbleSize: 气泡尺寸（由文本量尺得出）。
    ///   - screen: 宠物所在屏。
    /// - Returns: 气泡窗口帧与尾巴朝向（`tailDown` = 尾巴朝下，即气泡在宠物上方）。
    static func resolve(
        petFrame: CGRect,
        bubbleSize: CGSize,
        screen: PetScreenGeometry
    ) -> (frame: CGRect, tailDown: Bool) {
        let visible = screen.visibleFrame
        let aboveY = petFrame.maxY + gap
        let fitsAbove = aboveY + bubbleSize.height <= visible.maxY
        let tailDown = fitsAbove
        // 上方放不下翻到下方；下方也放不下（宠物贴屏底）时 clamp 到屏底，允许与宠物重叠。
        let y = fitsAbove
            ? aboveY
            : max(petFrame.minY - gap - bubbleSize.height, visible.minY)
        let preferredX = petFrame.midX - bubbleSize.width / 2
        let minX = visible.minX + horizontalInset
        let maxX = visible.maxX - horizontalInset - bubbleSize.width
        let x = min(max(preferredX, minX), max(minX, maxX))
        return (CGRect(origin: CGPoint(x: x, y: y), size: bubbleSize), tailDown)
    }
}
