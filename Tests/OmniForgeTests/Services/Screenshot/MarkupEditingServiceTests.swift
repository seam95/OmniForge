// Tests/OmniForgeTests/Services/Screenshot/MarkupEditingServiceTests.swift
import XCTest
@testable import OmniForge

private final class FakeMarkupIO: MarkupFileIO {
    var reads: [URL] = []
    var writes: [(URL, Data)] = []
    var stubData: Data?
    func dataContents(of url: URL) -> Data? { reads.append(url); return stubData }
    func write(data: Data, to url: URL) throws { writes.append((url, data)) }
}

final class MarkupEditingServiceTests: XCTestCase {
    private var io: FakeMarkupIO!
    private var target: URL!

    override func setUp() {
        super.setUp()
        io = FakeMarkupIO()
        target = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID()).png")
    }

    func testWriteBackWithURLSamePathShortCircuits() {
        // 扩展写回同一路径：仅回调保存成功，不再读写
        let ok = MarkupEditingService.writeBack(items: [target!], target: target!, io: io)
        XCTAssertTrue(ok)
        XCTAssertTrue(io.reads.isEmpty)
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testWriteBackWithDataURLCopiesData() {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID()).png")
        io.stubData = Data([1, 2, 3])
        let ok = MarkupEditingService.writeBack(items: [source], target: target!, io: io)
        XCTAssertTrue(ok)
        XCTAssertEqual(io.writes.first?.1, Data([1, 2, 3]))
    }

    func testWriteBackWithNSImageEncodesPNG() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let ok = MarkupEditingService.writeBack(items: [image], target: target!, io: io)
        XCTAssertTrue(ok)
        let written = try XCTUnwrap(io.writes.first?.1)
        XCTAssertFalse(written.isEmpty)
        XCTAssertNotNil(NSBitmapImageRep(data: written))   // 是合法位图
    }

    func testWriteBackNilDataFails() {
        io.stubData = nil
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("none.png")
        XCTAssertFalse(MarkupEditingService.writeBack(items: [source], target: target!, io: io))
        XCTAssertTrue(io.writes.isEmpty)
    }

    func testWriteBackEmptyItemsFails() {
        XCTAssertFalse(MarkupEditingService.writeBack(items: [], target: target!, io: io))
    }
}
