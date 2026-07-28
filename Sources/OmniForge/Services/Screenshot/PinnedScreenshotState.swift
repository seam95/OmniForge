import CoreGraphics
import Foundation

/// 单钉图交互状态（挂在控制器实例上，禁止全局单例）。
/// 决策 8.5-9：`isLocked` 与 `isClickThrough` 独立，无隐式联动。
struct PinnedScreenshotState: Equatable, Sendable {
    var scale: CGFloat
    var opacity: CGFloat
    var isLocked: Bool
    var isClickThrough: Bool

    init(
        scale: CGFloat = PinnedScreenshotGeometry.defaultScale,
        opacity: CGFloat = PinnedScreenshotGeometry.defaultOpacity,
        isLocked: Bool = false,
        isClickThrough: Bool = false
    ) {
        self.scale = PinnedScreenshotGeometry.clampedScale(scale)
        self.opacity = PinnedScreenshotGeometry.clampedOpacity(opacity)
        self.isLocked = isLocked
        self.isClickThrough = isClickThrough
    }

    /// 锁定时拒绝位移；解锁返回 delta。
    func proposedTranslation(_ delta: CGPoint) -> CGPoint? {
        guard !isLocked else { return nil }
        guard delta.x.isFinite, delta.y.isFinite else { return nil }
        return delta
    }

    /// 锁定时拒绝缩放；解锁返回夹取后的新 scale。
    /// 已在 min/max 且 factor 继续外扩时返回 nil，避免 frame 与 scale 不一致。
    func proposedScale(multiplying factor: CGFloat) -> CGFloat? {
        guard !isLocked else { return nil }
        guard factor.isFinite, factor > 0 else { return nil }
        let next = scale * factor
        let clamped = PinnedScreenshotGeometry.clampedScale(next)
        // 无有效变化（含已触顶/触底仍外扩）：调用方应 no-op，不改窗口 frame
        if clamped == scale {
            return nil
        }
        return clamped
    }

    mutating func applyScale(_ newScale: CGFloat) -> Bool {
        guard !isLocked else { return false }
        scale = PinnedScreenshotGeometry.clampedScale(newScale)
        return true
    }

    mutating func setOpacity(_ value: CGFloat) {
        opacity = PinnedScreenshotGeometry.clampedOpacity(value)
    }

    /// 独立切换锁定，不改变穿透。
    mutating func setLocked(_ value: Bool) {
        isLocked = value
    }

    /// 独立切换穿透，不改变锁定。
    mutating func setClickThrough(_ value: Bool) {
        isClickThrough = value
    }
}

/// 托盘/管理 API 展示用句柄（不含拖拽临时状态）。
struct PinnedScreenshotHandle: Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let isLocked: Bool
    let isClickThrough: Bool
    let opacity: CGFloat
    let scale: CGFloat
    let pixelWidth: Int
    let pixelHeight: Int
    /// 菜单文案用短标识（如尺寸）。
    var displayLabel: String {
        "\(pixelWidth)×\(pixelHeight)"
    }
}

enum PinnedScreenshotError: Error, Equatable {
    case invalidImage
    case invalidGeometry
    case notFound(UUID)
    case alreadyClosed(UUID)
    case copyFailed(String)
    case saveFailed(String)
}
