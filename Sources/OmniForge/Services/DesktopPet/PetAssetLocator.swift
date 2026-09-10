import Foundation

/// 宠物资产定位与加载。
/// - 内置资产随 App 发布在 Bundle 的 `Pets/<id>/`（自有格式，含 animations 清单）。
/// - 社区资产存于 Application Support 的宠物库（petdex 格式，动画由图集行号约定表达）。
enum PetAssetLocator {
    /// 额外搜索根：生产注入社区宠物库目录，测试注入源码树 Resources 目录。
    static var additionalSearchRoots: [URL] = []

    /// 内置默认宠物 id。
    static let builtInPetID = "cat"

    /// 指定 id 的资产目录：先查 Bundle，再查各搜索根。
    static func directory(for petID: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: petID, withExtension: nil, subdirectory: "Pets") {
            return bundled
        }
        for root in additionalSearchRoots {
            let candidate = root.appendingPathComponent(petID, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("pet.json").path) {
                return candidate
            }
        }
        return nil
    }

    /// 图集文件 URL。
    static func atlasURL(asset: PetSpriteAsset) -> URL? {
        directory(for: asset.id)?.appendingPathComponent(asset.atlasFileName)
    }

    /// 加载资产：优先按自有格式解析（含 animations 清单），失败则按 petdex 格式适配。
    static func load(from directory: URL) throws -> PetSpriteAsset {
        if let asset = try? PetSpriteAsset.load(from: directory) {
            return asset
        }
        return try PetdexAssetAdapter.load(from: directory)
    }

    /// 按 id 加载资产。
    static func loadAsset(id: String) -> PetSpriteAsset? {
        guard let directory = directory(for: id) else { return nil }
        return try? load(from: directory)
    }

    /// 内置默认宠物资产。
    static var builtInAsset: PetSpriteAsset? { loadAsset(id: builtInPetID) }
}
