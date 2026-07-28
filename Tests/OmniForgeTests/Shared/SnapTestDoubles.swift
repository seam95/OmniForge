import AppKit
import CoreGraphics
import OmniForge
@testable import OmniForge

/// WindowSnapProvider 测试替身:返回预设候选,记录查询参数。
final class FakeSnapProvider: WindowSnapProvider {
    var stubbedCandidate: SnapCandidate?
    private(set) var lastQueryPoint: NSPoint?
    private(set) var lastQueryVisibleFrame: NSRect?
    /// 被调用次数（装饰器透传验证用）。
    private(set) var callCount: Int = 0

    func candidate(
        at point: NSPoint,
        in viewBounds: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        primaryDisplayHeight: CGFloat
    ) async -> SnapCandidate? {
        lastQueryPoint = point
        lastQueryVisibleFrame = visibleFrame
        callCount += 1
        _ = primaryDisplayHeight
        return stubbedCandidate
    }
}
