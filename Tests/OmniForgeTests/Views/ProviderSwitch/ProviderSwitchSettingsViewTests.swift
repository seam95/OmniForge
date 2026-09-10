import XCTest
import SwiftUI
@testable import OmniForge

final class ProviderSwitchSettingsViewTests: XCTestCase {
    func test_settingsPresentation_properties() {
        XCTAssertTrue(ProviderSwitchPresentation.settings.showsInlineAddProviderButton)
        // 设置窗口顶部已有「+ 新增供应商」主按钮，弹层内不重复提供。
        XCTAssertFalse(ProviderSwitchPresentation.settings.showsSettingsPopoverAddProvider)
        XCTAssertTrue(ProviderSwitchPresentation.settings.showsProfileManagementMenu)
        XCTAssertFalse(ProviderSwitchPresentation.settings.showsLaunchCommandCopyButton)
        XCTAssertEqual(
            ProviderSwitchPresentation.settings.addProviderRoute,
            .profileEditor
        )
    }

    func test_menuBarPresentation_properties() {
        XCTAssertFalse(ProviderSwitchPresentation.menuBar.showsInlineAddProviderButton)
        // 菜单栏无顶部主按钮，「新增供应商」收入齿轮弹层。
        XCTAssertTrue(ProviderSwitchPresentation.menuBar.showsSettingsPopoverAddProvider)
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
        // 卡片化视觉常量（设计稿对齐）：圆角 14 / 间距 10 / logo 40 圆角 12。
        XCTAssertEqual(ProviderCardVisual.cornerRadius, 14)
        XCTAssertEqual(ProviderCardVisual.cardSpacing, 10)
        XCTAssertEqual(ProviderCardVisual.logoSize, 40)
        XCTAssertEqual(ProviderCardVisual.logoCornerRadius, 12)
        XCTAssertEqual(ProviderCardVisual.normalCardFill, .white)
    }

    func test_providerCardVisual_activeBorder_usesAccentTint() {
        // 激活描边为强调蓝 35% 透明度（设计稿关键值）：必须与非激活发丝描边区分开。
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertNotEqual(ProviderCardVisual.activeBorder(scheme), ProviderCardVisual.border)
        }
    }

    func test_providerBrandVisual_designContainerOverrides() {
        // 设计稿 logo 容器：DeepSeek 浅蓝底 #E8F1FB + 蓝标，Kimi 墨黑底 #1D1D1F + 白标。
        let deepseek = ProviderBrandVisual.visual(name: "DeepSeek", baseURL: "https://api.deepseek.com")
        XCTAssertEqual(deepseek.containerColor, Color(red: 0xE8 / 255.0, green: 0xF1 / 255.0, blue: 0xFB / 255.0))
        XCTAssertEqual(deepseek.logoTint, Color(red: 0x00 / 255.0, green: 0x66 / 255.0, blue: 0xCC / 255.0))

        let kimi = ProviderBrandVisual.visual(name: "Kimi 月之暗面", baseURL: "https://api.moonshot.cn")
        XCTAssertEqual(kimi.containerColor, Color(red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0))
        XCTAssertNil(kimi.logoTint)

        // 未覆盖品牌保持 nil（走品牌色底 + 白标兜底）。
        XCTAssertNil(ProviderBrandVisual.visual(name: "MyCustomProvider", baseURL: "https://example.com").containerColor)
    }

    func test_launchCommandCopyLocalization_isAvailable() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.providerCopyLaunchCommand.isEmpty)
            XCTAssertFalse(strings.providerLaunchCommandCopied.isEmpty)
            XCTAssertFalse(strings.providerLaunchCommandCopyFailed.isEmpty)
        }
    }

    /// 齿轮弹层（收纳原底部三链接动作）标题与动作文案中英齐全。
    func test_settingsPopoverLocalization_isAvailable() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.providerSettingsPopoverTitle.isEmpty)
            XCTAssertFalse(strings.providerAddProvider.isEmpty)
            XCTAssertFalse(strings.providerEditConfigFile.isEmpty)
            XCTAssertFalse(strings.providerRestoreBackup.isEmpty)
        }
    }

    /// 齿轮与弹层动作的无障碍标识（UI 测试 / 自动化探针定位用）。
    func test_settingsPopoverAccessibilityIDs_areDistinct() {
        let ids = [
            SettingsAccessibilityID.providerSwitchGearButton,
            SettingsAccessibilityID.providerSwitchPopoverAddProvider,
            SettingsAccessibilityID.providerSwitchPopoverEditConfig,
            SettingsAccessibilityID.providerSwitchPopoverRestoreBackup,
        ]
        XCTAssertEqual(Set(ids.map(\.rawValue)).count, ids.count)
    }
}
