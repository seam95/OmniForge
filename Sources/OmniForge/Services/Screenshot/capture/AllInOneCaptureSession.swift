import AppKit
import CoreGraphics
import Foundation

/// 全能截图会话编排：先遮罩，后异步冻屏注入 → 选区 → 编辑器（或 copy/pin 直出）。
/// 本类型只编排流程，不实现标注逻辑。
@MainActor
final class AllInOneCaptureSession: ScreenshotCaptureSession {
    private let captureClient: ScreenCaptureClient
    private let overlayController: CaptureOverlayController
    private let onComplete: (NSImage?) -> Void
    /// 入口意图：`.copy` / `.pin` 时 overlay 选区确认后直出，不进编辑器。
    private let entryIntent: ScreenshotEntryIntent?

    /// 测试钩子：覆盖冻屏枚举用的 display ID 列表。nil 时用 `NSScreen.screens`。
    /// 仅影响 Task.detached 冻屏路径，不改变 startCapture 空预抓行为。
    var freezeDisplayIDsForTesting: [CGDirectDisplayID]?

    init(
        captureClient: ScreenCaptureClient,
        overlayController: CaptureOverlayController,
        entryIntent: ScreenshotEntryIntent? = nil,
        onComplete: @escaping (NSImage?) -> Void
    ) {
        self.captureClient = captureClient
        self.overlayController = overlayController
        self.entryIntent = entryIntent
        self.onComplete = onComplete
    }

    /// 启动全能截图会话：遮罩立即出现，冻屏在后台抓取后注入。
    func start() {
        // 透传 copy/pin 直出意图；nil 表示常规全能路径（进编辑器）。
        overlayController.entryIntent = entryIntent

        // 1. 先出遮罩（空预抓），不在主线程同步多屏 CGWindowList。
        // 编辑器嵌入与拆解由 CaptureOverlayController 自行管理，
        // 回调在编辑器关闭后才触发（合成图或 nil）。
        overlayController.startCapture(screenSnapshots: [:]) { [weak self] finalImage in
            self?.onComplete(finalImage)
        }

        // 2. 后台冻屏；完成后主线程 apply。
        // generation + isTornDown：旧会话 Task 不得写入复用后的新 overlay 会话。
        let client = captureClient
        let generation = overlayController.snapshotGeneration
        let screens = freezeDisplayIDsForTesting
            ?? NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
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
                overlay?.applyScreenSnapshots(frozenSnapshots, generation: generation)
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
