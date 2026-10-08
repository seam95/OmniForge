// Tests/OmniForgeTests/System/ScreenCaptureMetadataTests.swift
import XCTest
@testable import OmniForge

final class ScreenCaptureMetadataTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scm-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeFile(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50]))
        return url
    }

    func testAppKitRectFlipsGlobalTopLeftY() {
        // 全局坐标 (x=10, y=20, w=100, h=200)，主屏 maxY=1000
        // AppKit: origin.y = 1000 - 20 - 200 = 780
        let rect = ScreenCaptureMetadata.appKitRect(x: 10, y: 20, w: 100, h: 200, mainScreenMaxY: 1000)
        XCTAssertEqual(rect, NSRect(x: 10, y: 780, width: 100, height: 200))
    }

    func testIsScreenCaptureTrueWhenXattrPresent() {
        let url = makeFile("a.png")
        setXattr(url, name: "com.apple.metadata:kMDItemIsScreenCapture", data: Data([1]))
        XCTAssertTrue(ScreenCaptureMetadata.isScreenCapture(url))
    }

    func testIsScreenCaptureFalseWhenXattrAbsent() {
        let url = makeFile("b.png")
        XCTAssertFalse(ScreenCaptureMetadata.isScreenCapture(url))
    }

    func testCaptureGlobalRectParsesPlistNumbers() {
        let url = makeFile("c.png")
        let plist = try! PropertyListSerialization.data(
            fromPropertyList: [10, 20, 100, 200] as [NSNumber], format: .binary, options: 0)
        setXattr(url, name: "com.apple.metadata:kMDItemScreenCaptureGlobalRect", data: plist)
        let rect = ScreenCaptureMetadata.captureGlobalRect(url, mainScreenMaxY: 1000)
        XCTAssertEqual(rect, NSRect(x: 10, y: 780, width: 100, height: 200))
    }

    func testCaptureGlobalRectNilForMissingOrMalformed() {
        XCTAssertNil(ScreenCaptureMetadata.captureGlobalRect(makeFile("d.png"), mainScreenMaxY: 1000))
        let bad = makeFile("e.png")
        setXattr(bad, name: "com.apple.metadata:kMDItemScreenCaptureGlobalRect", data: Data([1, 2]))
        XCTAssertNil(ScreenCaptureMetadata.captureGlobalRect(bad, mainScreenMaxY: 1000))
        // 宽高 <= 2 视为无效
        let tiny = makeFile("f.png")
        let plist = try! PropertyListSerialization.data(
            fromPropertyList: [0, 0, 1, 1] as [NSNumber], format: .binary, options: 0)
        setXattr(tiny, name: "com.apple.metadata:kMDItemScreenCaptureGlobalRect", data: plist)
        XCTAssertNil(ScreenCaptureMetadata.captureGlobalRect(tiny, mainScreenMaxY: 1000))
    }

    private func setXattr(_ url: URL, name: String, data: Data) {
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return data.withUnsafeBytes { buf in
                setxattr(path, name, buf.baseAddress, data.count, 0, 0) == 0
            }
        }
        XCTAssertTrue(ok)
    }
}
