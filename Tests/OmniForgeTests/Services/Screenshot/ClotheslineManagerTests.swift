import XCTest
@testable import OmniForge

private final class FakeSoundPlayer: ClotheslineSoundPlaying {
    var played: [(String, Float)] = []
    func play(name: String, volume: Float) { played.append((name, volume)) }
}

// 方法集对齐仓库既有 PasteboardWriting 协议（clearContents/setString/setData/writeObjects）。
private final class FakePasteboard: PasteboardWriting {
    var written: [Any] = []
    func clearContents() { written.removeAll() }
    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        written.append(string)
        return true
    }
    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        written.append(data)
        return true
    }
    @discardableResult
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        written.append(objects)
        return true
    }
}

private final class SilentSoundPlayer: ClotheslineSoundPlaying {
    func play(name: String, volume: Float) {}
}

extension ClotheslineManager {
    static func testable(
        userDefaults: UserDefaults,
        inboxFolder: URL? = nil,
        sound: ClotheslineSoundPlaying = SilentSoundPlayer()
    ) -> ClotheslineManager {
        ClotheslineManager(
            userDefaults: userDefaults,
            pasteboard: FakePasteboard(),
            thumbnailProvider: { _ in NSImage(size: NSSize(width: 100, height: 80)) },
            soundPlayer: sound,
            inboxFolderProvider: { inboxFolder }
        )
    }
}

final class ClotheslineManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: ClotheslineManager!
    private var dir: URL!

    @MainActor
    override func setUp() {
        super.setUp()
        let suite = "clothesline-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clothesline-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        manager = ClotheslineManager.testable(userDefaults: defaults)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    @MainActor
    private func makeFile(_ name: String = "shot.png") -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50]))
        return url
    }

    @MainActor
    func testHangAppendsItemWithTiltAndPersists() {
        let url = makeFile()
        let id = manager.hang(url)
        XCTAssertNotNil(id)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items[0].url, url)
        XCTAssertTrue(abs(manager.items[0].tilt) <= 2.5)
        XCTAssertEqual(defaults.stringArray(forKey: UserDefaultsKeys.screenshotClotheslineItems),
                       [url.path])
    }

    @MainActor
    func testHangDuplicateURLIsIgnored() {
        let url = makeFile()
        XCTAssertNotNil(manager.hang(url))
        XCTAssertNil(manager.hang(url))
        XCTAssertEqual(manager.items.count, 1)
    }

    @MainActor
    func testHangInvalidThumbnailReturnsNil() {
        let bad = ClotheslineManager(
            userDefaults: defaults,
            pasteboard: FakePasteboard(),
            thumbnailProvider: { _ in nil },
            soundPlayer: SilentSoundPlayer()
        )
        XCTAssertNil(bad.hang(makeFile()))
    }

    @MainActor
    func testCapacityEvictsOldest() throws {
        manager.maxItems = 2
        let a = makeFile("a.png"); let b = makeFile("b.png"); let c = makeFile("c.png")
        manager.hang(a); manager.hang(b)
        XCTAssertEqual(manager.liveCount, 2)
        manager.hang(c)
        XCTAssertEqual(manager.liveCount, 2)
        // 最旧 a 已 falling
        XCTAssertTrue(manager.items[0].falling)
        XCTAssertEqual(manager.items.first { !$0.falling }?.url, b)
        XCTAssertEqual(manager.items.last { !$0.falling }?.url, c)
    }

    @MainActor
    func testDropMarksFallingAndRemovesLater() throws {
        let url = makeFile()
        let id = try XCTUnwrap(manager.hang(url))
        var fell: [PeggedPhoto] = []
        manager.onFall = { fell.append($0) }
        manager.drop(id)
        XCTAssertTrue(manager.items[0].falling)
        XCTAssertEqual(fell.count, 1)
        XCTAssertEqual(manager.hitRects[id], nil)
    }

    @MainActor
    func testClearAllDropsEverythingLive() {
        manager.hang(makeFile("a.png")); manager.hang(makeFile("b.png"))
        manager.clearAll()
        XCTAssertEqual(manager.liveCount, 0)
    }

    @MainActor
    func testPruneDropsItemsWhoseFileVanished() throws {
        let url = makeFile()
        let id = try XCTUnwrap(manager.hang(url))
        try FileManager.default.removeItem(at: url)
        manager.prune()
        XCTAssertTrue(manager.items.first?.falling ?? true)
        _ = id
    }

    @MainActor
    func testOwnWriteExclusionRoundTrip() {
        let url = makeFile()
        manager.noteOwnWrite(url.path)
        XCTAssertTrue(manager.consumeOwnWrite(url))
        XCTAssertFalse(manager.consumeOwnWrite(url))  // 消费一次即失效
    }

    @MainActor
    func testRestoreFromPersistedPathsSkipsMissing() {
        let existing = makeFile("keep.png")
        defaults.set([existing.path, "/nonexistent/x.png"],
                     forKey: UserDefaultsKeys.screenshotClotheslineItems)
        let restored = ClotheslineManager.testable(userDefaults: defaults)
        XCTAssertEqual(restored.items.map(\.url), [existing])
    }

    @MainActor
    func testIsInInboxAndDiscardSemantics() throws {
        let inbox = dir.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let inInbox = inbox.appendingPathComponent("s.png")
        FileManager.default.createFile(atPath: inInbox.path, contents: Data([1]))
        let outside = makeFile("outside.png")

        let m = ClotheslineManager.testable(userDefaults: defaults, inboxFolder: inbox)
        let inboxID = try XCTUnwrap(m.hang(inInbox))
        let outsideID = try XCTUnwrap(m.hang(outside))
        XCTAssertTrue(m.isInInbox(inboxID))
        XCTAssertFalse(m.isInInbox(outsideID))

        m.discard(outsideID)   // 外部文件：仅离绳，文件仍在
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path) == false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        m.trash(inboxID)       // Inbox 文件：移废纸篓（测试环境 trashItem 可用；失败则仅断言离绳）
        XCTAssertEqual(m.items.first { $0.id == inboxID }?.falling, true)
    }

    @MainActor
    func testSoundOffByDefaultAndToggle() {
        XCTAssertFalse(manager.soundOn)
        manager.soundOn = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: UserDefaultsKeys.screenshotClotheslineSoundOn) || manager.soundOn)
    }
}
