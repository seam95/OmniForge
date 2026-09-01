import AppKit
import XCTest
@testable import OmniForge

/// 限额卡窗口行布局回归：右侧列宽须容纳最宽文本形态，防止 lineLimit(1) 截断。
final class TokenUsageLimitCardLayoutTests: XCTestCase {
    /// 重置时间列：最宽形态 "HH:mm"（窗口剩余 < 6h 时出现）在 10pt 等宽字体下的
    /// 实测宽度必须小于列宽。回归背景：列宽 30pt 与文本恰好同宽压线，浮点舍入后被
    /// 截断成 "13:…"（30 → 36 修复）。
    func test_resetTimeColumn_fitsWidestHHmmText() {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let size = ("00:00" as NSString).size(withAttributes: [.font: font])
        XCTAssertLessThan(
            ceil(size.width),
            TokenUsageLimitCardView.resetTimeColumnWidth,
            "\"HH:mm\" 实测宽 \(size.width)pt 超出时间列宽，会被 lineLimit(1) 截断"
        )
    }
}
