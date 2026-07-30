import AppKit
import CoreGraphics
import Foundation

/// 全能截图会话编排：先遮罩，后异步冻屏注入 → 选区 → 编辑器。
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

    /// 启动全能截图会话：遮罩立即出现，冻屏在后台抓取后注入。
    func start() {
        // 1. 先出遮罩（空预抓），不在主线程同步多屏 CGWindowList。
        // 编辑器嵌入与拆解由 CaptureOverlayController 自行管理，
        // 回调在编辑器关闭后才触发（合成图或 nil）。
        overlayController.startCapture(screenSnapshots: [:]) { [weak self] finalImage in
            self?.onComplete(finalImage)
        }

        // 2. 后台冻屏；完成后主线程 apply。cancel/tearDown 后 apply 经 isTornDown no-op。
        let client = captureClient
        let screens = NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
            screen.displayID
        }

        Task.detached(priority: .userInitiated) { [weak overlayController] in
            var snapshots: [CGDirectDisplayID: CGImage] = [:]
            for displayID in screens {
                if let image = client.captureSnapshot(displayID: displayID) {
                    snapshots[displayID] = image
                }
            }
            guard !snapshots.isEmpty else { return }
            let frozenSnapshots = snapshots
            let overlay = overlayController
            await MainActor.run {
                overlay?.applyScreenSnapshots(frozenSnapshots)
            }
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
