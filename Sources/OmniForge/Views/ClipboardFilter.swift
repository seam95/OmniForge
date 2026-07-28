import Foundation

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case url
    case rtf

    var id: String { rawValue }

    /// 返回该筛选器的本地化标签
    func label(in strings: Strings) -> String {
        switch self {
        case .all: return strings.clipboardFilterAll
        case .text: return strings.clipboardFilterText
        case .image: return strings.clipboardFilterImage
        case .file: return strings.clipboardFilterFile
        case .url: return strings.clipboardFilterUrl
        case .rtf: return strings.clipboardFilterRtf
        }
    }

    func matches(_ type: ClipboardContentType) -> Bool {
        switch self {
        case .all:
            return true
        case .text:
            return type == .text
        case .image:
            return type == .image
        case .file:
            return type == .file
        case .url:
            return type == .url
        case .rtf:
            return type == .rtf
        }
    }
}

