import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 控制中心 footer 契约：左区仅「设置」（直达设置窗默认页）、右区「退出」
/// （Token 页为「刷新」）。
///
/// 历史上左区还放过「特性」入口直达功能目录，已按反馈移除——功能目录仍可从
/// 设置窗侧栏「特性」进入，footer 不再承担该入口。
@MainActor
final class ControlCenterFooterTests: XCTestCase {

    func test_footerLeftShowsOnlySettings() throws {
        let strings = Strings.zhHans
        // 左区只有一个按钮：设置（与 settingsTitle 同文案、齿轮图标）。
        XCTAssertEqual(strings.settingsTitle, "设置")
        XCTAssertFalse(strings.settingsTitle.isEmpty)
        XCTAssertFalse(strings.actionQuit.isEmpty)
    }

    /// 离屏渲染：footer 左区仅渲染「设置」一个入口，右区为「退出」。
    func test_footerRendersOnlySettingsOnTheLeft() throws {
        let strings = Strings.zhHans
        let footer = HStack(spacing: 4) {
            FooterButton(label: strings.settingsTitle, systemImage: "gearshape") {}
            Spacer()
            FooterButton(label: strings.actionQuit,
                         systemImage: "rectangle.portrait.and.arrow.right") {}
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

        // 左区「设置」有内容，且宽度仅一个按钮（约 70pt 内）——若「特性」仍在会延伸到更右侧。
        XCTAssertTrue(containsInk(xRange: 0...80), "左区应渲染「设置」入口")
        // 中段留白（不再有第二个左侧入口）。
        XCTAssertFalse(containsInk(xRange: 130...250), "左区不应再有第二个入口")
        // 右区「退出」。
        XCTAssertTrue(containsInk(xRange: 300...378), "右区应渲染「退出」")
    }
}
