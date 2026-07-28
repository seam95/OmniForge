import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit + CGWindowList 实现的屏幕捕获客户端。
final class ScreenCaptureKitClient: ScreenCaptureClient {
    private let preflightAccess: () -> Bool

    init(preflightAccess: @escaping () -> Bool = { true }) {
        self.preflightAccess = preflightAccess
    }

    // MARK: - ScreenCaptureClient

    func captureDisplay(displayID: CGDirectDisplayID) async throws -> CGImage {
        guard preflightAccess() else { throw ScreenCaptureError.permissionDenied }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.invalidDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.captureResolution = .best

        let displayBounds = CGDisplayBounds(displayID)
        let scale = max(CGFloat(filter.pointPixelScale), 1)
        config.width = max(Int(ceil(displayBounds.width * scale)), 1)
        config.height = max(Int(ceil(displayBounds.height * scale)), 1)

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func captureRegion(
        _ rect: CGRect,
        displayID: CGDirectDisplayID,
        scaleFactor: CGFloat,
        excludingWindowIDs: [CGWindowID]
    ) async throws -> CGImage {
        guard preflightAccess() else { throw ScreenCaptureError.permissionDenied }
        guard rect.width > 0, rect.height > 0 else { throw ScreenCaptureError.invalidRect }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.invalidDisplay
        }

        let excludedWindows: [SCWindow]
        if excludingWindowIDs.isEmpty {
            excludedWindows = []
        } else {
            let idSet = Set(excludingWindowIDs)
            excludedWindows = content.windows.filter { idSet.contains($0.windowID) }
        }

        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        // sourceRect 必须在显示器的本地坐标系中（该显示器的左上原点），
        // 而非全局 CG 坐标系。扩展屏的 CGDisplayBounds.origin 非零时，
        // 传入全局坐标会捕获错误区域。
        let displayBounds = CGDisplayBounds(displayID)
        let localRect = CGRect(
            x: rect.origin.x - displayBounds.origin.x,
            y: rect.origin.y - displayBounds.origin.y,
            width: rect.width,
            height: rect.height
        )

        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        let scale = max(scaleFactor, 1)
        config.width = max(Int(ceil(rect.width * scale)), 1)
        config.height = max(Int(ceil(rect.height * scale)), 1)
        config.capturesAudio = false
        config.showsCursor = false

        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    func captureSnapshot(displayID: CGDirectDisplayID) -> CGImage? {
        let displayBounds = CGDisplayBounds(displayID)
        return CGWindowListCreateImage(
            displayBounds,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        )
    }
}

// MARK: - 从 CGImage 裁剪选区

extension CGImage {
    /// 从全屏快照中裁剪选区（全局坐标 → 本地坐标 → 像素坐标）。
    func croppingToSelection(globalRect: CGRect, displayID: CGDirectDisplayID) -> CGImage? {
        let displayBounds = CGDisplayBounds(displayID)
        let localRect = CGRect(
            x: globalRect.origin.x - displayBounds.origin.x,
            y: globalRect.origin.y - displayBounds.origin.y,
            width: globalRect.width,
            height: globalRect.height
        )
        let scaleX = CGFloat(width) / displayBounds.width
        let scaleY = CGFloat(height) / displayBounds.height
        let imageRect = CGRect(
            x: localRect.origin.x * scaleX,
            y: localRect.origin.y * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        )
        return cropping(to: imageRect)
    }
}
