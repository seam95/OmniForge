import AppKit

protocol PasteboardClient {
    var changeCount: Int { get }
    func readFileURLs() -> [URL]
    func readURL() -> URL?
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

    func readFileURLs() -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return objects ?? []
    }

    func readURL() -> URL? {
        if let string = pasteboard.string(forType: .URL), let url = URL(string: string) {
            return url
        }
        return nil
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
