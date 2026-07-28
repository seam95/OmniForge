import XCTest
@testable import OmniForge

final class ShelfSupportTests: XCTestCase {
    func test_allowsAutomaticOpen_blocksExcludedOnly() {
        XCTAssertTrue(ShelfInteractionSupport.allowsAutomaticOpen(
            sourceBundleIdentifier: "com.example.Editor",
            excludedBundleIdentifiers: ["com.example.Browser"]))
        XCTAssertFalse(ShelfInteractionSupport.allowsAutomaticOpen(
            sourceBundleIdentifier: "com.example.Browser",
            excludedBundleIdentifiers: ["com.example.Browser"]))
        XCTAssertTrue(ShelfInteractionSupport.allowsAutomaticOpen(
            sourceBundleIdentifier: nil,
            excludedBundleIdentifiers: ["com.example.Browser"]))
    }

    func test_shouldCloseAfterDrag_truthTable() {
        XCTAssertTrue(ShelfInteractionSupport.shouldCloseAfterDrag(
            dropAccepted: true, draggedItemCount: 2, closeAfterDrop: true, pinned: false))
        XCTAssertFalse(ShelfInteractionSupport.shouldCloseAfterDrag(
            dropAccepted: false, draggedItemCount: 2, closeAfterDrop: true, pinned: false))
        XCTAssertFalse(ShelfInteractionSupport.shouldCloseAfterDrag(
            dropAccepted: true, draggedItemCount: 0, closeAfterDrop: true, pinned: false))
        XCTAssertFalse(ShelfInteractionSupport.shouldCloseAfterDrag(
            dropAccepted: true, draggedItemCount: 2, closeAfterDrop: true, pinned: true))
    }

    func test_shouldRemoveAfterDrag_respectsPreference() {
        XCTAssertTrue(ShelfInteractionSupport.shouldRemoveAfterDrag(
            dropAccepted: true, draggedItemCount: 1, removeAfterDrop: true))
        XCTAssertFalse(ShelfInteractionSupport.shouldRemoveAfterDrag(
            dropAccepted: true, draggedItemCount: 1, removeAfterDrop: false))
    }

    func test_persistedItem_roundTrip() throws {
        let file = ShelfPersistedItem(id: UUID(), kind: .file, title: "notes.pdf", path: "/tmp/notes.pdf")
        let text = ShelfPersistedItem(id: UUID(), kind: .text, title: "Hello", text: "Hello world")
        let link = ShelfPersistedItem(id: UUID(), kind: .link, title: "example.com", url: "https://example.com/page")
        let batch = ShelfPersistedItem(id: UUID(), kind: .batch, title: "batch", children: [file, text])
        let original = [file, text, link, batch]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([ShelfPersistedItem].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_sanitized_dropsMissingFilesKeepsText() {
        let file = ShelfPersistedItem(id: UUID(), kind: .file, title: "a", path: "/missing")
        let text = ShelfPersistedItem(id: UUID(), kind: .text, title: "t", text: "hi")
        let result = ShelfPersistenceSupport.sanitized([file, text]) { _ in false }
        XCTAssertEqual(result, [text])
    }

    func test_sanitized_collapsesSingleChildBatch() {
        let file = ShelfPersistedItem(id: UUID(), kind: .file, title: "a", path: "/a")
        let text = ShelfPersistedItem(id: UUID(), kind: .text, title: "t", text: "hi")
        let batch = ShelfPersistedItem(id: UUID(), kind: .batch, title: "b", children: [file, text])
        let result = ShelfPersistenceSupport.sanitized([batch]) { _ in false }
        XCTAssertEqual(result, [text])
    }

    func test_unmountedVolumeRoot() {
        XCTAssertEqual(
            ShelfPersistenceSupport.unmountedVolumeRoot(of: "/Volumes/NAS/docs/a.txt"),
            "/Volumes/NAS")
        XCTAssertNil(ShelfPersistenceSupport.unmountedVolumeRoot(of: "/Users/me/a.txt"))
    }

    func test_sanitized_dropsWhitespaceTextAndInvalidLinks() {
        let blank = ShelfPersistedItem(id: UUID(), kind: .text, title: "", text: "  \n ")
        let bad = ShelfPersistedItem(id: UUID(), kind: .link, title: "x", url: "not a url##")
        let fileLink = ShelfPersistedItem(id: UUID(), kind: .link, title: "x", url: "file:///etc/hosts")
        XCTAssertTrue(ShelfPersistenceSupport.sanitized([blank, bad, fileLink]) { _ in true }.isEmpty)
    }
}
