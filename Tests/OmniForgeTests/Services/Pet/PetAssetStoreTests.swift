import AppKit
import XCTest
@testable import OmniForge

/// 社区宠物资产库测试：导入校验、列出、删除、slug 清洗。
final class PetAssetStoreTests: XCTestCase {
    private var root: URL!
    private var sourceRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-store-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("library", isDirectory: true)
        sourceRoot = base.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        root = nil
        sourceRoot = nil
        try super.tearDownWithError()
    }

    /// 生成一个可被适配器接受的最小宠物目录。
    @discardableResult
    private func makeSourcePet(slug: String, displayName: String) throws -> URL {
        let directory = sourceRoot.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let columns = 8, rows = 9, cellWidth = 16, cellHeight = 17
        let width = columns * cellWidth, height = rows * cellHeight
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let image: CGImage? = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
            for column in 0..<3 {
                context.fill(CGRect(x: column * cellWidth, y: 0, width: cellWidth, height: cellHeight))
            }
            return context.makeImage()
        }
        let png = try XCTUnwrap(image.flatMap {
            NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:])
        })
        try png.write(to: directory.appendingPathComponent("spritesheet.png"))
        let manifest = ["id": slug, "displayName": displayName, "spritesheetPath": "spritesheet.png"]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: directory.appendingPathComponent("pet.json")
        )
        return directory
    }

    private func makeStore() -> PetAssetStore {
        PetAssetStore(rootDirectory: root)
    }

    // MARK: - 导入

    func test_importCopiesPetAndListsIt() throws {
        let source = try makeSourcePet(slug: "boba", displayName: "Boba")
        let store = makeStore()

        let pet = try store.importPet(from: source)

        XCTAssertEqual(pet.slug, "boba")
        XCTAssertEqual(pet.displayName, "Boba")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("boba/pet.json").path
        ))
        XCTAssertEqual(store.installedPets().map(\.slug), ["boba"])
    }

    func test_importSanitizesSlug() throws {
        let source = try makeSourcePet(slug: "My Pet!!", displayName: "Weird")
        let store = makeStore()

        let pet = try store.importPet(from: source)

        // 非安全字符折叠为连字符，且不含路径分隔符。
        XCTAssertFalse(pet.slug.contains("/"))
        XCTAssertFalse(pet.slug.contains("!"))
        XCTAssertEqual(store.installedPets().count, 1)
    }

    func test_importRejectsDirectoryWithoutManifest() throws {
        let empty = sourceRoot.appendingPathComponent("nope", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let store = makeStore()

        XCTAssertThrowsError(try store.importPet(from: empty))
        XCTAssertTrue(store.installedPets().isEmpty)
    }

    func test_importRejectsInvalidAtlasAndLeavesNoResidue() throws {
        let source = sourceRoot.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"id":"broken","displayName":"Broken"}"#.utf8)
            .write(to: source.appendingPathComponent("pet.json"))
        let store = makeStore()

        XCTAssertThrowsError(try store.importPet(from: source))
        // 校验失败不应在库中留下半成品。
        XCTAssertTrue(store.installedPets().isEmpty)
    }

    func test_reimportOverwritesExisting() throws {
        let store = makeStore()
        let first = try makeSourcePet(slug: "dup", displayName: "First")
        try store.importPet(from: first)

        let second = try makeSourcePet(slug: "dup2", displayName: "Second")
        // 目录名不同但 id 相同，应覆盖同一条目。
        let secondManifest = ["id": "dup", "displayName": "Second", "spritesheetPath": "spritesheet.png"]
        try JSONSerialization.data(withJSONObject: secondManifest).write(
            to: second.appendingPathComponent("pet.json")
        )
        try store.importPet(from: second)

        let pets = store.installedPets()
        XCTAssertEqual(pets.count, 1)
        XCTAssertEqual(pets.first?.displayName, "Second")
    }

    // MARK: - 列出与删除

    func test_installedPetsSortedByDisplayName() throws {
        let store = makeStore()
        try store.importPet(from: makeSourcePet(slug: "zeta", displayName: "Zeta"))
        try store.importPet(from: makeSourcePet(slug: "alpha", displayName: "Alpha"))

        XCTAssertEqual(store.installedPets().map(\.displayName), ["Alpha", "Zeta"])
    }

    func test_installedPetsEmptyWhenRootMissing() {
        XCTAssertTrue(makeStore().installedPets().isEmpty)
    }

    func test_removeDeletesPet() throws {
        let store = makeStore()
        try store.importPet(from: makeSourcePet(slug: "gone", displayName: "Gone"))

        try store.remove(slug: "gone")

        XCTAssertTrue(store.installedPets().isEmpty)
    }

    func test_removeMissingPetIsNoop() throws {
        XCTAssertNoThrow(try makeStore().remove(slug: "absent"))
    }

    // MARK: - slug 清洗

    func test_sanitizedSlugLowercasesAndFolds() {
        XCTAssertEqual(PetAssetStore.sanitizedSlug("Hello World"), "hello-world")
        XCTAssertEqual(PetAssetStore.sanitizedSlug("a/b\\c"), "a-b-c")
        XCTAssertEqual(PetAssetStore.sanitizedSlug("--dup--"), "dup")
        XCTAssertEqual(PetAssetStore.sanitizedSlug("caps_ok-1"), "caps_ok-1")
    }
}
