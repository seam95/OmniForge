import AppKit
import XCTest
@testable import OmniForge

final class ClipboardImageDownsamplerTests: XCTestCase {
    func test_imageDownsamplesToRequestedPixelSize() throws {
        let source = NSImage(size: NSSize(width: 1200, height: 600))
        source.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 600).fill()
        source.unlockFocus()
        let data = try XCTUnwrap(source.tiffRepresentation)

        let result = try XCTUnwrap(
            ClipboardImageDownsampler.image(data: data, maxPixelSize: 300)
        )
        let representation = try XCTUnwrap(result.representations.first)

        XCTAssertLessThanOrEqual(
            max(representation.pixelsWide, representation.pixelsHigh),
            300
        )
        XCTAssertEqual(
            representation.pixelsWide,
            representation.pixelsHigh * 2,
            accuracy: 1
        )
    }

    func test_invalidDataReturnsNil() {
        XCTAssertNil(
            ClipboardImageDownsampler.image(data: Data([0, 1]), maxPixelSize: 300)
        )
    }
}
