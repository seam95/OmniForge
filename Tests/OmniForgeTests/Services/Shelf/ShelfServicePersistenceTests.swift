import AppKit
import XCTest
@testable import OmniForge

@MainActor
final class ShelfServicePersistenceTests: XCTestCase {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "shelf-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        Defaults.register(in: defaults)
        return (defaults, name)
    }

    private func makeStore() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfServicePersist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_restore_preservesExistingItems_andSanitizes() async throws {
        let (defaults, _) = makeSuite()
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let textID = UUID()
        let missingFileID = UUID()
        let goodFileID = UUID()
        let goodFile = store.appendingPathComponent("kept.txt")
        try "kept".write(to: goodFile, atomically: true, encoding: .utf8)

        let persisted: [ShelfPersistedItem] = [
            ShelfPersistedItem(id: textID, kind: .text, title: "Hello", text: "Hello world"),
            ShelfPersistedItem(id: missingFileID, kind: .file, title: "gone", path: "/tmp/definitely-missing-\(UUID().uuidString)"),
            ShelfPersistedItem(id: goodFileID, kind: .file, title: "kept.txt", path: goodFile.path),
        ]
        let data = try JSONEncoder().encode(persisted)
        defaults.set(data, forKey: UserDefaultsKeys.shelfItems)

        let service = ShelfService(userDefaults: defaults, storeDirectory: store)
        let ok = await service.waitForRestoreForTesting()
        XCTAssertTrue(ok)

        let ids = Set(service.items.map(\.id))
        XCTAssertTrue(ids.contains(textID), "valid text should restore")
        XCTAssertTrue(ids.contains(goodFileID), "existing file should restore")
        XCTAssertFalse(ids.contains(missingFileID), "missing file should be sanitized away")
        XCTAssertEqual(service.itemCount, 2)

        // Text payload
        let textItem = service.items.first { $0.id == textID }
        if case let .text(text)? = textItem?.payload {
            XCTAssertEqual(text, "Hello world")
        } else {
            XCTFail("expected text item")
        }
    }

    func test_persist_roundTrip_afterMutation() async throws {
        let (defaults, _) = makeSuite()
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let service = ShelfService(userDefaults: defaults, storeDirectory: store)
        _ = await service.waitForRestoreForTesting()

        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("persist me", forType: .string)
        XCTAssertTrue(service.accept(pasteboard: pb))
        await service.flushPersistForTesting()

        guard let data = defaults.data(forKey: UserDefaultsKeys.shelfItems) else {
            return XCTFail("expected shelfItems data after persist")
        }
        let decoded = try JSONDecoder().decode([ShelfPersistedItem].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].kind, .text)
        XCTAssertEqual(decoded[0].text, "persist me")

        // New service instance restores the same text.
        let service2 = ShelfService(userDefaults: defaults, storeDirectory: store)
        _ = await service2.waitForRestoreForTesting()
        XCTAssertEqual(service2.itemCount, 1)
        if case let .text(text) = service2.items[0].payload {
            XCTAssertEqual(text, "persist me")
        } else {
            XCTFail("expected restored text")
        }
    }

    func test_restoreGate_blocksEarlyPersistOverwrite() async throws {
        let (defaults, _) = makeSuite()
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store) }

        let savedID = UUID()
        let saved = [ShelfPersistedItem(id: savedID, kind: .text, title: "saved", text: "from disk")]
        defaults.set(try JSONEncoder().encode(saved), forKey: UserDefaultsKeys.shelfItems)

        let service = ShelfService(userDefaults: defaults, storeDirectory: store)
        // Immediately after init, restore may not have completed; accept is still allowed
        // and should merge after restore without wiping saved items.
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("live add", forType: .string)
        XCTAssertTrue(service.accept(pasteboard: pb))

        _ = await service.waitForRestoreForTesting()
        // Restored + live.
        XCTAssertGreaterThanOrEqual(service.itemCount, 2)
        let texts: [String] = service.items.compactMap {
            if case let .text(t) = $0.payload { return t }
            return nil
        }
        XCTAssertTrue(texts.contains("from disk"))
        XCTAssertTrue(texts.contains("live add"))
    }
}
