import AppKit
import Foundation

/// 图片剪贴板写入边界（供 Fake 替身）。
protocol ClipboardImageWriting: AnyObject {
    /// 将编码后的图像写入剪贴板。
    /// - Returns: 是否写入成功（clearContents + setData 均成功）。
    @discardableResult
    func writeImage(_ output: EncodedImageOutput) -> Bool
}

/// 图片剪贴板写入生产实现。
///
/// 复用 OmniForge 现有的 `PasteboardWriting` / `SystemPasteboardWriter`
/// （`ClipboardPasteService.swift`）。参照 capcap
/// `ClipboardManager.copyToClipboard(imageOutput:)`（L32-39）：
/// clearContents 后 PNG + TIFF 双写，pasteboardType 恒 `.png`。
final class ClipboardImageWriter: ClipboardImageWriting {
    private let pasteboard: PasteboardWriting

    init(pasteboard: PasteboardWriting = SystemPasteboardWriter()) {
        self.pasteboard = pasteboard
    }

    @discardableResult
    func writeImage(_ output: EncodedImageOutput) -> Bool {
        pasteboard.clearContents()
        let pngOK = pasteboard.setData(output.data, forType: output.pasteboardType)
        // TIFF 备份（兼容偏好 TIFF 的应用）；失败不致命，PNG 成功即可。
        if let tiffData = tiffData(from: output) {
            _ = pasteboard.setData(tiffData, forType: .tiff)
        }
        return pngOK
    }

    /// 从编码输出（PNG）解码回位图再转 TIFF；不可得则跳过。
    private func tiffData(from output: EncodedImageOutput) -> Data? {
        guard let image = NSImage(data: output.data) else { return nil }
        return image.tiffRepresentation
    }
}
