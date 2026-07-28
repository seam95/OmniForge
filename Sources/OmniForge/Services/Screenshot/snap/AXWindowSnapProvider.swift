import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AX 命中元素的窗口吸附 provider(主实现,需辅助功能权限)。
///
/// 流程：
/// 1. Window Server 有序窗口 → 所有含点的候选（前→后）
/// 2. 按序对每个 owner 做 AX 命中；前序失败则回退下一窗（菜单栏/状态项常需此路径）
/// 3. 用该窗前方遮挡裁切可见矩形
final class AXWindowSnapProvider: WindowSnapProvider {
    private let minSnapSize: CGFloat
    private let windowListProvider: () -> [SnapWindowInfo]

    /// - Parameters:
    ///   - minSnapSize: 候选元素最小边长阈值,默认 20pt。
    ///   - windowListProvider: 自定义窗口列表(测试注入)；默认读 CGWindowList。
    init(
        minSnapSize: CGFloat = 20,
        windowListProvider: (() -> [SnapWindowInfo])? = nil
    ) {
        self.minSnapSize = minSnapSize
        self.windowListProvider = windowListProvider ?? AXWindowSnapProvider.defaultWindows
    }

    func candidate(
        at point: NSPoint,
        in viewBounds: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        primaryDisplayHeight: CGFloat
    ) async -> SnapCandidate? {
        _ = visibleFrame  // AX/元素级吸附不依赖边缘几何；由外层装饰器处理。
        let cgPoint = SnapCoordinate.cgPoint(
            viewPoint: point,
            screenFrame: screenFrame,
            primaryDisplayHeight: primaryDisplayHeight
        )
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let windows = windowListProvider()

        // 系统 UI 窗口（菜单栏/状态项）直选：它们的 owner 是系统进程，AX hit-test 永久失败，
        // 但 CGWindowList bounds 本身就是合法候选。优先于 AX 路径处理。
        // （windows 已在解析时排除 selfPID，本 app 自己的状态项不会被误吸。）
        if let systemPick = SystemWindowSnapPicker.pick(at: cgPoint, in: windows) {
            let viewRect = SnapCoordinate.viewRect(
                cgRect: systemPick.bounds,
                screenFrame: screenFrame,
                primaryDisplayHeight: primaryDisplayHeight
            )
            if viewBounds.intersects(viewRect) {
                return SnapCandidate(rect: viewRect, windowID: systemPick.windowID)
            }
        }

        let hits = UnderlyingWindowResolver.candidatesContaining(
            cgPoint,
            in: windows,
            excludingOwnerPID: selfPID
        )

        // 同一 pid 只 hit 一次，避免多层窗重复 IPC。
        var triedPIDs = Set<pid_t>()
        for top in hits {
            if triedPIDs.contains(top.ownerPID) { continue }
            triedPIDs.insert(top.ownerPID)

            guard let element = hitTest(pid: top.ownerPID, cgPoint: cgPoint) else { continue }
            guard let result = AXSnapAncestor.smallestSnapAncestor(
                of: element,
                minSize: minSnapSize,
                frameReader: AXFrameReader.frame,
                roleReader: AXFrameReader.role,
                parentReader: AXFrameReader.parent
            ) else { continue }

            let frontBounds = UnderlyingWindowResolver.occluders(
                inFrontOf: top,
                in: windows,
                excludingOwnerPID: selfPID
            ).map(\.bounds)

            guard let visibleCG = SnapOcclusionClipper.clip(
                candidate: result.rect,
                containing: cgPoint,
                occluders: frontBounds,
                minSize: minSnapSize
            ) else { continue }

            let viewRect = SnapCoordinate.viewRect(
                cgRect: visibleCG,
                screenFrame: screenFrame,
                primaryDisplayHeight: primaryDisplayHeight
            )
            guard viewBounds.intersects(viewRect) else { continue }

            let windowID = AXWindowResolver.windowID(for: element) ?? top.windowID
            return SnapCandidate(rect: viewRect, windowID: windowID)
        }
        return nil
    }

    // MARK: - AX hit-test

    private func hitTest(pid: pid_t, cgPoint: CGPoint) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            app, Float(cgPoint.x), Float(cgPoint.y), &element
        ) == .success else { return nil }
        return element
    }

    // MARK: - 窗口列表

    private static func defaultWindows() -> [SnapWindowInfo] {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return SnapWindowListParser.parse(list, excludingOwnerPID: selfPID)
    }
}
