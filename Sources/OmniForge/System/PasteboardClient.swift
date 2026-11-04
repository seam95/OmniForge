import AppKit

protocol PasteboardClient {
    var changeCount: Int { get }
    /// 当前剪贴板内容是否被标记为敏感（org.nspasteboard.ConcealedType）。
    var isConcealed: Bool { get }
    func readFileURLs() -> [URL]
    /// public.url 槽位的原始字符串（未编码）。返回原始串而非 URL 对象：
    /// 部分源应用（如 Otty）会把「单词+冒号」的普通文本塞进该槽位，
    /// 归档层需要先做白名单校验、不过时按纯文本保存原文，解析放采集层做。
    func readURLString() -> String?
    func readImageData() -> Data?
    func readText() -> String?
    func readRTFData() -> Data?
}

final class SystemPasteboardClient: PasteboardClient {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    /// nspasteboard.org 联盟约定：1Password / Bitwarden 等密码管理器复制敏感数据时，
    /// 会向剪贴板额外声明 org.nspasteboard.ConcealedType 类型标记，
    /// 要求粘贴板类工具跳过该内容、不写入历史。只检查类型声明，不触碰数据本身。
    var isConcealed: Bool {
        pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true
    }

    func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return objects ?? []
    }

    func readURLString() -> String? {
        pasteboard.string(forType: .URL)
    }

    func readImageData() -> Data? {
        // .png 槽位可能是占位符（微信等只写 4 字节魔数）：必须过可解码校验。
        if let data = pasteboard.data(forType: .png), ClipboardImageDownsampler.isDecodable(data) {
            return data
        }
        if let tiffData = pasteboard.data(forType: .tiff), ClipboardImageDownsampler.isDecodable(tiffData) {
            guard let imageRep = NSBitmapImageRep(data: tiffData) else { return tiffData }
            return imageRep.representation(using: .png, properties: [:]) ?? tiffData
        }
        // 最后经 NSImage 类读取：多表示画布上取得到真实位图表示。
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let tiff = image.tiffRepresentation, ClipboardImageDownsampler.isDecodable(tiff) {
            return NSBitmapImageRep(data: tiff)?
                .representation(using: .png, properties: [:]) ?? tiff
        }
        return nil
    }

    func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    func readRTFData() -> Data? {
        pasteboard.data(forType: .rtf)
    }
}
