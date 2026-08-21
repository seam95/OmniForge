import AppKit
import CoreGraphics
import XCTest
@testable import OmniForge

@MainActor
final class PinnedScreenshotRegistryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var pipeline: ScreenshotResultPipeline!
    private var registry: PinnedScreenshotRegistry!
    private var fixedDate: Date!

    override func setUp() {
        super.setUp()
        suiteName = "PinnedScreenshotRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        Defaults.register(in: defaults)
        fixedDate = Date(timeIntervalSince1970: 1_720_000_000)
        pipeline = ScreenshotResultPipeline(userDefaults: defaults)
        var tick = fixedDate!
        registry = PinnedScreenshotRegistry(pipeline: pipeline, now: {
            tick = tick.addingTimeInterval(1)
            return tick
        })
    }

    override func tearDown() {
        registry.closeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_register_enumerate_close() throws {
        let r1 = try makeResult(width: 40, height: 20)
        let r2 = try makeResult(width: 60, height: 30)
        let h1 = try registry.pin(result: r1)
        let h2 = try registry.pin(result: r2)
        XCTAssertEqual(registry.count, 2)
        let all = registry.allPinned()
        XCTAssertEqual(all.map(\.id), [h1.id, h2.id])
        XCTAssertEqual(all[0].displayLabel, "40×20")

        try registry.close(h1.id)
        XCTAssertEqual(registry.count, 1)
        XCTAssertEqual(registry.allPinned().map(\.id), [h2.id])

        XCTAssertThrowsError(try registry.close(h1.id)) { error in
            guard let pinError = error as? PinnedScreenshotError,
                  case .notFound = pinError else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
        XCTAssertThrowsError(try registry.copy(h1.id))
        XCTAssertThrowsError(try registry.setLocked(h1.id, true))
    }

    func test_lockAndClickThrough_queryableIndependently() throws {
        let handle = try registry.pin(result: try makeResult())
        try registry.setLocked(handle.id, true)
        try registry.setClickThrough(handle.id, true)
        let after = registry.handle(for: handle.id)!
        XCTAssertTrue(after.isLocked)
        XCTAssertTrue(after.isClickThrough)

        try registry.setLocked(handle.id, false)
        let unlocked = registry.handle(for: handle.id)!
        XCTAssertFalse(unlocked.isLocked)
        XCTAssertTrue(unlocked.isClickThrough)
    }

    func test_invalidImage_failsVisibly() {
        XCTAssertThrowsError(
            try registry.pin(
                image: try! makeImage(width: 10, height: 10),
                pointPixelScale: 0,
                preferredScreenFrame: nil,
                baseResult: nil
            )
        ) { error in
            XCTAssertEqual(error as? PinnedScreenshotError, .invalidGeometry)
        }
    }

    // MARK: - ESC 关闭（选中钉图）

    func test_newPin_isSelectedAndCanBeClosedWithEscape() throws {
        let h = try registry.pin(result: try makeResult())
        XCTAssertEqual(registry.count, 1)

        XCTAssertTrue(registry.closeSelectedPin())
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.handle(for: h.id))
    }

    func test_markTouched_switchesSelectedPin() throws {
        let h1 = try registry.pin(result: try makeResult())
        let h2 = try registry.pin(result: try makeResult())
        XCTAssertEqual(registry.count, 2)

        registry.markTouched(h1.id)
        XCTAssertTrue(registry.closeSelectedPin())
        XCTAssertEqual(registry.count, 1)
        XCTAssertNil(registry.handle(for: h1.id))
        XCTAssertNotNil(registry.handle(for: h2.id))
    }

    func test_clearingSelection_keepsPinsWhenEscapeIsPressed() throws {
        let h1 = try registry.pin(result: try makeResult())
        let h2 = try registry.pin(result: try makeResult())
        XCTAssertEqual(registry.count, 2)

        registry.clearSelectedPin()
        XCTAssertFalse(registry.closeSelectedPin())
        XCTAssertEqual(registry.count, 2)
        XCTAssertNotNil(registry.handle(for: h1.id))
        XCTAssertNotNil(registry.handle(for: h2.id))
    }

    func test_closingSelectedPin_doesNotFallBackToAnotherPin() throws {
        let h1 = try registry.pin(result: try makeResult())
        let h2 = try registry.pin(result: try makeResult())

        XCTAssertTrue(registry.closeSelectedPin())
        XCTAssertNil(registry.handle(for: h2.id))
        XCTAssertNotNil(registry.handle(for: h1.id))
        XCTAssertFalse(registry.closeSelectedPin())
        XCTAssertEqual(registry.count, 1)
    }

    func test_markTouched_unknownId_doesNotReplaceSelection() throws {
        let h = try registry.pin(result: try makeResult())
        registry.markTouched(UUID())

        XCTAssertTrue(registry.closeSelectedPin())
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.handle(for: h.id))
    }

    private func makeResult(width: Int = 20, height: Int = 10) throws -> ScreenshotResult {
        let image = try makeImage(width: width, height: height)
        let screen = CaptureTargetScreen(
            displayID: 1,
            frameInAppKitPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pointPixelScale: 2
        )
        return try ScreenshotResult(
            mode: .fullScreen,
            targetScreen: screen,
            selection: nil,
            timestamp: fixedDate,
            pixelImage: image,
            windowInfo: nil
        )
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = ctx.makeImage() else {
            struct E: Error {}
            throw E()
        }
        return image
    }
}
