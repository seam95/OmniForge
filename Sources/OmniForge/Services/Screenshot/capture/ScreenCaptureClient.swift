import CoreGraphics
import Foundation

/// 屏幕捕获客户端协议。
/// 生产实现使用 ScreenCaptureKit + CGWindowList；
/// 测试使用 Fake 替身。
protocol ScreenCaptureClient {
    /// 捕获指定显示器的全屏图像。
    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage

    /// 捕获指定显示器上的区域，可排除指定窗口（如长截图 hint toast）。
    func captureRegion(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage

    /// 预抓整屏快照，可排除指定窗口。
    /// 冻屏发生在遮罩显示之后，必须排除 overlay 自身窗口，否则快照会把暗化遮罩烤进底图。
    func captureSnapshot(
        displayID: CGDirectDisplayID,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage
}

extension ScreenCaptureClient {
    /// 兼容旧调用：默认不排除任何窗口。
    func captureRegion(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat
    ) async throws -> CGImage {
        try await captureRegion(rect, displayID: displayID, scaleFactor: scaleFactor, excludingWindowIDs: [])
    }
}

/// 捕获错误。
enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    case captureFailed(String)
    case timeout
    case invalidDisplay
    case invalidRect
}
