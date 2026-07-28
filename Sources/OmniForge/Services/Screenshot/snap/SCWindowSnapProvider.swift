import AppKit
import CoreGraphics
import ScreenCaptureKit

/// SCWindow 的最小抽象(供纯函数解耦,SCWindow 通过下方空 extension 满足此协议)。
protocol SCWindowLike {
    var frame: CGRect { get }
    var windowID: CGWindowID { get }
}

/// SCWindow 原生即具备 frame/windowID,空 extension 即可满足协议(Swift 不自动推导)。
extension SCWindow: SCWindowLike {}

/// 在 SCWindow 列表中取最顶层命中。
/// SCShareableContent.windows 按 z-order 从前到后返回,数组首位即最顶层。
enum SCWindowPicker {
    /// - Parameters:
    ///   - point: CG 全局坐标点。
    ///   - windows: 按 z-order 从前到后排列的窗口。
    /// - Returns: 第一个 frame 包含该点的窗口(即顶层命中);无则 nil。
    static func topmostWindow<W: SCWindowLike>(
        containing point: CGPoint,
        in windows: [W]
    ) -> W? {
        for window in windows where window.frame.contains(point) {
            return window  // 第一个命中的即顶层
        }
        return nil
    }
}

/// SCShareableContent.windows 整窗吸附 provider(AX 未授权时的降级实现)。
/// 命中最前窗后，用更前层窗口裁切可见矩形（与 AX 路径语义一致）。
final class SCWindowSnapProvider: WindowSnapProvider {
    private let windowListProvider: () async -> [SCWindow]
    private let minSnapSize: CGFloat

    /// - Parameters:
    ///   - windowListProvider: 自定义窗口列表来源(测试注入);
    ///     默认读 `SCShareableContent.current.windows`。
    ///   - minSnapSize: 裁切后最小边长。
    init(
        windowListProvider: (() async -> [SCWindow])? = nil,
        minSnapSize: CGFloat = 20
    ) {
        self.windowListProvider = windowListProvider ?? SCWindowSnapProvider.defaultWindows
        self.minSnapSize = minSnapSize
    }

    func candidate(
        at point: NSPoint,
        in viewBounds: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        primaryDisplayHeight: CGFloat
    ) async -> SnapCandidate? {
        _ = visibleFrame  // 整窗吸附不依赖边缘几何；由外层装饰器处理。
        let cgPoint = SnapCoordinate.cgPoint(
            viewPoint: point,
            screenFrame: screenFrame,
            primaryDisplayHeight: primaryDisplayHeight
        )
        let windows = await windowListProvider().filter {
            $0.isOnScreen
                && $0.owningApplication != nil
                && SCWindowSnapEligibility.isEligible(windowLayer: $0.windowLayer)
        }
        guard let hit = SCWindowPicker.topmostWindow(containing: cgPoint, in: windows) else {
            return nil
        }

        // 更前层窗口 bounds 作为遮挡（数组中 hit 之前的项）。
        var frontBounds: [CGRect] = []
        for window in windows {
            if window.windowID == hit.windowID { break }
            frontBounds.append(window.frame)
        }

        guard let visibleCG = SnapOcclusionClipper.clip(
            candidate: hit.frame,
            containing: cgPoint,
            occluders: frontBounds,
            minSize: minSnapSize
        ) else { return nil }

        let viewRect = SnapCoordinate.viewRect(
            cgRect: visibleCG,
            screenFrame: screenFrame,
            primaryDisplayHeight: primaryDisplayHeight
        )
        guard viewBounds.intersects(viewRect) else { return nil }
        return SnapCandidate(rect: viewRect, windowID: hit.windowID)
    }

    private static func defaultWindows() async -> [SCWindow] {
        (try? await SCShareableContent.current.windows) ?? []
    }
}
