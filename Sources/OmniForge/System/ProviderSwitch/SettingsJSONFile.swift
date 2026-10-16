import Foundation

/// `settings.json` 根对象读写 helper — 直连切换与聚合模式共用同一份文件，
/// 读写口径必须单一来源，否则两条路径的键所有权会漂移。
enum SettingsJSONFile {
    /// 读取根对象；文件缺失 → nil；存在但非 JSON 对象 → 抛 corrupted。
    static func readRoot(from url: URL, fileManager: FileManager) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderConfigFileError.corrupted(path: url.path)
        }
        return root
    }

    /// 写根对象：美化 + 键排序后原子写入（0600）。
    static func writeRoot(_ root: [String: Any], to url: URL, fileManager: FileManager) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw ProviderConfigFileError.writeFailed(path: url.path)
        }
        do {
            try AtomicFileWriter.write(data, to: url, fileManager: fileManager)
        } catch {
            throw ProviderConfigFileError.writeFailed(path: url.path)
        }
    }
}
