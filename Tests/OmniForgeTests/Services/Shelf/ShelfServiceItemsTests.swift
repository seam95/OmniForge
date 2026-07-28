import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class ShelfServiceItemsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var storeDirectory: URL!
    private var service: ShelfService!

    override func setUp() async throws {
        try await super.setUp()
        let suiteName = "shelf-items-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        Defaults.register(in: defaults)

        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfServiceItems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        service = ShelfService(userDefaults: defaults, storeDirectory: storeDirectory)
        let restored = await service.waitForRestoreForTesting()
        XCTAssertTrue(restored)
    }

    override func tearDown() async throws {
        service = nil
        if let storeDirectory {
            try? FileManager.default.removeItem(at: storeDirectory)
        }
        defaults = nil
        storeDirectory = nil
        try await super.tearDown()
    }

    func test_addTextAndClear() async {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("hello shelf", forType: .string)

        XCTAssertTrue(service.accept(pasteboard: pb))
        XCTAssertEqual(service.itemCount, 1)
        XCTAssertEqual(service.items.count, 1)
        if case let .text(text) = service.items[0].payload {
            XCTAssertEqual(text, "hello shelf")
        } else {
            XCTFail("expected text payload")
        }

        service.clear()
        XCTAssertEqual(service.itemCount, 0)
        XCTAssertTrue(service.items.isEmpty)
    }

    func test_completeInternalDrag_removesWhenPreferred() async {
        defaults.set(true, forKey: UserDefaultsKeys.shelfRemoveAfterDrop)

        let fileA = storeDirectory.appendingPathComponent("a.txt")
        let fileB = storeDirectory.appendingPathComponent("b.txt")
        try? "a".write(to: fileA, atomically: true, encoding: .utf8)
        try? "b".write(to: fileB, atomically: true, encoding: .utf8)

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([fileA as NSURL, fileB as NSURL])
        XCTAssertTrue(service.accept(pasteboard: pb))
        // Two file URLs become one batch (count > 1).
        XCTAssertEqual(service.items.count, 1)
        XCTAssertTrue(service.items[0].isBatch)
        XCTAssertEqual(service.itemCount, 2)

        let childIDs = service.items[0].batchItems.map(\.id)
        XCTAssertEqual(childIDs.count, 2)

        // Drag one leaf out successfully with removeAfterDrop.
        let dragID = childIDs[0]
        service.beginInternalDrag(ids: [dragID])
        service.completeInternalDrag(dropAccepted: true)

        XCTAssertEqual(service.itemCount, 1)
        // Single-child batch collapses to the remaining leaf.
        XCTAssertEqual(service.items.count, 1)
        XCTAssertFalse(service.items[0].isBatch)
    }

    func test_completeInternalDrag_keepsWhenRemoveDisabled() async {
        defaults.set(false, forKey: UserDefaultsKeys.shelfRemoveAfterDrop)

        let fileA = storeDirectory.appendingPathComponent("keep-a.txt")
        try? "a".write(to: fileA, atomically: true, encoding: .utf8)

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([fileA as NSURL])
        XCTAssertTrue(service.accept(pasteboard: pb))
        XCTAssertEqual(service.itemCount, 1)

        let id = service.items[0].id
        service.beginInternalDrag(ids: [id])
        service.completeInternalDrag(dropAccepted: true)
        XCTAssertEqual(service.itemCount, 1)
    }

    func test_completeInternalDrag_collapsesDockedWhenCloseAfterDrop() async {
        defaults.set(true, forKey: UserDefaultsKeys.shelfEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfDropZoneEnabled)
        defaults.set(true, forKey: UserDefaultsKeys.shelfCloseAfterDrop)
        defaults.set(false, forKey: UserDefaultsKeys.shelfRemoveAfterDrop)
        UserDefaults.standard.set(true, forKey: AppFeature.shelf.availabilityKey)

        let fileA = storeDirectory.appendingPathComponent("close-docked.txt")
        try? "a".write(to: fileA, atomically: true, encoding: .utf8)

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([fileA as NSURL])
        XCTAssertTrue(service.accept(pasteboard: pb))
        XCTAssertEqual(service.itemCount, 1)

        // Expanded docked card, no floating panel — closeAfterDrop should collapse.
        service.expandDocked()
        XCTAssertTrue(service.dockedExpanded)
        XCTAssertFalse(service.isVisible)

        let id = service.items[0].id
        service.beginInternalDrag(ids: [id])
        service.completeInternalDrag(dropAccepted: true)

        XCTAssertFalse(service.dockedExpanded)
        XCTAssertEqual(service.itemCount, 1)
    }

    func test_sourceOperationMask_respectsRemovePreference() {
        defaults.set(true, forKey: UserDefaultsKeys.shelfRemoveAfterDrop)
        XCTAssertEqual(service.sourceOperationMask(for: .withinApplication), .move)
        XCTAssertEqual(service.sourceOperationMask(for: .outsideApplication), [.copy, .move])

        defaults.set(false, forKey: UserDefaultsKeys.shelfRemoveAfterDrop)
        XCTAssertEqual(service.sourceOperationMask(for: .outsideApplication), .copy)
    }

    func test_mergeInternalDrag_intoTile() async {
        let fileA = storeDirectory.appendingPathComponent("m-a.txt")
        let fileB = storeDirectory.appendingPathComponent("m-b.txt")
        try? "a".write(to: fileA, atomically: true, encoding: .utf8)
        try? "b".write(to: fileB, atomically: true, encoding: .utf8)

        // Accept one at a time so we get two top-level tiles.
        var pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([fileA as NSURL])
        XCTAssertTrue(service.accept(pasteboard: pb))
        pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([fileB as NSURL])
        XCTAssertTrue(service.accept(pasteboard: pb))
        XCTAssertEqual(service.items.count, 2)

        let targetID = service.items[0].id
        let sourceID = service.items[1].id
        service.beginInternalDrag(ids: [sourceID])
        XCTAssertTrue(service.mergePasteboard(NSPasteboard.withUniqueName(), into: targetID))
        XCTAssertTrue(service.isInternalDragActive) // still active until complete
        // After merge, one batch remains.
        XCTAssertEqual(service.items.count, 1)
        XCTAssertTrue(service.items[0].isBatch)
        XCTAssertEqual(service.itemCount, 2)

        // Completing after merge must not remove (internalDragWasMerged).
        service.completeInternalDrag(dropAccepted: true)
        XCTAssertEqual(service.itemCount, 2)
    }

    func test_automaticExclusions_addRemove() {
        service.addAutomaticExclusion("com.example.A")
        service.addAutomaticExclusion("com.example.A") // de-dupe
        service.addAutomaticExclusion("  com.example.B  ")
        XCTAssertEqual(service.automaticExclusions, ["com.example.A", "com.example.B"])
        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsKeys.shelfAutomaticExclusions),
            ["com.example.A", "com.example.B"])

        service.removeAutomaticExclusion("com.example.A")
        XCTAssertEqual(service.automaticExclusions, ["com.example.B"])
    }

    func test_syncWithPreferences_incrementsCounter() {
        let before = service.syncWithPreferencesCallCount
        service.syncWithPreferences()
        XCTAssertEqual(service.syncWithPreferencesCallCount, before + 1)
    }
}
