import AppKit
import SwiftUI
import XCTest
@testable import OmniForge

/// Top 列表维度切换（SPEC 2026-09-15）：维度文案契约 + 两维度渲染冒烟。
@MainActor
final class TokenUsageTopDimensionTests: XCTestCase {

    // MARK: - 文案契约

    func test_dimensionLabels_nonEmptyInBothLanguages() {
        for strings in [Strings.zhHans, Strings.en] {
            for dimension in TokenUsageTopDimension.allCases {
                XCTAssertFalse(dimension.label(strings).isEmpty, "\(dimension) 切换器文案在两语言下均非空")
                XCTAssertFalse(dimension.sectionTitle(strings).isEmpty, "\(dimension) 区头标题在两语言下均非空")
            }
        }
    }

    func test_dimensionLabels_chineseValues() {
        let strings = Strings.zhHans
        XCTAssertEqual(TokenUsageTopDimension.model.label(strings), "模型")
        XCTAssertEqual(TokenUsageTopDimension.app.label(strings), "App")
        XCTAssertEqual(TokenUsageTopDimension.model.sectionTitle(strings), "模型")
        XCTAssertEqual(TokenUsageTopDimension.app.sectionTitle(strings), "App")
    }

    func test_dimension_codableRoundTrip() throws {
        for dimension in TokenUsageTopDimension.allCases {
            let data = try JSONEncoder().encode(dimension)
            XCTAssertEqual(try JSONDecoder().decode(TokenUsageTopDimension.self, from: data), dimension)
        }
    }

    func test_dimension_caseOrder_isModelFirstAppSecond() {
        // 切换器选项顺序由 CaseIterable 声明序驱动，锁定「模型在前、App 在后」。
        XCTAssertEqual(TokenUsageTopDimension.allCases, [.model, .app])
    }

    // MARK: - 渲染冒烟

    /// 模型维度：名次彩色圆点行（provider 为 nil）可离屏渲染出非空位图。
    func test_render_modelDimension_smoke() throws {
        let entries = [
            UsageTopModelEntry(name: "claude-sonnet-4-5", tokens: 433_400, percent: 66.5),
            UsageTopModelEntry(name: "gpt-6-astra", tokens: 218_400, percent: 33.5),
        ]
        try assertRendersNonEmpty(entries: entries, dimension: .model)
    }

    /// App 维度：品牌 logo 行（provider 回填）可离屏渲染出非空位图。
    func test_render_appDimension_smoke() throws {
        let entries = [
            UsageTopModelEntry(name: "Codex", tokens: 512_300, percent: 58.2, provider: .codex),
            UsageTopModelEntry(name: "ZCode", tokens: 301_800, percent: 34.3, provider: .zcode),
            UsageTopModelEntry(name: "WorkBuddy", tokens: 65_200, percent: 7.4, provider: .workbuddy),
        ]
        try assertRendersNonEmpty(entries: entries, dimension: .app)
    }

    private func assertRendersNonEmpty(
        entries: [UsageTopModelEntry], dimension: TokenUsageTopDimension
    ) throws {
        var selection = dimension
        let view = TokenUsageTopModelsView(
            entries: entries,
            dimension: Binding(get: { selection }, set: { selection = $0 }),
            strings: .zhHans
        )
        .frame(width: 348)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 348, height: 120)
        host.layoutSubtreeIfNeeded()

        // 离屏渲染须走 cacheDisplay：host.draw + 手工 NSGraphicsContext 渲染不出 SwiftUI 内容。
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 348, pixelsHigh: 120,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        XCTAssertNotNil(rep)
        host.cacheDisplay(in: host.bounds, to: rep!)

        // 至少存在一个非透明像素（渲染非空白）。
        var opaquePixels = 0
        for x in stride(from: 0, to: 348, by: 4) {
            for y in stride(from: 0, to: 120, by: 4) {
                if let color = rep!.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    opaquePixels += 1
                }
            }
        }
        XCTAssertGreaterThan(opaquePixels, 10, "\(dimension) 维度渲染不应为空白")
    }
}
