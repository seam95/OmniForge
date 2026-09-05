import XCTest
@testable import OmniForge

final class ProviderSwitchSettingsViewTests: XCTestCase {
    func test_settingsPresentation_properties() {
        XCTAssertTrue(ProviderSwitchPresentation.settings.showsInlineAddProviderButton)
        XCTAssertFalse(ProviderSwitchPresentation.settings.showsFooterAddProviderLink)
        XCTAssertTrue(ProviderSwitchPresentation.settings.showsProfileManagementMenu)
        XCTAssertFalse(ProviderSwitchPresentation.settings.showsLaunchCommandCopyButton)
        XCTAssertEqual(
            ProviderSwitchPresentation.settings.addProviderRoute,
            .profileEditor
        )
    }

    func test_menuBarPresentation_properties() {
        XCTAssertFalse(ProviderSwitchPresentation.menuBar.showsInlineAddProviderButton)
        XCTAssertTrue(ProviderSwitchPresentation.menuBar.showsFooterAddProviderLink)
        XCTAssertTrue(ProviderSwitchPresentation.menuBar.showsProfileManagementMenu)
        XCTAssertFalse(ProviderSwitchPresentation.menuBar.showsLaunchCommandCopyButton)
        XCTAssertEqual(
            ProviderSwitchPresentation.menuBar.addProviderRoute,
            .providerSettings
        )
    }

    func test_providerBrandVisual_resolvesExpectedLetters() {
        XCTAssertEqual(ProviderBrandVisual.visual(name: "DeepSeek", baseURL: "https://api.deepseek.com").letter, "D")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "Kimi 月之暗面", baseURL: "https://api.moonshot.cn").letter, "K")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn").letter, "G")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "MiniMax", baseURL: "https://api.minimax.chat").letter, "M")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "OpenAI", baseURL: "https://api.openai.com").letter, "O")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "Claude", baseURL: "https://api.anthropic.com").letter, "A")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com").letter, "Q")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "Ollama", baseURL: "http://localhost:11434").letter, "O")
        XCTAssertEqual(ProviderBrandVisual.visual(name: "MyCustomProvider", baseURL: "https://example.com").letter, "M")
    }

    func test_officialLogo_mapsToolToBrandLogo() {
        XCTAssertEqual(ProviderBrandVisual.officialLogo(for: .claudeCode), ProviderLogoAssets.claude)
        XCTAssertEqual(ProviderBrandVisual.officialLogo(for: .codex), ProviderLogoAssets.openai)
    }

    func test_providerCardVisual_constants() {
        // 卡片化视觉常量（设计稿对齐）：圆角 14 / 间距 10 / logo 44 圆角 12。
        XCTAssertEqual(ProviderCardVisual.cornerRadius, 14)
        XCTAssertEqual(ProviderCardVisual.cardSpacing, 10)
        XCTAssertEqual(ProviderCardVisual.logoSize, 44)
        XCTAssertEqual(ProviderCardVisual.logoCornerRadius, 12)
        XCTAssertEqual(ProviderCardVisual.background, .white)
    }

    func test_providerCardVisual_activeBorder_usesAccentTint() {
        // 激活描边为 accent tint：必须与非激活发丝描边区分开。
        XCTAssertNotEqual(ProviderCardVisual.activeBorder, ProviderCardVisual.border)
    }

    func test_launchCommandCopyLocalization_isAvailable() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.providerCopyLaunchCommand.isEmpty)
            XCTAssertFalse(strings.providerLaunchCommandCopied.isEmpty)
            XCTAssertFalse(strings.providerLaunchCommandCopyFailed.isEmpty)
        }
    }
}
