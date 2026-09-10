import Foundation

/// petdex 社区宠物清单条目。
struct PetdexPet: Equatable, Identifiable {
    let slug: String
    let displayName: String
    /// 分类（character / creature / object）。
    let kind: String
    /// 提交者。
    let submittedBy: String
    /// 图集直链。
    let spritesheetURL: URL?
    /// pet.json 直链。
    let petJsonURL: URL?
    /// 整包 zip 直链（当前实现不用，留作降级）。
    let zipURL: URL?
    /// 图集版本：manifest 声明值，实测不可靠（存在标 v1 实为 8×11 的情况），
    /// 仅作参考展示；实际支持性由适配器按图集尺寸判定。
    let spriteVersionNumber: Int

    var id: String { slug }
}

/// petdex 清单响应。
struct PetdexManifest: Equatable {
    let generatedAt: String?
    let total: Int
    let pets: [PetdexPet]

    /// 按关键词过滤（精确命中优先，其余子串包含；大小写不敏感）。
    func search(_ keyword: String, limit: Int) -> [PetdexPet] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [PetdexPet]
        if trimmed.isEmpty {
            matched = pets
        } else {
            matched = Self.matching(pets, keyword: trimmed)
        }
        return Array(matched.prefix(max(0, limit)))
    }

    /// 精确命中（slug 或展示名全等）优先；无精确命中才回退子串包含（保序）。
    /// 按名安装「cat」不应被清单序靠前的「catgirl」抢走。
    static func matching(_ pets: [PetdexPet], keyword: String) -> [PetdexPet] {
        let lowered = keyword.lowercased()
        let exact = pets.filter {
            $0.slug.lowercased() == lowered || $0.displayName.lowercased() == lowered
        }
        if !exact.isEmpty { return exact }
        return pets.filter {
            $0.displayName.lowercased().contains(lowered) || $0.slug.contains(lowered)
        }
    }
}

/// 清单拉取失败原因。
enum PetdexManifestError: Error, Equatable, LocalizedError {
    case network
    case badStatus(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .network: return "无法连接宠物服务"
        case .badStatus(let code): return "宠物服务返回错误（\(code)）"
        case .malformed: return "宠物清单格式异常"
        }
    }
}

/// petdex 清单客户端：拉取公开清单并做本地缓存（默认 1 天）。
final class PetdexManifestClient {
    /// 清单端点（会 307 跳到 CDN，URLSession 自动跟随）。
    static let manifestURL = URL(string: "https://petdex.dev/api/manifest")!
    /// 缓存有效期。
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private let client: HTTPDataFetching
    private let cacheURL: URL?
    private let now: () -> Date
    private let fileManager: FileManager

    init(
        client: HTTPDataFetching,
        cacheURL: URL?,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.client = client
        self.cacheURL = cacheURL
        self.now = now
        self.fileManager = fileManager
    }

    /// 默认 15s 超时的 ephemeral session + Caches 目录缓存。
    convenience init(
        timeout: TimeInterval = 15,
        cacheURL: URL? = PetdexManifestClient.defaultCacheURL()
    ) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        self.init(
            client: URLSession(configuration: config),
            cacheURL: cacheURL
        )
    }

    /// 生产缓存路径：`~/Library/Caches/OmniForge/petdex-manifest.json`。
    static func defaultCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OmniForge/petdex-manifest.json")
    }

    /// 拉取清单：命中未过期缓存则直接用，否则联网刷新。
    /// - Parameter forceRefresh: 忽略缓存强制刷新。
    func load(forceRefresh: Bool = false) async throws -> PetdexManifest {
        if !forceRefresh, let cached = loadCachedManifest() {
            return cached
        }
        do {
            let manifest = try await fetchFromNetwork()
            storeCache(manifest)
            return manifest
        } catch {
            // 网络失败时退回过期缓存，保证离线仍可浏览与安装已有宠物。
            if let stale = loadCachedManifest(ignoreTTL: true) {
                return stale
            }
            throw error
        }
    }

    // MARK: - 网络

    private func fetchFromNetwork() async throws -> PetdexManifest {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await client.data(from: Self.manifestURL)
        } catch {
            throw PetdexManifestError.network
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PetdexManifestError.badStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// 解码清单 JSON（防御式：缺字段的条目跳过而非整体失败）。
    static func decode(_ data: Data) throws -> PetdexManifest {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PetdexManifestError.malformed
        }
        let petsRaw = root["pets"] as? [[String: Any]] ?? []
        let pets: [PetdexPet] = petsRaw.compactMap { raw in
            guard let slug = raw["slug"] as? String, !slug.isEmpty else { return nil }
            return PetdexPet(
                slug: slug,
                displayName: (raw["displayName"] as? String) ?? slug,
                kind: (raw["kind"] as? String) ?? "unknown",
                submittedBy: (raw["submittedBy"] as? String) ?? "",
                spritesheetURL: (raw["spritesheetUrl"] as? String).flatMap(URL.init(string:)),
                petJsonURL: (raw["petJsonUrl"] as? String).flatMap(URL.init(string:)),
                zipURL: (raw["zipUrl"] as? String).flatMap(URL.init(string:)),
                spriteVersionNumber: (raw["spriteVersionNumber"] as? Int) ?? 1
            )
        }
        guard !pets.isEmpty else { throw PetdexManifestError.malformed }
        return PetdexManifest(
            generatedAt: root["generatedAt"] as? String,
            total: (root["total"] as? Int) ?? pets.count,
            pets: pets
        )
    }

    // MARK: - 缓存

    private func loadCachedManifest(ignoreTTL: Bool = false) -> PetdexManifest? {
        guard let cacheURL else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: cacheURL.path),
              let modified = attributes[.modificationDate] as? Date else {
            return nil
        }
        if !ignoreTTL, now().timeIntervalSince(modified) > Self.cacheTTL {
            return nil
        }
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? Self.decode(data)
    }

    private func storeCache(_ manifest: PetdexManifest) {
        guard let cacheURL else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: Self.rawJSON(from: manifest))
        else { return }
        try? fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL)
    }

    /// 缓存写回时还原 petdex 原始字段名，保证缓存文件与线上格式一致、可直接被 `decode` 读回。
    private static func rawJSON(from manifest: PetdexManifest) -> [String: Any] {
        [
            "generatedAt": manifest.generatedAt ?? "",
            "total": manifest.total,
            "pets": manifest.pets.map { pet -> [String: Any] in
                var item: [String: Any] = [
                    "slug": pet.slug,
                    "displayName": pet.displayName,
                    "kind": pet.kind,
                    "submittedBy": pet.submittedBy,
                    "spriteVersionNumber": pet.spriteVersionNumber,
                ]
                item["spritesheetUrl"] = pet.spritesheetURL?.absoluteString
                item["petJsonUrl"] = pet.petJsonURL?.absoluteString
                item["zipUrl"] = pet.zipURL?.absoluteString
                return item
            },
        ]
    }
}
