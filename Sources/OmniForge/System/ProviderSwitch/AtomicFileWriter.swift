import Foundation

/// 原子写：tmp + rename + `0600`（复用 `CodexAuthPersistence` 既有模式，SPEC 2.5）。
/// 进程中途被杀也不会留下写坏的半成品文件。
enum AtomicFileWriter {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: temp, options: [.atomic])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: url)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }
}
