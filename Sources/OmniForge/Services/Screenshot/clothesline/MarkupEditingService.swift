// Sources/OmniForge/Services/Screenshot/clothesline/MarkupEditingService.swift
import AppKit
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.omniforge.app", category: "ClotheslineMarkup")

protocol MarkupFileIO: AnyObject {
    func dataContents(of url: URL) -> Data?
    func write(data: Data, to url: URL) throws
}

final class DefaultMarkupFileIO: MarkupFileIO {
    func dataContents(of url: URL) -> Data? { try? Data(contentsOf: url) }
    func write(data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

/// 调起系统 Markup 标注扩展（截图缩略图点开的那个编辑窗），保存后写回原文件。
/// 无扩展时回退默认应用打开。
@MainActor
final class MarkupEditingService: NSObject, NSSharingServiceDelegate {
    static let shared = MarkupEditingService()

    /// 编辑写回成功后回调（刷新绳上缩略图）。
    var onSaved: (URL) -> Void = { _ in }

    private var editing: URL?
    private let io: MarkupFileIO
    private static let serviceName = NSSharingService.Name("com.apple.MarkupUI.Markup")

    init(io: MarkupFileIO = DefaultMarkupFileIO()) {
        self.io = io
        super.init()
    }

    func edit(_ url: URL) {
        guard let service = NSSharingService(named: Self.serviceName),
              service.canPerform(withItems: [url])
        else {
            NSWorkspace.shared.open(url)   // 无扩展：预览是最接近的替代
            return
        }
        editing = url
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }

    // MARK: NSSharingServiceDelegate

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            guard let target = editing else { return }
            editing = nil
            if Self.writeBack(items: items, target: target, io: io) {
                onSaved(target)
            }
        }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService,
                                    didFailToShareItems items: [Any], error: Error) {
        log.notice("Markup 未保存结束 \(error.localizedDescription, privacy: .public)")
    }

    // MARK: 写回分发（纯逻辑，可测）

    /// 扩展可能回传 URL / NSImage / NSItemProvider 三种形态。
    /// 返回是否写回成功。同路径短路（扩展自行覆盖）。
    /// nonisolated：纯同步分发、不触及主线程状态，脱离类级 @MainActor 才可在测试中直接调用。
    @discardableResult
    nonisolated static func writeBack(items: [Any], target: URL, io: MarkupFileIO) -> Bool {
        guard let item = items.first else { return false }
        switch item {
        case let url as URL:
            if url.standardizedFileURL == target.standardizedFileURL { return true }
            guard let data = io.dataContents(of: url) else { return false }
            return write(data: data, to: target, io: io)
        case let image as NSImage:
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { return false }
            return write(data: png, to: target, io: io)
        default:
            return false   // NSItemProvider 异步路径走 edit 流程内处理，writeBack 只管同步形态
        }
    }

    nonisolated private static func write(data: Data, to target: URL, io: MarkupFileIO) -> Bool {
        guard !data.isEmpty else { return false }
        do {
            try io.write(data: data, to: target)
            return true
        } catch {
            log.error("Markup 写回失败 \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
