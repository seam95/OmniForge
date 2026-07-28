import AppKit
import CoreGraphics
import Foundation

/// 全屏截图会话编排：捕获鼠标所在屏整屏 → 在 overlay 内嵌入编辑器。
///
/// 调整为「捕获整屏 → 开 overlay → 嵌入编辑器 → onComplete」，
/// 与全能截图共用 CaptureOverlayController 的编辑器嵌入路径。
@MainActor
final class FullscreenCaptureSession: ScreenshotCaptureSession {
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

    /// 启动全屏截图会话。
    func start() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let displayID = screen.displayID else {
            onComplete(nil)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let cgImage = try await self.captureClient.captureDisplay(
                    displayID: displayID
                )
                let image = NSImage(cgImage: cgImage, size: screen.frame.size)
                await MainActor.run {
                    // 整屏图像直接进编辑器（共享 overlay 窗口）。
                    self.overlayController.startEditor(with: image, on: screen) { [weak self] finalImage in
                        self?.onComplete(finalImage)
                    }
                }
            } catch {
                await MainActor.run {
                    self.onComplete(nil)
                }
            }
        }
    }

    func cancel() {
        overlayController.tearDown()
        onComplete(nil)
    }
}
