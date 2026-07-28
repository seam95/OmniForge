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
        if let data = pasteboard.data(forType: .png) {
            return data
        }
        guard let tiffData = pasteboard.data(forType: .tiff) else {
            return nil
        }
        guard let imageRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return imageRep.representation(using: .png, properties: [:])
    }

    func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    func readRTFData() -> Data? {
        pasteboard.data(forType: .rtf)
    }
}
