import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 控制中心 footer 左区入口契约（信息架构重构 SPEC §5.1）：
/// 「功能」直达设置窗特性页（FeatureHub 正门），「设置」落默认页；顺序稳定、恒定显示。
@MainActor
final class ControlCenterFooterEntryTests: XCTestCase {
    func test_footerEntries_followStableOrder() {
        XCTAssertEqual(ControlCenterFooterEntry.allCases, [.features, .settings])
    }

    func test_footerEntries_deepLinkToExpectedSettingsTabs() {
        // 功能目录 → 设置窗特性页；设置 → 默认页（nil 语义）。
        XCTAssertEqual(ControlCenterFooterEntry.features.settingsTab, .features)
        XCTAssertNil(ControlCenterFooterEntry.settings.settingsTab)
    }

    func test_footerEntries_useExpectedIcons() {
        XCTAssertEqual(ControlCenterFooterEntry.features.systemImage, "puzzlepiece.extension")
        XCTAssertEqual(ControlCenterFooterEntry.settings.systemImage, "gearshape")
    }

    func test_footerEntryLabels_useStringsContract() {
        XCTAssertEqual(
            ControlCenterFooterEntry.features.label(in: .zhHans),
            Strings.zhHans.controlcenterFooterFeatures
        )
        XCTAssertEqual(ControlCenterFooterEntry.features.label(in: .en), "Features")
        XCTAssertEqual(
            ControlCenterFooterEntry.settings.label(in: .zhHans),
            Strings.zhHans.settingsTitle
        )
        // 新增键两语言均非空（本地化完整性）。
        XCTAssertFalse(Strings.zhHans.controlcenterFooterFeatures.isEmpty)
        XCTAssertFalse(Strings.en.controlcenterFooterFeatures.isEmpty)
    }

    /// 离屏渲染：footer 左区两个入口均渲染出内容（图标 + 文字）。
    func test_footerRendersBothLeftEntries() throws {
        let strings = Strings.zhHans
        let footer = HStack(spacing: 4) {
            ForEach(ControlCenterFooterEntry.allCases, id: \.self) { entry in
                FooterButton(label: entry.label(in: strings), systemImage: entry.systemImage) {}
            }
            Spacer()
        }
        .frame(width: ControlCenterContentMetrics.panelWidth, height: 36)
        .background(Color.white)
        .environment(\.colorScheme, .light)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ControlCenterContentMetrics.panelWidth, height: 36),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: footer)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        let width = Int(ControlCenterContentMetrics.panelWidth)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 36,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: CGFloat(width), height: 36)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()

        func containsInk(xRange: ClosedRange<Int>, threshold: CGFloat = 170) -> Bool {
            for y in 0..<36 {
                for x in xRange {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let r = c.redComponent * 255, g = c.greenComponent * 255, b = c.blueComponent * 255
                    if min(r, g, b) < threshold { return true }
                }
            }
            return false
        }

        // 左区（功能 + 设置两个入口）应渲染文字/图标内容。
        XCTAssertTrue(containsInk(xRange: 0...190), "footer 左区应渲染功能与设置两个入口")
        // 右区应为留白（Spacer），无内容污染。
        XCTAssertFalse(containsInk(xRange: 250...378), "footer 右区应保持留白")
    }
}
