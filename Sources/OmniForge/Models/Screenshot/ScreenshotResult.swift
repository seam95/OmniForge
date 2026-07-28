import CoreGraphics
import Foundation

/// 窗口模式预留信息（形状在 T5 前保持最小）。
struct CapturedWindowInfo: Equatable, Sendable {
    let windowID: UInt32
    let title: String?
    let bundleIdentifier: String?
}

/// 单目标屏截图结果（决策 8.1-1）。
/// 不含多屏 tile / 合成矩阵 / 跨屏 bounding box。
/// 失败不得用空图 + 成功表达；错误走 ScreenCaptureClientError / ScreenshotResultError。
struct ScreenshotResult {
    let mode: ScreenshotMode
    let targetScreen: CaptureTargetScreen
    /// 全屏可为空；区域模式必有且 displayID 与 targetScreen 一致。
    let selection: CaptureSelection?
    let timestamp: Date
    /// 物理像素、左上原点。
    let pixelImage: CGImage
    let windowInfo: CapturedWindowInfo?

    init(
        mode: ScreenshotMode,
        targetScreen: CaptureTargetScreen,
        selection: CaptureSelection?,
        timestamp: Date,
        pixelImage: CGImage,
        windowInfo: CapturedWindowInfo?
    ) throws {
        try Self.requireValidPixelImageDimensions(
            width: pixelImage.width,
            height: pixelImage.height
        )

        switch mode {
        case .allInOne:
            guard let selection else {
                throw ScreenshotResultError.regionRequiresSelection
            }
            guard selection.targetScreen.displayID == targetScreen.displayID else {
                throw ScreenshotResultError.selectionScreenMismatch
            }
        case .fullScreen:
            if let selection, selection.targetScreen.displayID != targetScreen.displayID {
                throw ScreenshotResultError.selectionScreenMismatch
            }
        }

        self.mode = mode
        self.targetScreen = targetScreen
        self.selection = selection
        self.timestamp = timestamp
        self.pixelImage = pixelImage
        self.windowInfo = windowInfo
    }

    /// 物理像素图尺寸校验（init 与单测共用）。
    /// CGImage 无法构造 0 宽/高，故将 guard 抽为可测路径，避免假绿。
    static func requireValidPixelImageDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw ScreenshotResultError.invalidImageDimensions
        }
    }
}

enum ScreenshotResultError: Error, Equatable {
    case regionRequiresSelection
    case selectionScreenMismatch
    case invalidImageDimensions
}
