import Foundation

/// 社区宠物浏览状态。
enum PetCommunityState: Equatable {
    case idle
    case loading
    case loaded([PetdexPet])
    case failed(String)
}

/// 社区宠物浏览器：拉取 petdex 清单、下载宠物入库。
/// 与 `DesktopPetManager`（窗口与行为）分离，便于独立测试与演进。
@MainActor
final class PetCommunityBrowser: ObservableObject {
    @Published private(set) var state: PetCommunityState = .idle
    /// 正在下载的宠物 slug。
    @Published private(set) var downloadingSlugs: Set<String> = []
    /// 下载失败提示（slug → 文案），供列表行内展示。
    @Published private(set) var downloadErrors: [String: String] = [:]

    private let manifestClient: PetdexManifestClient
    private let downloader: PetdexDownloader
    private let store: PetAssetStore
    private let stagingDirectory: URL

    init(
        manifestClient: PetdexManifestClient,
        downloader: PetdexDownloader,
        store: PetAssetStore,
        stagingDirectory: URL
    ) {
        self.manifestClient = manifestClient
        self.downloader = downloader
        self.store = store
        self.stagingDirectory = stagingDirectory
    }

    /// 生产默认构造。
    convenience init(store: PetAssetStore) {
        self.init(
            manifestClient: PetdexManifestClient(),
            downloader: PetdexDownloader(),
            store: store,
            stagingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("OmniForgePetDownloads", isDirectory: true)
        )
    }

    /// 拉取清单（命中缓存则即时返回）。
    func load(forceRefresh: Bool = false) async {
        if case .loading = state { return }
        state = .loading
        do {
            let manifest = try await manifestClient.load(forceRefresh: forceRefresh)
            state = .loaded(manifest.pets)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            state = .failed(detail)
        }
    }

    /// 搜索当前清单（空关键词返回前 `limit` 条）。
    func search(_ keyword: String, limit: Int = 30) -> [PetdexPet] {
        guard case .loaded(let pets) = state else { return [] }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched: [PetdexPet]
        if trimmed.isEmpty {
            matched = pets
        } else {
            let lowered = trimmed.lowercased()
            matched = pets.filter {
                $0.displayName.lowercased().contains(lowered) || $0.slug.contains(lowered)
            }
        }
        return Array(matched.prefix(max(0, limit)))
    }

    /// 下载并入库指定宠物。
    @discardableResult
    func download(_ pet: PetdexPet) async -> Result<PetAssetStore.InstalledPet, Error> {
        guard !downloadingSlugs.contains(pet.slug) else {
            return .failure(PetdexDownloadError.network)
        }
        downloadingSlugs.insert(pet.slug)
        downloadErrors[pet.slug] = nil
        defer { downloadingSlugs.remove(pet.slug) }

        do {
            let installed = try await downloader.download(
                pet,
                into: store,
                stagingDirectory: stagingDirectory
            )
            return .success(installed)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            downloadErrors[pet.slug] = detail
            return .failure(error)
        }
    }

    /// 按名字安装社区宠物：在清单中匹配（展示名或 slug，取第一个命中）并下载入库。
    /// 浏览挑选交给 petdex 网站，这里只负责「看中后按名字装」。
    func install(byName name: String) async -> Result<PetAssetStore.InstalledPet, Error> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(PetdexDownloadError.notFound(name))
        }
        do {
            let manifest = try await manifestClient.load()
            guard let pet = manifest.search(trimmed, limit: 1).first else {
                return .failure(PetdexDownloadError.notFound(trimmed))
            }
            return await download(pet)
        } catch {
            return .failure(error)
        }
    }

    /// 该 slug 是否已安装。
    func isInstalled(_ slug: String) -> Bool {
        store.installedPets().contains { $0.slug == slug }
    }

    /// 清空下载错误提示。
    func clearErrors() {
        downloadErrors.removeAll()
    }
}
