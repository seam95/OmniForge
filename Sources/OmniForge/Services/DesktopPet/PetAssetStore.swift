import Foundation

/// 本地社区宠物资产库：把用户导入的 petdex 宠物存放在 Application Support 下，
/// 与随 App 发布的内置资产分离（内置资产在 Bundle/Resources/Pets）。
struct PetAssetStore {
    /// 已安装的宠物条目。
    struct InstalledPet: Identifiable, Equatable {
        /// 目录名（即资产 id）。
        let slug: String
        /// 展示名（取自 pet.json，缺失时回退 slug）。
        let displayName: String

        var id: String { slug }
    }

    /// 存储根目录（每个宠物一个子目录）。
    let rootDirectory: URL
    private let fileManager: FileManager

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// 生产环境默认根目录：`~/Library/Application Support/OmniForge/Pets`。
    /// 与便签库（OmniForge/StickyNotes）同级，便于用户定位与管理。
    static func defaultRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("OmniForge/Pets", isDirectory: true)
    }

    /// 指定宠物的目录。
    func directory(for slug: String) -> URL {
        rootDirectory.appendingPathComponent(slug, isDirectory: true)
    }

    /// 列出已安装宠物（按展示名排序）。
    func installedPets() -> [InstalledPet] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { return nil }
            let manifestURL = url.appendingPathComponent("pet.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }
            let displayName = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode(ManifestName.self, from: $0) }?
                .displayName
            return InstalledPet(
                slug: url.lastPathComponent,
                displayName: displayName ?? url.lastPathComponent
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// 导入宠物目录：校验后复制到库中，返回条目。同名已存在则覆盖。
    /// - Parameter source: 含 `pet.json` 与图集的目录。
    @discardableResult
    func importPet(from source: URL) throws -> InstalledPet {
        let manifestURL = source.appendingPathComponent("pet.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw PetdexAssetError.missingPetJSON
        }
        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(ManifestName.self, from: $0) }
        let slug = Self.sanitizedSlug(
            manifest?.id ?? source.lastPathComponent
        )
        guard !slug.isEmpty else { throw PetdexAssetError.missingPetJSON }

        let destination = directory(for: slug)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)

        // 复制后校验资产确实可用，避免把坏目录留在库里。
        do {
            _ = try PetdexAssetAdapter.load(from: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return InstalledPet(
            slug: slug,
            displayName: manifest?.displayName ?? slug
        )
    }

    /// 删除已安装宠物。
    func remove(slug: String) throws {
        let destination = directory(for: slug)
        guard fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.removeItem(at: destination)
    }

    /// 目录名清洗：小写化并把路径分隔符等不安全字符折叠为连字符，避免路径穿越。
    static func sanitizedSlug(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed
    }

    private struct ManifestName: Decodable {
        let id: String?
        let displayName: String?
    }
}
