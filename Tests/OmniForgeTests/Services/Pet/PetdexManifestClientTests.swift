import AppKit
import XCTest
@testable import OmniForge

/// 支持 Data 响应与按 URL 分发的 HTTP stub（manifest 与下载共用）。
final class PetdexHTTPStub: HTTPDataFetching {
    struct Response {
        let data: Data
        let status: Int
    }

    /// 按 URL 绝对字符串前缀路由；无匹配时用 defaultResponse。
    var routes: [String: Response]
    var defaultResponse: Response
    /// 可注入的全局错误（优先于路由）。
    var error: Error?
    private(set) var requestedURLs: [URL] = []

    init(
        routes: [String: Response] = [:],
        defaultResponse: Response = Response(data: Data(), status: 200)
    ) {
        self.routes = routes
        self.defaultResponse = defaultResponse
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        requestedURLs.append(url)
        if let error { throw error }
        let response = routes.first { url.absoluteString.hasPrefix($0.key) }?.value ?? defaultResponse
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (response.data, http)
    }
}

/// petdex 清单客户端测试：解码、缓存 TTL、离线回退、搜索。
final class PetdexManifestClientTests: XCTestCase {
    private var cacheURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("petdex-manifest-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheURL)
        try super.tearDownWithError()
    }

    private func makeClient(
        stub: PetdexHTTPStub,
        now: @escaping () -> Date = { Date() }
    ) -> PetdexManifestClient {
        PetdexManifestClient(client: stub, cacheURL: cacheURL, now: now)
    }

    private static let manifestJSON: String = """
    {
      "generatedAt": "2026-09-10T00:00:00.000Z",
      "total": 2,
      "pets": [
        {
          "slug": "boba",
          "displayName": "Boba",
          "kind": "creature",
          "submittedBy": "Alice",
          "spritesheetUrl": "https://assets.petdex.dev/pets/boba/sprite.webp",
          "petJsonUrl": "https://assets.petdex.dev/pets/boba/petjson.json",
          "zipUrl": "https://assets.petdex.dev/pets/boba/zip.zip",
          "spriteVersionNumber": 1
        },
        {
          "slug": "eve",
          "displayName": "EVE",
          "kind": "character",
          "spriteVersionNumber": 2
        }
      ]
    }
    """

    // MARK: - 解码

    func test_decodeParsesPetsAndSkipsIncompleteEntries() throws {
        // 缺 slug 的条目被跳过而非整体失败。
        let json = """
        {"total": 3, "pets": [
          {"slug": "ok"},
          {"displayName": "no-slug"},
          {"slug": "v2pet", "spriteVersionNumber": 2}
        ]}
        """
        let manifest = try PetdexManifestClient.decode(Data(json.utf8))

        XCTAssertEqual(manifest.pets.map(\.slug), ["ok", "v2pet"])
        XCTAssertEqual(manifest.total, 3)
        XCTAssertEqual(manifest.pets[1].spriteVersionNumber, 2)
    }

    func test_decodeRejectsEmptyPets() {
        XCTAssertThrowsError(
            try PetdexManifestClient.decode(Data(#"{"total":0,"pets":[]}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? PetdexManifestError, .malformed)
        }
    }

    func test_decodeRejectsMalformedJSON() {
        XCTAssertThrowsError(
            try PetdexManifestClient.decode(Data("not json".utf8))
        ) { error in
            XCTAssertEqual(error as? PetdexManifestError, .malformed)
        }
    }

    func test_searchMatchesDisplayNameAndSlug() throws {
        let manifest = try PetdexManifestClient.decode(Data(Self.manifestJSON.utf8))

        XCTAssertEqual(manifest.search("boba", limit: 10).map(\.slug), ["boba"])
        XCTAssertEqual(manifest.search("EVE", limit: 10).map(\.slug), ["eve"])
        // 空关键词返回全部（受 limit 截断）。
        XCTAssertEqual(manifest.search("", limit: 1).count, 1)
        XCTAssertEqual(manifest.search("  ", limit: 10).count, 2)
        XCTAssertTrue(manifest.search("missing", limit: 10).isEmpty)
    }

    func test_searchPrefersExactMatchOverPrefixContenders() throws {
        // 清单序 catgirl 在前：搜 cat 应精确命中 cat，不被子串命中的 catgirl 抢走。
        let pets = [
            PetdexPet(slug: "catgirl", displayName: "Catgirl", kind: "creature",
                      submittedBy: "A", spritesheetURL: nil, petJsonURL: nil, zipURL: nil,
                      spriteVersionNumber: 1),
            PetdexPet(slug: "cat", displayName: "Cat", kind: "creature",
                      submittedBy: "B", spritesheetURL: nil, petJsonURL: nil, zipURL: nil,
                      spriteVersionNumber: 1),
        ]

        XCTAssertEqual(PetdexManifest.matching(pets, keyword: "cat").map(\.slug), ["cat"])
        XCTAssertEqual(PetdexManifest.matching(pets, keyword: "Cat").map(\.slug), ["cat"])
        // 无精确命中才回退子串包含（保序）。
        XCTAssertEqual(
            PetdexManifest.matching(pets, keyword: "catg").map(\.slug),
            ["catgirl"]
        )
    }

    // MARK: - 网络与缓存

    func test_loadFetchesThenServesFromCacheWithoutNetwork() async throws {
        let stub = PetdexHTTPStub(defaultResponse: .init(data: Data(Self.manifestJSON.utf8), status: 200))
        let client = makeClient(stub: stub)

        _ = try await client.load()
        XCTAssertEqual(stub.requestedURLs.count, 1)

        _ = try await client.load()
        // 第二次命中缓存，不再发请求。
        XCTAssertEqual(stub.requestedURLs.count, 1)
    }

    func test_loadRefetchesAfterCacheTTLExpires() async throws {
        // 注入时钟须以真实当前时间起步：缓存过期判定基于文件 mtime（真实时钟写入）。
        var now = Date()
        let stub = PetdexHTTPStub(defaultResponse: .init(data: Data(Self.manifestJSON.utf8), status: 200))
        let client = makeClient(stub: stub, now: { now })

        _ = try await client.load()
        // 前进超过 TTL。
        now += PetdexManifestClient.cacheTTL + 1
        _ = try await client.load()

        XCTAssertEqual(stub.requestedURLs.count, 2)
    }

    func test_loadFallsBackToStaleCacheWhenNetworkFails() async throws {
        let stub = PetdexHTTPStub(defaultResponse: .init(data: Data(Self.manifestJSON.utf8), status: 200))
        var now = Date()
        let client = makeClient(stub: stub, now: { now })

        // 首次成功并落缓存。
        _ = try await client.load()

        // TTL 过期 + 断网：仍能拿到过期缓存。
        now += PetdexManifestClient.cacheTTL + 1
        stub.error = URLError(.notConnectedToInternet)
        let manifest = try await client.load()
        XCTAssertEqual(manifest.pets.count, 2)
    }

    func test_loadThrowsWhenNoCacheAndNetworkFails() async {
        let stub = PetdexHTTPStub()
        stub.error = URLError(.notConnectedToInternet)
        let client = makeClient(stub: stub)

        do {
            _ = try await client.load()
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? PetdexManifestError, .network)
        }
    }

    func test_loadThrowsOnBadStatus() async {
        let stub = PetdexHTTPStub(defaultResponse: .init(data: Data("{}".utf8), status: 500))
        let client = makeClient(stub: stub)

        do {
            _ = try await client.load()
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? PetdexManifestError, .badStatus(500))
        }
    }
}
