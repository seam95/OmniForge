import Foundation

/// 单个 petdex 宠物下载失败原因。
enum PetdexDownloadError: Error, Equatable, LocalizedError {
    case missingURL
    case network
    case badStatus(Int, resource: String)
    case writeFailed
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .missingURL: return "该宠物缺少下载地址"
        case .network: return "下载失败，请检查网络"
        case .badStatus(let code, let resource): return "下载 \(resource) 失败（\(code)）"
        case .writeFailed: return "写入宠物文件失败"
        case .notFound(let name): return "没有找到「\(name)」"
        }
    }
}

/// petdex 宠物下载器：按清单条目下载 `pet.json` 与图集，落库为本地宠物。
///
/// 下载两个文件分别获取（而非整包 zip），省去解压依赖；
/// 图集按 `pet.json` 声明的 `spritesheetPath` 命名，保证后续适配器可定位。
final class PetdexDownloader {
    /// 单文件体积上限保护（8×9 图集通常 < 3MB，给足余量）。
    static let maxResourceBytes = 20 * 1024 * 1024

    private let client: HTTPDataFetching
    private let fileManager: FileManager

    init(client: HTTPDataFetching, fileManager: FileManager = .default) {
        self.client = client
        self.fileManager = fileManager
    }

    /// 默认 30s 超时的 ephemeral session。
    convenience init(timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.init(client: URLSession(configuration: config))
    }

    /// 下载指定宠物到 `store`，返回入库条目。
    /// - Parameters:
    ///   - pet: 清单条目。
    ///   - store: 目标宠物库。
    ///   - stagingDirectory: 临时工作目录（调用方提供，便于测试注入）。
    @discardableResult
    func download(
        _ pet: PetdexPet,
        into store: PetAssetStore,
        stagingDirectory: URL
    ) async throws -> PetAssetStore.InstalledPet {
        // 不按 manifest 版本预检：实测版本字段不可靠，图集实际尺寸由适配器判定。
        guard let petJsonURL = pet.petJsonURL, let sheetURL = pet.spritesheetURL else {
            throw PetdexDownloadError.missingURL
        }

        let work = stagingDirectory.appendingPathComponent("\(pet.slug)-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        // 1. pet.json
        let petJsonData = try await fetch(petJsonURL, resource: "pet.json")
        let manifestURL = work.appendingPathComponent("pet.json")
        guard (try? petJsonData.write(to: manifestURL)) != nil else {
            throw PetdexDownloadError.writeFailed
        }

        // 2. 图集：按 pet.json 声明的文件名落盘（缺失时退回默认名）。
        let declaredName = Self.spritesheetName(in: petJsonData)
            ?? (sheetURL.pathExtension.isEmpty ? "spritesheet.webp" : "spritesheet.\(sheetURL.pathExtension)")
        let safeName = Self.sanitizedFileName(declaredName)
        let sheetData = try await fetch(sheetURL, resource: "spritesheet")
        let sheetPath = work.appendingPathComponent(safeName)
        guard (try? sheetData.write(to: sheetPath)) != nil else {
            throw PetdexDownloadError.writeFailed
        }

        // 3. 入库（PetAssetStore 会再次校验资产可解析）。
        return try store.importPet(from: work)
    }

    // MARK: - 私有

    private func fetch(_ url: URL, resource: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.data(from: url)
        } catch {
            throw PetdexDownloadError.network
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PetdexDownloadError.badStatus(http.statusCode, resource: resource)
        }
        guard data.count <= Self.maxResourceBytes else {
            throw PetdexDownloadError.badStatus(0, resource: resource)
        }
        return data
    }

    /// 从 pet.json 读取 spritesheetPath。
    private static func spritesheetName(in data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return root["spritesheetPath"] as? String
    }

    /// 文件名清洗：仅取末段并剔除路径分隔符，防目录穿越。
    static func sanitizedFileName(_ raw: String) -> String {
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        let cleaned = last.replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "spritesheet.webp" : cleaned
    }
}
