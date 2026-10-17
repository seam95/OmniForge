import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// 控制中心顶部 Tab 导航样式契约：
/// 浅色模式下整体背景为纯白（#FFFFFF），无外层灰色轨道，
/// 选中 Tab 为浅蓝药丸底（#EBF3FE）搭配鲜亮蓝字（#0D7FFD），
/// 未选中 Tab 为石板炭灰（#4A4B56）。
@MainActor
final class ControlCenterNavigationStyleTests: XCTestCase {

    func test_menuPanelSymbolsAndTitles() {
        let strings = Strings.zhHans
        let panels = MenuPanel.primaryCases
        XCTAssertEqual(panels.count, 4)
        XCTAssertEqual(panels[0].navTitle(in: strings), "监控")
        XCTAssertEqual(panels[1].navTitle(in: strings), "Token")
        XCTAssertEqual(panels[2].navTitle(in: strings), "供应商")
        XCTAssertEqual(panels[3].navTitle(in: strings), "工具")

        XCTAssertEqual(panels[0].symbolName, "waveform.path.ecg")
        XCTAssertEqual(panels[1].symbolName, "chart.line.uptrend.xyaxis")
        XCTAssertEqual(panels[2].symbolName, "arrow.triangle.swap")
        XCTAssertEqual(panels[3].symbolName, "wrench.fill")
    }

    /// 离屏渲染核对：导航区背景为全白，选中项为浅蓝药丸底（#EBF3FE），未选中项无底块。
    func test_navButtonActiveStyleRendersBluePill() throws {
        struct NavTestHost: View {
            @Namespace private var ns
            var body: some View {
                HStack(spacing: 4) {
                    ControlCenterNavButton(
                        panel: .systemMonitor,
                        title: "监控",
                        isActive: true,
                        activeFill: Color(red: 0xEB / 255.0, green: 0xF3 / 255.0, blue: 0xFE / 255.0),
                        activeForeground: Color(red: 0x0D / 255.0, green: 0x7F / 255.0, blue: 0xFD / 255.0),
                        inactiveForeground: Color(red: 0x4A / 255.0, green: 0x4B / 255.0, blue: 0x56 / 255.0),
                        colorScheme: .light,
                        indicatorNamespace: ns,
                        action: {}
                    )
                    ControlCenterNavButton(
                        panel: .tokenUsage,
                        title: "Token",
                        isActive: false,
                        activeFill: Color(red: 0xEB / 255.0, green: 0xF3 / 255.0, blue: 0xFE / 255.0),
                        activeForeground: Color(red: 0x0D / 255.0, green: 0x7F / 255.0, blue: 0xFD / 255.0),
                        inactiveForeground: Color(red: 0x4A / 255.0, green: 0x4B / 255.0, blue: 0x56 / 255.0),
                        colorScheme: .light,
                        indicatorNamespace: ns,
                        action: {}
                    )
                }
                .padding(8)
                .background(Color.white)
                .frame(width: 200, height: 44)
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: NavTestHost().environment(\.colorScheme, .light))
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 44,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            XCTFail("无法创建位图")
            return
        }
        rep.size = NSSize(width: 200, height: 44)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        hosting.cacheDisplay(in: NSRect(x: 0, y: 0, width: 200, height: 44), to: rep)
        NSGraphicsContext.restoreGraphicsState()

        // 1. 检查背景四周为纯白 (#FFFFFF)
        var whiteCount = 0
        for x in [2, 4, 196, 198] {
            for y in 2..<10 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent > 0.98 && c.greenComponent > 0.98 && c.blueComponent > 0.98 {
                    whiteCount += 1
                }
            }
        }
        XCTAssertGreaterThan(whiteCount, 20, "Tab 切换区四周背景应为纯白 #FFFFFF")

        // 2. 检查选中项存在浅蓝药丸背景 (#EBF3FE 范围)
        var bluePillPixelCount = 0
        for x in 0..<100 {
            for y in 0..<44 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.blueComponent > 0.90 && c.redComponent > 0.85 && (c.blueComponent - c.redComponent) > 0.03 {
                    bluePillPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(bluePillPixelCount, 50, "选中 Tab 应渲染浅蓝药丸底块 (#EBF3FE)")

        // 3. 检查未选中项区域无浅蓝药丸底块
        var unselectedBluePillCount = 0
        for x in 100..<200 {
            for y in 0..<44 {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.blueComponent > 0.90 && c.redComponent > 0.85 && (c.blueComponent - c.redComponent) > 0.03 {
                    unselectedBluePillCount += 1
                }
            }
        }
        XCTAssertEqual(unselectedBluePillCount, 0, "未选中项不应有浅蓝药丸底块")
    }
}
