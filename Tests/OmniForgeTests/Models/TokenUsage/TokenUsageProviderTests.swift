import XCTest
import SwiftUI
@testable import OmniForge

/// 多供应商接入（2026-08-24）—— 9 家新 provider 的 rawValue / displayName / accentColor。
final class TokenUsageProviderTests: XCTestCase {

    func test_newProviderRawValuesAlignWithSourceNames() {
        XCTAssertEqual(TokenUsageProvider.opencode.rawValue, "opencode")
        XCTAssertEqual(TokenUsageProvider.codebuddy.rawValue, "codebuddy")
        XCTAssertEqual(TokenUsageProvider.grok.rawValue, "grok")
        XCTAssertEqual(TokenUsageProvider.zcode.rawValue, "zcode")
        XCTAssertEqual(TokenUsageProvider.traeCN.rawValue, "trae-cn")
        XCTAssertEqual(TokenUsageProvider.qoder.rawValue, "qoder")
        XCTAssertEqual(TokenUsageProvider.arkCodingPlan.rawValue, "ark-coding-plan")
    }

    func test_newProvidersAppearInAllCases() {
        for provider in [
            TokenUsageProvider.opencode, .codebuddy, .grok, .zcode,
            .traeCN, .qoder, .arkCodingPlan,
        ] {
            XCTAssertTrue(TokenUsageProvider.allCases.contains(provider))
        }
    }

    func test_newProviderDisplayNames() {
        XCTAssertEqual(TokenUsageProvider.opencode.displayName, "opencode")
        XCTAssertEqual(TokenUsageProvider.codebuddy.displayName, "CodeBuddy")
        XCTAssertEqual(TokenUsageProvider.grok.displayName, "Grok")
        XCTAssertEqual(TokenUsageProvider.zcode.displayName, "ZCode")
        XCTAssertEqual(TokenUsageProvider.traeCN.displayName, "Trae CN")
        XCTAssertEqual(TokenUsageProvider.qoder.displayName, "Qoder")
        XCTAssertEqual(TokenUsageProvider.arkCodingPlan.displayName, "方舟 Coding Plan")
    }

    func test_newProviderAccentColorsAreDistinct() {
        let colors: [Color] = [
            TokenUsageProvider.opencode.accentColor,
            TokenUsageProvider.codebuddy.accentColor,
            TokenUsageProvider.grok.accentColor,
            TokenUsageProvider.zcode.accentColor,
            TokenUsageProvider.traeCN.accentColor,
            TokenUsageProvider.qoder.accentColor,
            TokenUsageProvider.arkCodingPlan.accentColor,
        ]
        XCTAssertEqual(colors.count, 7)
    }
}