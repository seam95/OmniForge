import Foundation

protocol ClipboardStore {
    func loadEntries() -> [ClipboardEntry]
    func saveEntries(_ entries: [ClipboardEntry])
    func saveEntry(_ entry: ClipboardEntry)
    func deleteEntries(ids: Set<UUID>)
    func loadFullContent(for entryID: UUID) -> ClipboardContent?
    func releaseMemory()
}

// 默认实现（基于旧 API），保证 FakeClipboardStore / FileClipboardStore 编译通过
extension ClipboardStore {
    func saveEntry(_ entry: ClipboardEntry) {
        var all = loadEntries()
        all.removeAll { $0.id == entry.id }
        all.insert(entry, at: 0)
        saveEntries(all)
    }

    func deleteEntries(ids: Set<UUID>) {
        saveEntries(loadEntries().filter { !ids.contains($0.id) })
    }

    func loadFullContent(for entryID: UUID) -> ClipboardContent? {
        loadEntries().first { $0.id == entryID }?.content
    }
}

final class FileClipboardStore: ClipboardStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let entriesFileName = "entries.json"
    private let blobsDirectoryName = "blobs"

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        ensureDirectories()
    }

    func loadEntries() -> [ClipboardEntry] {
        loadCompleteEntries().map { $0.lightweight() }
    }

    func releaseMemory() {
        // 文件实现不持有内存缓存。
    }

    func saveEntry(_ entry: ClipboardEntry) {
        var all = loadCompleteEntries()
        all.removeAll { $0.id == entry.id }
        all.insert(entry, at: 0)
        saveEntries(all)
    }

    func deleteEntries(ids: Set<UUID>) {
        saveEntries(loadCompleteEntries().filter { !ids.contains($0.id) })
    }

    func loadFullContent(for entryID: UUID) -> ClipboardContent? {
        loadCompleteEntries().first { $0.id == entryID }?.content
    }

    private func loadCompleteEntries() -> [ClipboardEntry] {
        let fileURL = directoryURL.appendingPathComponent(entriesFileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let records = try? decoder.decode([ClipboardEntryRecord].self, from: data) else {
            return []
        }

        return records.compactMap { record in
            let content: ClipboardContent
            switch record.type {
            case .text:
                guard let text = record.text else { return nil }
                content = .text(text)
            case .url:
                guard let url = record.url else { return nil }
                content = .url(url)
            case .file:
                guard let files = record.files else { return nil }
                content = .files(files)
            case .image, .rtf, .unknown:
                guard let blobName = record.blobFilename else {
                    content = .unknown(nil)
                    break
                }
                let blobURL = blobsDirectoryURL().appendingPathComponent(blobName)
                let blobData = try? Data(contentsOf: blobURL)
                switch record.type {
                case .image:
                    content = .image(blobData)
                case .rtf:
                    content = .rtf(blobData)
                case .unknown:
                    content = .unknown(blobData)
                default:
                    content = .unknown(nil)
                }
            }

            return ClipboardEntry(
                id: record.id,
                createdAt: record.createdAt,
                type: record.type,
                preview: record.preview,
                sourceAppBundleID: record.sourceAppBundleID,
                sourceAppName: record.sourceAppName,
                content: content,
                thumbnailData: loadThumbnailData(from: record.thumbnailBlobFilename)
            )
        }
    }

    func saveEntries(_ entries: [ClipboardEntry]) {
        ensureDirectories()
        let blobsURL = blobsDirectoryURL()

        var records: [ClipboardEntryRecord] = []
        var usedBlobNames = Set<String>()

        for entry in entries {
            var record = ClipboardEntryRecord(
                id: entry.id,
                createdAt: entry.createdAt,
                type: entry.type,
                preview: entry.preview,
                sourceAppBundleID: entry.sourceAppBundleID,
                sourceAppName: entry.sourceAppName,
                text: nil,
                url: nil,
                files: nil,
                blobFilename: nil,
                thumbnailBlobFilename: nil
            )

            switch entry.content {
            case .text(let text):
                record.text = text
            case .url(let url):
                record.url = url
            case .files(let files):
                record.files = files
            case .image(let data):
                guard let data else { break }
                let name = "\(entry.id.uuidString).png"
                record.blobFilename = name
                usedBlobNames.insert(name)
                try? data.write(to: blobsURL.appendingPathComponent(name), options: .atomic)
            case .rtf(let data):
                guard let data else { break }
                let name = "\(entry.id.uuidString).rtf"
                record.blobFilename = name
                usedBlobNames.insert(name)
                try? data.write(to: blobsURL.appendingPathComponent(name), options: .atomic)
            case .unknown(let data):
                guard let data else { break }
                let name = "\(entry.id.uuidString).bin"
                record.blobFilename = name
                usedBlobNames.insert(name)
                try? data.write(to: blobsURL.appendingPathComponent(name), options: .atomic)
            }

            if let thumbnailData = entry.thumbnailData {
                let thumbnailName = "\(entry.id.uuidString)_thumb.png"
                record.thumbnailBlobFilename = thumbnailName
                usedBlobNames.insert(thumbnailName)
                try? thumbnailData.write(to: blobsURL.appendingPathComponent(thumbnailName), options: .atomic)
            }

            records.append(record)
        }

        cleanupUnusedBlobs(keeping: usedBlobNames)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(records) {
            let fileURL = directoryURL.appendingPathComponent(entriesFileName)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func ensureDirectories() {
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        let blobsURL = blobsDirectoryURL()
        if !fileManager.fileExists(atPath: blobsURL.path) {
            try? fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        }
    }

    private func blobsDirectoryURL() -> URL {
        directoryURL.appendingPathComponent(blobsDirectoryName)
    }

    private func cleanupUnusedBlobs(keeping usedBlobNames: Set<String>) {
        let blobsURL = blobsDirectoryURL()
        guard let contents = try? fileManager.contentsOfDirectory(at: blobsURL, includingPropertiesForKeys: nil) else {
            return
        }
        for fileURL in contents {
            let name = fileURL.lastPathComponent
            if !usedBlobNames.contains(name) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func loadThumbnailData(from fileName: String?) -> Data? {
        guard let fileName else { return nil }
        let fileURL = blobsDirectoryURL().appendingPathComponent(fileName)
        return try? Data(contentsOf: fileURL)
    }
}

private struct ClipboardEntryRecord: Codable {
    let id: UUID
    let createdAt: Date
    let type: ClipboardContentType
    let preview: String
    let sourceAppBundleID: String?
    let sourceAppName: String?
    var text: String?
    var url: URL?
    var files: [URL]?
    var blobFilename: String?
    var thumbnailBlobFilename: String?
}
