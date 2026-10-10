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
    /// 编辑写回成功后回调（把标注结果复制进剪贴板，粘贴即用）。
    var onCopied: (URL) -> Void = { _ in }

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
        scheduleMarkupWindowMovable()
    }

    /// 分享服务把 Markup 扩展 UI 呈现在我们进程里的**无标题无边框**窗口
    /// （实测 styleMask 为 0），且它是离屏宿主窗的**子窗口**——子窗口只能随父
    /// 移动，单开 isMovableByWindowBackground 无效（探针实证：属性写上也不动）。
    /// 系统缩略图那条路给的是带标题栏的独立窗口所以能拖。
    /// 修复：摘掉父窗口成为独立顶层窗 + 开背景拖动，恢复 AppKit 标准的
    /// 无边框可移动语义（拖工具栏/空白区移动；按钮与画布各自消费事件不受影响）。
    /// 标注窗约 1s 后才出现，故轮询重试至多 ~3s。
    private func scheduleMarkupWindowMovable(attempt: Int = 0) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            if self.makeMarkupWindowMovable() { return }
            guard attempt < 10 else { return }
            self.scheduleMarkupWindowMovable(attempt: attempt + 1)
        }
    }

    @discardableResult
    private func makeMarkupWindowMovable() -> Bool {
        var applied = false
        for window in NSApp.windows where window.title == "Markup" {
            window.parent = nil
            window.isMovableByWindowBackground = true
            applied = true
        }
        return applied
    }

    // MARK: NSSharingServiceDelegate

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            guard let target = editing else { return }
            editing = nil
            let item = items.first
            // URL / NSImage 两种同步形态走纯分发（可测）；其余（NSItemProvider）
            // 走异步装载——实测系统扩展常回 provider，漏掉它会静默丢失标注结果。
            if let item, Self.writeBack(items: [item], target: target, io: io) {
                finish(target)
            } else if let provider = item as? NSItemProvider {
                loadProvider(provider, into: target)
            } else {
                log.error("Markup 返回了无法处理的形态：\(String(describing: type(of: item)), privacy: .public)")
            }
        }
    }

    /// 写回成功后的收尾：绳上缩略图刷新 + 复制进剪贴板。
    private func finish(_ target: URL) {
        onSaved(target)
        onCopied(target)
    }

    /// NSItemProvider 异步装载：优先文件 URL，其次原格式/任意图片数据。
    private func loadProvider(_ provider: NSItemProvider, into target: URL) {
        let types = provider.registeredTypeIdentifiers
        log.notice("Markup provider types: \(types.joined(separator: ", "), privacy: .public)")
        if types.contains(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { self.writeBackFile(url, to: target) }
                }
            }
            return
        }
        let original = UTType(filenameExtension: target.pathExtension)?.identifier
        let imageType = types.first { $0 == original }
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        guard let imageType else {
            log.error("Markup provider 无可识别的图片类型")
            return
        }
        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, _ in
            DispatchQueue.main.async {
                self.writeBackData(data, to: target)
            }
        }
    }

    private func writeBackFile(_ source: URL, to target: URL) {
        if source.standardizedFileURL == target.standardizedFileURL {
            finish(target)   // 扩展自行覆盖了原文件
        } else {
            writeBackData(try? Data(contentsOf: source), to: target)
        }
    }

    private func writeBackData(_ data: Data?, to target: URL) {
        guard let data, !data.isEmpty else {
            log.error("Markup provider 未给出有效数据")
            return
        }
        do {
            try data.write(to: target, options: .atomic)
            finish(target)
        } catch {
            log.error("Markup 写回失败 \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
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
