import AppKit
import XCTest
@testable import OmniForge

/// petdex 下载器与社区浏览器测试。
@MainActor
final class PetdexDownloaderTests: XCTestCase {
    private var libraryRoot: URL!
    private var staging: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("petdex-dl-\(UUID().uuidString)", isDirectory: true)
        libraryRoot = base.appendingPathComponent("library", isDirectory: true)
        staging = base.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: libraryRoot.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    /// 生成一张合法的 8×9 小图集 PNG（row0 填 3 帧，其余透明）。
    private static func miniAtlasPNG(cellWidth: Int = 16, cellHeight: Int = 17) -> Data {
        let columns = 8, rows = 9
        let width = columns * cellWidth, height = rows * cellHeight
        let cs = CGColorSpaceCreateDeviceRGB()
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let image: CGImage = buffer.withUnsafeMutableBytes { raw -> CGImage in
                let ctx = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
                for column in 0..<3 {
                    ctx.fill(CGRect(x: column * cellWidth, y: 0, width: cellWidth, height: cellHeight))
                }
                return ctx.makeImage()!
            }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    private static let petJSON = Data(
        #"{"id":"boba","displayName":"Boba","spritesheetPath":"spritesheet.webp"}"#.utf8
    )

    private func makeStore() -> PetAssetStore {
        PetAssetStore(rootDirectory: libraryRoot)
    }

    private func makePet(version: Int = 1) -> PetdexPet {
        PetdexPet(
            slug: "boba",
            displayName: "Boba",
            kind: "creature",
            submittedBy: "Alice",
            spritesheetURL: URL(string: "https://assets.petdex.dev/pets/boba/sprite.webp"),
            petJsonURL: URL(string: "https://assets.petdex.dev/pets/boba/petjson.json"),
            zipURL: nil,
            spriteVersionNumber: version
        )
    }

    // MARK: - 下载

    func test_downloadFetchesBothFilesAndImportsIntoStore() async throws {
        let stub = PetdexHTTPStub(routes: [
            "https://assets.petdex.dev/pets/boba/petjson.json": .init(data: Self.petJSON, status: 200),
            "https://assets.petdex.dev/pets/boba/sprite.webp": .init(data: Self.miniAtlasPNG(), status: 200),
        ])
        let downloader = PetdexDownloader(client: stub)
        let store = makeStore()

        let pet = try await downloader.download(makePet(), into: store, stagingDirectory: staging)

        XCTAssertEqual(pet.slug, "boba")
        XCTAssertEqual(store.installedPets().map(\.slug), ["boba"])
        // 图集按 pet.json 声明名落盘。
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: libraryRoot.appendingPathComponent("boba/spritesheet.webp").path
        ))
    }

    func test_downloadFallsBackToURLExtensionWhenPathUndeclared() async throws {
        let manifest = Data(#"{"id":"boba","displayName":"Boba"}"#.utf8)
        let stub = PetdexHTTPStub(routes: [
            "https://assets.petdex.dev/pets/boba/petjson.json": .init(data: manifest, status: 200),
            "https://assets.petdex.dev/pets/boba/sprite.webp": .init(data: Self.miniAtlasPNG(), status: 200),
        ])
        let store = makeStore()

        _ = try await PetdexDownloader(client: stub).download(
            makePet(), into: store, stagingDirectory: staging
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: libraryRoot.appendingPathComponent("boba/spritesheet.webp").path
        ))
    }



    func test_downloadRejectsMissingURLs() async {
        let pet = PetdexPet(
            slug: "broken", displayName: "Broken", kind: "object",
            submittedBy: "", spritesheetURL: nil, petJsonURL: nil,
            zipURL: nil, spriteVersionNumber: 1
        )
        let store = makeStore()

        do {
            _ = try await PetdexDownloader(client: PetdexHTTPStub()).download(
                pet, into: store, stagingDirectory: staging
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? PetdexDownloadError, .missingURL)
        }
    }

    func test_downloadSurfacesBadStatus() async {
        let stub = PetdexHTTPStub(routes: [
            "https://assets.petdex.dev/pets/boba/petjson.json": .init(data: Data(), status: 404),
        ])
        let store = makeStore()

        do {
            _ = try await PetdexDownloader(client: stub).download(
                makePet(), into: store, stagingDirectory: staging
            )
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(
                error as? PetdexDownloadError,
                .badStatus(404, resource: "pet.json")
            )
        }
    }

    func test_sanitizedFileNameStripsPaths() {
        XCTAssertEqual(PetdexDownloader.sanitizedFileName("a/b/spritesheet.webp"), "spritesheet.webp")
        XCTAssertEqual(PetdexDownloader.sanitizedFileName("evil\\name.png"), "evilname.png")
        XCTAssertEqual(PetdexDownloader.sanitizedFileName("  "), "spritesheet.webp")
    }

    // MARK: - 社区浏览器

    func test_browserLoadPopulatesLoadedState() async {
        let manifestJSON = """
        {"total":1,"pets":[{"slug":"boba","displayName":"Boba","kind":"creature",
        "submittedBy":"A","spritesheetUrl":"https://x/s.webp","petJsonUrl":"https://x/p.json",
        "zipUrl":null,"spriteVersionNumber":1}]}
        """
        let stub = PetdexHTTPStub(defaultResponse: .init(data: Data(manifestJSON.utf8), status: 200))
        let browser = PetCommunityBrowser(
            manifestClient: PetdexManifestClient(client: stub, cacheURL: nil),
            downloader: PetdexDownloader(client: stub),
            store: makeStore(),
            stagingDirectory: staging
        )

        await browser.load()

        guard case .loaded(let pets) = browser.state else {
            return XCTFail("期望 loaded，实际 \(browser.state)")
        }
        XCTAssertEqual(pets.map(\.slug), ["boba"])
        XCTAssertEqual(browser.search("bob").map(\.slug), ["boba"])
    }

    func test_browserLoadFailureEntersFailedState() async {
        let stub = PetdexHTTPStub()
        stub.error = URLError(.notConnectedToInternet)
        let browser = PetCommunityBrowser(
            manifestClient: PetdexManifestClient(client: stub, cacheURL: nil),
            downloader: PetdexDownloader(client: stub),
            store: makeStore(),
            stagingDirectory: staging
        )

        await browser.load()

        guard case .failed = browser.state else {
            return XCTFail("期望 failed，实际 \(browser.state)")
        }
    }

    func test_browserDownloadImportsPetAndMarksInstalled() async throws {
        let stub = PetdexHTTPStub(routes: [
            "https://assets.petdex.dev/pets/boba/petjson.json": .init(data: Self.petJSON, status: 200),
            "https://assets.petdex.dev/pets/boba/sprite.webp": .init(data: Self.miniAtlasPNG(), status: 200),
        ])
        let store = makeStore()
        let browser = PetCommunityBrowser(
            manifestClient: PetdexManifestClient(client: stub, cacheURL: nil),
            downloader: PetdexDownloader(client: stub),
            store: store,
            stagingDirectory: staging
        )
        let pet = makePet()

        let result = await browser.download(pet)

        guard case .success(let installed) = result else {
            return XCTFail("下载应成功，实际 \(result)")
        }
        XCTAssertEqual(installed.slug, "boba")
        XCTAssertTrue(browser.isInstalled("boba"))
        XCTAssertTrue(browser.downloadingSlugs.isEmpty)
    }

    func test_browserDownloadFailureRecordsError() async {
        let stub = PetdexHTTPStub(routes: [
            "https://assets.petdex.dev/pets/boba/petjson.json": .init(data: Data(), status: 500),
        ])
        let browser = PetCommunityBrowser(
            manifestClient: PetdexManifestClient(client: stub, cacheURL: nil),
            downloader: PetdexDownloader(client: stub),
            store: makeStore(),
            stagingDirectory: staging
        )

        let result = await browser.download(makePet())

        guard case .failure = result else {
            return XCTFail("应当失败")
        }
        XCTAssertNotNil(browser.downloadErrors["boba"])
        XCTAssertTrue(browser.downloadingSlugs.isEmpty)
    }
}
