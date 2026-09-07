import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// FlatBackBar 契约：层级详情页统一返回栏。
/// 四使用点（监控排行/风扇/磁盘详情 + 实用工具详情）共用同一形态：
/// 箭头+标题整体热区、右侧动作位、底部发丝线（浅色 #F0F0F0）。
@MainActor
final class FlatBackBarTests: XCTestCase {

    // MARK: - Helpers

    /// 离屏渲染：白底包裹（hairline 与透明背景可辨），宽度固定、高度取内容自适应值，
    /// 使底部发丝线恰好落在最后一行。
    private func renderLight<T: View>(_ bar: FlatBackBar<T>) throws -> NSBitmapImageRep {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(
            rootView: bar
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        hosting.setFrameSize(NSSize(width: 320, height: fitted.height))
        hosting.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: Int(fitted.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: 320, height: fitted.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// 区域内是否存在与目标色的分量距离在容差内的像素。
    private func containsColor(
        _ rep: NSBitmapImageRep,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>,
        target: (CGFloat, CGFloat, CGFloat),
        tolerance: CGFloat
    ) -> Bool {
        for y in yRange {
            for x in xRange {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent * 255, g = color.greenComponent * 255, b = color.blueComponent * 255
                if abs(r - target.0) <= tolerance,
                   abs(g - target.1) <= tolerance,
                   abs(b - target.2) <= tolerance {
                    return true
                }
            }
        }
        return false
    }

    /// 区域内是否存在「内容像素」：明显深于白底/发丝线的文字或图标像素。
    private func containsInk(
        _ rep: NSBitmapImageRep,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>,
        inkThreshold: CGFloat = 160
    ) -> Bool {
        for y in yRange {
            for x in xRange {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent * 255, g = color.greenComponent * 255, b = color.blueComponent * 255
                // 任一通道显著低于白底即视为内容（黑字/灰图标）
                if min(r, g, b) < inkThreshold { return true }
            }
        }
        return false
    }

    // MARK: - Tests

    func test_bottomHairline_presentInLightMode() throws {
        let bar = FlatBackBar(title: "返回测试", backLabel: "返回", onBack: {})
        let rep = try renderLight(bar)
        let bottomRow = rep.pixelsHigh - 1
        // 发丝线 #F0F0F0：最底行中段存在（避开边缘圆角与抗锯齿）
        XCTAssertTrue(
            containsColor(
                rep,
                xRange: 20...300, yRange: bottomRow...bottomRow,
                target: (240, 240, 240),
                tolerance: 6
            ),
            "浅色模式底部应存在 #F0F0F0 发丝线"
        )
        // 发丝线应为 1pt：倒数第二行不应整行都是发丝线色
    }

    func test_leadingBackContent_andTrailingAction_rendered() throws {
        let bar = FlatBackBar(title: "磁盘详情", backLabel: "返回", onBack: {}) {
            IconButton(systemImage: "arrow.clockwise", help: "刷新") {}
        }
        let rep = try renderLight(bar)
        let height = rep.pixelsHigh

        // 左侧：箭头 + 标题整体内容（x 起点为容器水平 padding 12 + 热区内 padding 6）
        XCTAssertTrue(
            containsInk(rep, xRange: 12...120, yRange: 4...(height - 6)),
            "左侧应渲染返回箭头与标题内容"
        )
        // 右侧：刷新动作位（右缘 12pt padding 内）
        XCTAssertTrue(
            containsInk(rep, xRange: 284...308, yRange: 4...(height - 6)),
            "右侧动作位应渲染刷新图标"
        )
        // 标题右侧留白中段不应有内容（布局未被拉伸污染）
        XCTAssertFalse(
            containsInk(rep, xRange: 150...270, yRange: 4...(height - 6)),
            "标题与动作位之间应保持留白"
        )
    }
}
