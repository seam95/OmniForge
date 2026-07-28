import AppKit
import Foundation

/// 截图静默保存错误。参照 SPEC「禁止静默伪造成功」。
enum ScreenshotSavingError: Error, LocalizedError, Equatable {
    /// 目录创建失败。
    case directoryCreationFailed(String)
    /// 文件写入失败。
    case writeFailed(String)
    /// 编码后的数据为空。
    case emptyPayload

    var errorDescription: String? {
        switch self {
        case let .directoryCreationFailed(path): return "Could not create directory \(path)"
        case let .writeFailed(path): return "Could not write file \(path)"
        case .emptyPayload: return "Encoded image payload is empty"
        }
    }
}

/// 截图静默保存边界（供 Fake 替身）。
///
/// 用户已确认偏离 SPEC §6.2 的 NSSavePanel，改为 capcap 式静默保存
/// （参照 `EditWindowController.save` L1662-1716）。
protocol ScreenshotSaving: AnyObject {
    /// 将编码后的图像静默保存到指定目录。
    /// - Parameters:
    ///   - output: 编码后的图像输出。
    ///   - quality: 质量档位（影响默认扩展名）。
    ///   - fileName: 可选文件名（不含目录）；为空时用时间戳模板。
    ///   - directory: 可选目录；为空时默认 `~/Desktop`。
    /// - Returns: 最终写入的文件 URL。
    func save(
        output: EncodedImageOutput,
        quality: ScreenshotImageQuality,
        fileName: String?,
        directory: URL?
    ) throws -> URL
}

/// 截图静默保存生产实现。
final class ScreenshotSaver: ScreenshotSaving {
    /// 默认保存目录（`~/Desktop`）。
    static let defaultDirectory: URL = {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
    }()

    private let fileManager: FileManager
    private let now: () -> Date

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now
    }

    func save(
        output: EncodedImageOutput,
        quality: ScreenshotImageQuality,
        fileName: String?,
        directory: URL?
    ) throws -> URL {
        guard !output.data.isEmpty else {
            throw ScreenshotSavingError.emptyPayload
        }

        let targetDirectory = directory ?? Self.defaultDirectory
        try ensureDirectory(targetDirectory)

        let name = fileName.map(Self.cleanFileName) ??
            Self.timestampedFileName(quality: quality, date: now())
        let uniqueURL = try uniqueFileURL(in: targetDirectory, fileName: name)

        do {
            try output.data.write(to: uniqueURL, options: .atomic)
        } catch {
            throw ScreenshotSavingError.writeFailed(uniqueURL.path)
        }
        return uniqueURL
    }

    // MARK: - 内部

    private func ensureDirectory(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw ScreenshotSavingError.directoryCreationFailed(url.path)
        }
    }

    /// 同名文件去重：`Screenshot-...png` → `Screenshot-...-1.png`。
    /// 参照 capcap `SaveDestination.uniqueFile` 思路。
    private func uniqueFileURL(in directory: URL, fileName: String) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        if !fileManager.fileExists(atPath: url.path) {
            return url
        }
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for index in 1..<10_000 {
            let candidateName = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // 超过上限视为写入失败（避免无限循环 / 不伪造成功）。
        throw ScreenshotSavingError.writeFailed(url.path)
    }

    /// 文件名模板：`Screenshot-yyyyMMdd-HHmmss.png`。
    static func timestampedFileName(quality: ScreenshotImageQuality, date: Date) -> String {
        timestampedFileName(prefix: "Screenshot", quality: quality, date: date)
    }

    /// 文件名模板：`<prefix>-yyyyMMdd-HHmmss.<ext>`。
    static func timestampedFileName(
        prefix: String,
        quality: ScreenshotImageQuality,
        date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safePrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrefix = safePrefix.isEmpty ? "Screenshot" : safePrefix
        return "\(resolvedPrefix)-\(formatter.string(from: date)).\(quality.fileExtension)"
    }

    /// 去除多余空白与意外路径分隔符；缺扩展名时补 quality 默认扩展名。
    static func cleanFileName(_ fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let noSlash = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let stem = (noSlash as NSString).deletingPathExtension
        let ext = (noSlash as NSString).pathExtension
        if ext.isEmpty {
            return "\(stem).png"
        }
        return noSlash
    }
}
