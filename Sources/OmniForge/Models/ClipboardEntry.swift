import CryptoKit
import Foundation
import ImageIO

enum ClipboardContentType: String, Codable, CaseIterable {
    case text
    case image
    case file
    case url
    case rtf
    case unknown
}

enum ClipboardContent: Equatable {
    case text(String?)        // nil = 文本未加载到内存
    case image(Data?)       // nil = blob 未加载到内存
    case files([URL])
    case url(URL)
    case rtf(Data?)         // nil = blob 未加载到内存
    case unknown(Data?)
}

struct ClipboardEntry: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let type: ClipboardContentType
    let preview: String
    let sourceAppBundleID: String?
    let sourceAppName: String?
    let content: ClipboardContent
    let thumbnailData: Data?
    let blobSize: Int64
    let imageWidth: Int?
    let imageHeight: Int?
    let contentHash: Data?

    init(
        id: UUID,
        createdAt: Date,
        type: ClipboardContentType,
        preview: String,
        sourceAppBundleID: String?,
        sourceAppName: String?,
        content: ClipboardContent,
        thumbnailData: Data? = nil,
        blobSize: Int64? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        contentHash: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.preview = preview
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
        self.content = content
        self.thumbnailData = thumbnailData

        // blobSize：优先使用显式值，否则从 content 自动计算
        if let blobSize {
            self.blobSize = blobSize
        } else {
            switch content {
            case .image(let data):
                self.blobSize = Int64(data?.count ?? 0)
            case .rtf(let data):
                self.blobSize = Int64(data?.count ?? 0)
            case .unknown(let data):
                self.blobSize = Int64(data?.count ?? 0)
            case .text(let text):
                self.blobSize = Int64(text?.utf8.count ?? 0)
            case .files, .url:
                self.blobSize = 0
            }
        }

        // imageWidth / imageHeight：优先使用显式值，否则从 image Data 自动提取
        if let imageWidth, let imageHeight {
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
        } else if case .image(let data) = content, let data,
                  let dims = ClipboardEntry.imageDimensions(from: data) {
            self.imageWidth = dims.width
            self.imageHeight = dims.height
        } else {
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
        }

        // contentHash：优先使用显式值，否则从 content 自动计算
        if let contentHash {
            self.contentHash = contentHash
        } else {
            switch content {
            case .image(let data):
                self.contentHash = data.map { Self.sha256($0) }
            case .rtf(let data):
                self.contentHash = data.map { Self.sha256($0) }
            case .unknown(let data):
                self.contentHash = data.map { Self.sha256($0) }
            case .text(let text):
                self.contentHash = text.map { Self.sha256(Data($0.utf8)) }
            case .url(let url):
                self.contentHash = Self.sha256(Data(url.absoluteString.utf8))
            case .files(let urls):
                let joined = urls.map(\.absoluteString).joined(separator: "\n")
                self.contentHash = Self.sha256(Data(joined.utf8))
            }
        }
    }

    /// 从图片 Data 中读取像素尺寸（不解码像素，仅读元数据）
    static func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// 返回 blob Data 置 nil 的轻量副本（保留所有元数据）
    func lightweight() -> ClipboardEntry {
        let lightContent: ClipboardContent
        switch content {
        case .image:
            lightContent = .image(nil)
        case .rtf:
            lightContent = .rtf(nil)
        case .unknown:
            lightContent = .unknown(nil)
        case .text:
            lightContent = .text(nil)
        case .url, .files:
            lightContent = content
        }
        return ClipboardEntry(
            id: id,
            createdAt: createdAt,
            type: type,
            preview: preview,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            content: lightContent,
            thumbnailData: thumbnailData,
            blobSize: blobSize,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            contentHash: contentHash
        )
    }

    /// 替换 content 的副本
    func withContent(_ newContent: ClipboardContent) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            createdAt: createdAt,
            type: type,
            preview: preview,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppName: sourceAppName,
            content: newContent,
            thumbnailData: thumbnailData,
            blobSize: blobSize,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            contentHash: contentHash
        )
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
