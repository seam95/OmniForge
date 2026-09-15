import XCTest
@testable import OmniForge

final class ShelfSupportTests: XCTestCase {
    // MARK: - 降采样缩略图（审查 R18）

    /// 大图降采样：缩略图最长边不超预算，不驻留全尺寸解码。
    func test_downsampledThumbnail_capsToPixelBudget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfThumbTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 造 2000×1500 的 PNG。
        let context = CGContext(
            data: nil, width: 2000, height: 1500,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
        let cgImage = context.makeImage()!
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let png = rep.representation(using: .png, properties: [:])!
        let url = dir.appendingPathComponent("big.png")
        try png.write(to: url)

        let thumbnail = try XCTUnwrap(ShelfService.downsampledImageThumbnail(at: url))

        XCTAssertLessThanOrEqual(max(thumbnail.size.width, thumbnail.size.height), 512, "缩略图不超像素预算")
        XCTAssertGreaterThan(thumbnail.size.width, 0)
    }

    /// 缺失文件与损坏输入返回 nil（调用方降级文件图标）。
    func test_downsampledThumbnail_failsGracefully() {
        let missing = URL(fileURLWithPath: "/nonexistent/shelf-thumb-\(UUID().uuidString).png")
        XCTAssertNil(ShelfService.downsampledImageThumbnail(at: missing))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfThumbTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("junk.png")
        try? Data("not an image".utf8).write(to: junk)
        XCTAssertNil(ShelfService.downsampledImageThumbnail(at: junk))
    }

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
