import SwiftUI
import XCTest
@testable import OmniForge

/// 桌宠窗口拖动承载测试：阈值门控语义与拖动回调接线。
/// 拖动改由原生窗口拖动会话承担后，这里锁住两条不可回归的契约：
/// 位移识别阈值只在越过时才启动会话（单击永不拖动），以及窗口建好后回调已接线。
@MainActor
final class PetHostingViewDragTests: XCTestCase {
    private typealias Host = PetHostingView<AnyView>

    // MARK: - 位移识别阈值（纯函数）

    func test_thresholdIgnoresSubThresholdMovement() {
        // 单击 / 触摸板轻微抖动（<8pt）不得进入拖动会话。
        XCTAssertFalse(Host.dragExceedsThreshold(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 107.9, y: 100)
        ))
    }

    func test_thresholdTriggersAtExactlyEightPoints() {
        XCTAssertTrue(Host.dragExceedsThreshold(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 108, y: 100)
        ))
    }

    func test_thresholdUsesEuclideanDistanceForDiagonalMovement() {
        // 斜向 (±5, ±5) 的合成位移约 7.07pt：单轴都不过阈值，合成后仍不过。
        XCTAssertFalse(Host.dragExceedsThreshold(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 105, y: 105)
        ))
        // (±6, ±6) 合成约 8.49pt：任一单轴都 <8，但合成位移越过阈值。
        XCTAssertTrue(Host.dragExceedsThreshold(
            from: NSPoint(x: 100, y: 100),
            to: NSPoint(x: 106, y: 106)
        ))
    }

    // MARK: - 接线

    func test_panelHostingViewCarriesDragCallbacksAfterStart() throws {
        let suiteName = "PetHostingViewDragTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let assetRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-drag-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: assetRoot)
        }

        let clock = ManualFrameClock()
        let manager = DesktopPetManager(
            userDefaults: defaults,
            windowController: PetWindowController(petSize: CGSize(width: 96, height: 96)),
            assetStore: PetAssetStore(rootDirectory: assetRoot),
            stringsProvider: { Strings.zhHans },
            visibleScreensProvider: { [PetScreenGeometry(
                visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 800),
                identifier: "display-1"
            )] },
            tickInterval: 3600,
            frameClock: clock
        )
        manager.start()
        defer { manager.teardown() }

        let host = try XCTUnwrap(manager.windowController.panel?.contentView as? Host)
        XCTAssertNotNil(host.onWindowDragStart)
        XCTAssertNotNil(host.onWindowDragEnd)

        // 会话回调应驱动状态迁移：开始进 drag 态，结束回 idle。
        host.onWindowDragStart?()
        XCTAssertEqual(manager.behaviorState, .drag)
        host.onWindowDragEnd?()
        XCTAssertEqual(manager.behaviorState, .idle)
    }
}
