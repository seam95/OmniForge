import AppKit
import CoreGraphics
import Foundation

/// 全能截图会话编排：冻屏快照 → 选区遮罩 → 编辑器。
/// 本类型只编排流程，不实现标注逻辑。
@MainActor
final class AllInOneCaptureSession: ScreenshotCaptureSession {
    private let captureClient: ScreenCaptureClient
    private let overlayController: CaptureOverlayController
    private let onComplete: (NSImage?) -> Void

    init(
        captureClient: ScreenCaptureClient,
        overlayController: CaptureOverlayController,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.captureClient = captureClient
        self.overlayController = overlayController
        self.onComplete = onComplete
    }

    /// 启动全能截图会话。
    func start() {
        // 预抓每屏快照
        var snapshots: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            if let snapshot = captureClient.captureSnapshot(displayID: displayID) {
                snapshots[displayID] = snapshot
            }
        }

        // 开遮罩 → 选区 → 嵌入编辑器 → 回调。
        // 编辑器嵌入与拆解由 CaptureOverlayController 自行管理，
        // 回调在编辑器关闭后才触发（合成图或 nil）。
        overlayController.startCapture(
            screenSnapshots: snapshots
        ) { [weak self] finalImage in
            guard let self else { return }
            self.onComplete(finalImage)
        }
    }

    /// 取消会话。
    func cancel() {
        overlayController.tearDown()
        onComplete(nil)
    }
}

extension NSScreen {
    /// 获取该屏幕的 CGDirectDisplayID。
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
