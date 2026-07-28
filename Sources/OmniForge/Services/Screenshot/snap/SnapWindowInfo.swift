import CoreGraphics
import Foundation

/// Window Server 窗口快照（CG 全局坐标，列表顺序 = 前→后 z-order）。
struct SnapWindowInfo: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bounds: CGRect
    let layer: Int
}

/// 解析 `CGWindowListCopyWindowInfo` 条目为有序窗口列表。
enum SnapWindowListParser {
    /// - Parameters:
    ///   - entries: 前→后有序的窗口字典。
    ///   - excludingOwnerPID: 剔除的 owner（通常为本 app overlay）。
    /// - Returns: 有效尺寸、非 excluded 的窗口，保持原顺序。
    static func parse(
        _ entries: [[String: Any]],
        excludingOwnerPID: pid_t
    ) -> [SnapWindowInfo] {
        var result: [SnapWindowInfo] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            guard let pid = ownerPID(from: entry), pid != excludingOwnerPID else { continue }
            guard let windowID = windowID(from: entry) else { continue }
            guard let bounds = bounds(from: entry), bounds.width > 0, bounds.height > 0 else { continue }
            let layer = (entry[kCGWindowLayer as String] as? Int)
                ?? (entry[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? 0
            result.append(SnapWindowInfo(
                windowID: windowID,
                ownerPID: pid,
                bounds: bounds,
                layer: layer
            ))
        }
        return result
    }

    private static func ownerPID(from entry: [String: Any]) -> pid_t? {
        if let pid = entry[kCGWindowOwnerPID as String] as? pid_t { return pid }
        if let number = entry[kCGWindowOwnerPID as String] as? NSNumber { return number.int32Value }
        return nil
    }

    private static func windowID(from entry: [String: Any]) -> CGWindowID? {
        if let id = entry[kCGWindowNumber as String] as? CGWindowID { return id }
        if let number = entry[kCGWindowNumber as String] as? NSNumber {
            return CGWindowID(number.uint32Value)
        }
        return nil
    }

    private static func bounds(from entry: [String: Any]) -> CGRect? {
        guard let dict = entry[kCGWindowBounds as String] as? [String: Any]
                ?? entry[kCGWindowBounds as String] as? [String: CGFloat]
                ?? (entry[kCGWindowBounds as String] as? NSDictionary) as? [String: Any]
        else { return nil }
        // CGRect(dictionaryRepresentation:) 需要 CFDictionary
        if let nsDict = entry[kCGWindowBounds as String] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: nsDict as CFDictionary) {
            return rect
        }
        guard let x = cgFloat(dict["X"]),
              let y = cgFloat(dict["Y"]),
              let w = cgFloat(dict["Width"]),
              let h = cgFloat(dict["Height"]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func cgFloat(_ value: Any?) -> CGFloat? {
        if let v = value as? CGFloat { return v }
        if let v = value as? Double { return CGFloat(v) }
        if let v = value as? NSNumber { return CGFloat(truncating: v) }
        return nil
    }
}

/// 按 z-order 解析鼠标下最前窗口与其前方遮挡窗。
enum UnderlyingWindowResolver {
    /// 从前到后找第一个 bounds 包含点、且 owner 未被排除的窗口。
    static func topmost(
        at point: CGPoint,
        in windows: [SnapWindowInfo],
        excludingOwnerPID: pid_t
    ) -> SnapWindowInfo? {
        candidatesContaining(point, in: windows, excludingOwnerPID: excludingOwnerPID).first
    }

    /// 所有 bounds 包含点的窗口，前→后（用于 frontmost AX 失败时回退菜单栏等）。
    static func candidatesContaining(
        _ point: CGPoint,
        in windows: [SnapWindowInfo],
        excludingOwnerPID: pid_t
    ) -> [SnapWindowInfo] {
        windows.filter { $0.ownerPID != excludingOwnerPID && $0.bounds.contains(point) }
    }

    /// 返回列表中位于 `target` 之前（更前层）的窗口，保持前→后顺序。
    ///
    /// 系统 UI 窗口（Dock/菜单栏/状态项，layer ≥ dockWindow）不计为遮挡：
    /// 它们是事件层或仅占顶部条带，把 Dock 的全屏事件 bounds 当作 app 候选的
    /// 遮挡会错误地裁空候选。仅保留 layer 0 的真实 app 窗口半遮挡关系。
    static func occluders(
        inFrontOf target: SnapWindowInfo,
        in windows: [SnapWindowInfo],
        excludingOwnerPID: pid_t
    ) -> [SnapWindowInfo] {
        let systemLayerFloor = Int(CGWindowLevelForKey(.dockWindow))  // 20
        var result: [SnapWindowInfo] = []
        for window in windows {
            if window.windowID == target.windowID, window.ownerPID == target.ownerPID {
                break
            }
            if window.ownerPID == excludingOwnerPID { continue }
            if window.layer >= systemLayerFloor { continue }
            result.append(window)
        }
        return result
    }
}

/// 多屏 hover 路由：按 AppKit 全局鼠标点选择目标屏与局部点。
struct SnapHoverScreen: Equatable {
    let id: String
    let frame: NSRect
}

enum SnapHoverRouter {
    struct Target: Equatable {
        let id: String
        let localPoint: CGPoint
        let screenFrame: NSRect
    }

    static func target(
        mouseAppKitGlobal: CGPoint,
        screens: [SnapHoverScreen]
    ) -> Target? {
        for screen in screens where screen.frame.contains(mouseAppKitGlobal) {
            return Target(
                id: screen.id,
                localPoint: CGPoint(
                    x: mouseAppKitGlobal.x - screen.frame.minX,
                    y: mouseAppKitGlobal.y - screen.frame.minY
                ),
                screenFrame: screen.frame
            )
        }
        return nil
    }
}

/// 用更前层窗口矩形裁切候选，得到仍包含鼠标点的可见轴对齐矩形。
enum SnapOcclusionClipper {
    /// - Parameters:
    ///   - candidate: 候选完整 frame（CG 全局）。
    ///   - point: 鼠标点（必须落在最终可见矩形内）。
    ///   - occluders: 更前层窗口 bounds（CG 全局）。
    ///   - minSize: 裁切后任一边长低于此值则丢弃。
    /// - Returns: 含鼠标点的可见矩形；无法得到则 nil。
    static func clip(
        candidate: CGRect,
        containing point: CGPoint,
        occluders: [CGRect],
        minSize: CGFloat = 1
    ) -> CGRect? {
        guard candidate.contains(point) else { return nil }

        var remaining = [candidate]
        for occluder in occluders {
            guard occluder.intersects(candidate) || remaining.contains(where: { $0.intersects(occluder) }) else {
                continue
            }
            if occluder.contains(point) {
                return nil
            }
            var next: [CGRect] = []
            next.reserveCapacity(remaining.count * 4)
            for rect in remaining {
                next.append(contentsOf: subtract(rect, minus: occluder))
            }
            remaining = next
            if remaining.isEmpty { return nil }
        }

        // 取仍包含鼠标点的矩形；若有多块，选面积最大者（通常只有一块含点）。
        let containing = remaining.filter { $0.contains(point) }
        guard let best = containing.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }
        if best.width < minSize || best.height < minSize {
            return nil
        }
        return best
    }

    /// 轴对齐矩形差集：`rect - hole`，拆成最多 4 个不相交矩形。
    private static func subtract(_ rect: CGRect, minus hole: CGRect) -> [CGRect] {
        let inter = rect.intersection(hole)
        guard !inter.isNull, !inter.isEmpty else { return [rect] }
        if inter == rect { return [] }

        var parts: [CGRect] = []
        // 上
        if inter.minY > rect.minY {
            parts.append(CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: inter.minY - rect.minY
            ))
        }
        // 下
        if inter.maxY < rect.maxY {
            parts.append(CGRect(
                x: rect.minX,
                y: inter.maxY,
                width: rect.width,
                height: rect.maxY - inter.maxY
            ))
        }
        // 左（中间条带高度 = inter 高度，避免与上下重叠）
        if inter.minX > rect.minX {
            parts.append(CGRect(
                x: rect.minX,
                y: inter.minY,
                width: inter.minX - rect.minX,
                height: inter.height
            ))
        }
        // 右
        if inter.maxX < rect.maxX {
            parts.append(CGRect(
                x: inter.maxX,
                y: inter.minY,
                width: rect.maxX - inter.maxX,
                height: inter.height
            ))
        }
        return parts.filter { $0.width > 0 && $0.height > 0 }
    }
}
