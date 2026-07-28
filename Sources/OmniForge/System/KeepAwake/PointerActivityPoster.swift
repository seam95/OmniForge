import CoreGraphics
import Foundation

/// 指针事件发送与位置读取边界。
protocol PointerActivityPosting: AnyObject {
    func currentLocation() -> CGPoint
    func displayBounds(containing point: CGPoint) -> CGRect
    func postMouseMoved(to point: CGPoint) throws
}

/// 可注入的 CoreGraphics 函数表。
struct PointerActivityAPI {
    var currentLocation: () -> CGPoint
    var activeDisplayCount: () -> UInt32
    var activeDisplayList: (_ max: UInt32) -> [CGDirectDisplayID]
    var displayBounds: (_ id: CGDirectDisplayID) -> CGRect
    var postEvent: (_ event: CGEvent?) -> Void
    var makeMouseEvent: (_ location: CGPoint) -> CGEvent?

    static let live = PointerActivityAPI(
        currentLocation: { CGEvent(source: nil)?.location ?? .zero },
        activeDisplayCount: {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            return count
        },
        activeDisplayList: { max in
            var count: UInt32 = 0
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(max))
            CGGetActiveDisplayList(max, &ids, &count)
            return Array(ids.prefix(Int(count)))
        },
        displayBounds: { CGDisplayBounds($0) },
        postEvent: { event in
            event?.post(tap: .cghidEventTap)
        },
        makeMouseEvent: { location in
            let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: location,
                mouseButton: .left
            )
            return event
        }
    )
}

/// 指针微动纯几何：优先 +1，触边时 -1。
enum PointerActivityGeometry {
    static func nudgeTarget(from point: CGPoint, bounds: CGRect) -> CGPoint {
        let maxX = bounds.maxX - 1
        let maxY = bounds.maxY - 1
        let minX = bounds.minX
        let minY = bounds.minY

        // 水平优先；触右边界则向左。
        if point.x + 1 <= maxX {
            return CGPoint(x: point.x + 1, y: point.y)
        }
        if point.x - 1 >= minX {
            return CGPoint(x: point.x - 1, y: point.y)
        }
        // 水平无空间时尝试垂直。
        if point.y + 1 <= maxY {
            return CGPoint(x: point.x, y: point.y + 1)
        }
        if point.y - 1 >= minY {
            return CGPoint(x: point.x, y: point.y - 1)
        }
        // 单点显示器：无法微动，仍返回原点（调用方应视为无位移）。
        return point
    }
}

final class PointerActivityPoster: PointerActivityPosting {
    private let api: PointerActivityAPI

    init(api: PointerActivityAPI = .live) {
        self.api = api
    }

    func currentLocation() -> CGPoint {
        api.currentLocation()
    }

    func displayBounds(containing point: CGPoint) -> CGRect {
        let count = api.activeDisplayCount()
        guard count > 0 else {
            return CGRect(x: point.x, y: point.y, width: 1, height: 1)
        }
        let ids = api.activeDisplayList(count)
        for id in ids {
            let bounds = api.displayBounds(id)
            if bounds.contains(point) {
                return bounds
            }
        }
        // 未命中时回退主屏或首个显示器。
        if let first = ids.first {
            return api.displayBounds(first)
        }
        return CGRect(x: point.x, y: point.y, width: 1, height: 1)
    }

    func postMouseMoved(to point: CGPoint) throws {
        guard let event = api.makeMouseEvent(point) else {
            throw KeepAwakeError.pointerEventFailed
        }
        api.postEvent(event)
    }
}
