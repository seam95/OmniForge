import XCTest
import SwiftUI
@testable import OmniForge

final class ProviderSwitchSettingsViewTests: XCTestCase {
    /// 供应商切换的唯一界面入口是菜单栏控制中心 tab：设置侧栏不再有该页
    /// （功能本体 AppFeature.providerSwitch 保留，仅供控制中心消费）。
    func test_providerSwitchEntry_isMenuBarOnly() {
        XCTAssertNil(SettingsToolbarTab(rawValue: "providerSwitch"))
        XCTAssertEqual(
            MenuPanel.visibleCases(isAvailable: { $0 == .providerSwitch }),
            [.providerSwitch]
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

    /// 齿轮弹层（收纳新增 / 编辑配置文件 / 恢复备份三个动作）标题与动作文案中英齐全；
    /// 弹层动作行为纯文字列表项，不带「+」前缀。
    func test_settingsPopoverLocalization_isAvailable() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.providerSettingsPopoverTitle.isEmpty)
            XCTAssertFalse(strings.providerAddProviderAction.isEmpty)
            XCTAssertFalse(strings.providerEditConfigFile.isEmpty)
            XCTAssertFalse(strings.providerRestoreBackup.isEmpty)
            XCTAssertFalse(
                strings.providerAddProviderAction.hasPrefix("+"),
                "弹层动作行不应带「+」前缀"
            )
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

    // MARK: - 模式两行（直连 / 聚合）

    /// 默认展开哪一行，看哪个模式真的在生效。聚合生效时若默认展开直连，
    /// 用户第一眼看到的是一排被锁死的操作（`directActionsDisabled`）。
    func test_initialPanelMode_followsWhatIsActuallyActive() {
        XCTAssertEqual(ProviderModeRow.initialMode(isAggregating: false), .direct)
        XCTAssertEqual(ProviderModeRow.initialMode(isAggregating: true), .aggregation)
    }

    /// 聚合生效时直连行必须说明「已暂停」，不能显示激活供应商——
    /// 否则用户展开才发现里面全是禁用控件。
    func test_directRowSummary_explainsPauseWhenAggregating() {
        XCTAssertEqual(
            ProviderModeRow.directSummary(activeName: "Kimi", isAggregating: true, strings: .zhHans),
            Strings.zhHans.providerModeDirectPaused
        )
        XCTAssertEqual(
            ProviderModeRow.directSummary(activeName: "Kimi", isAggregating: false, strings: .zhHans),
            "使用 Kimi"
        )
        // 未托管 / 损坏等匹配不到 profile 的状态 → 回落官方
        XCTAssertEqual(
            ProviderModeRow.directSummary(activeName: nil, isAggregating: false, strings: .zhHans),
            Strings.zhHans.providerModeDirectOfficial
        )
        XCTAssertEqual(
            ProviderModeRow.directSummary(activeName: "", isAggregating: false, strings: .zhHans),
            Strings.zhHans.providerModeDirectOfficial
        )
    }

    /// 聚合行摘要区分三态：未开启且有人可加入 / 未开启且无人可加入 / 已开启。
    func test_aggregationRowSummary_distinguishesOffJoinableOffAndOn() {
        let kimi = ProviderAggregationManager.AggregationMemberView(id: "kimi", name: "Kimi", isDefault: true, isOfficial: false,
                                         publishedCount: 2, modelIDs: ["a", "b"])
        let glm = ProviderAggregationManager.AggregationMemberView(id: "glm", name: "GLM", isDefault: false, isOfficial: false,
                                        publishedCount: 1, modelIDs: ["c"])

        XCTAssertEqual(
            ProviderModeRow.aggregationSummary(members: [], joinableCount: 2, strings: .zhHans),
            "未开启 · 2 家可加入"
        )
        XCTAssertEqual(
            ProviderModeRow.aggregationSummary(members: [], joinableCount: 0, strings: .zhHans),
            Strings.zhHans.providerModeAggregationOff
        )
        XCTAssertEqual(
            ProviderModeRow.aggregationSummary(members: [kimi, glm], joinableCount: 1, strings: .zhHans),
            "2 家 · 默认 Kimi"
        )
    }

    /// 模式两行的标题与摘要文案中英齐全（标题复用既有 `providerMode*` 键）。
    func test_modeRowLocalization_isAvailable() {
        for strings in [Strings.zhHans, Strings.en] {
            XCTAssertFalse(strings.providerModeDirect.isEmpty)
            XCTAssertFalse(strings.providerModeAggregation.isEmpty)
            XCTAssertFalse(strings.providerModeDirectPaused.isEmpty)
            XCTAssertFalse(strings.providerModeDirectOfficial.isEmpty)
            XCTAssertFalse(strings.providerModeDirectActiveFormat.isEmpty)
            XCTAssertFalse(strings.providerModeAggregationOff.isEmpty)
            XCTAssertFalse(strings.providerModeAggregationOffJoinableFormat.isEmpty)
            XCTAssertFalse(strings.providerModeAggregationOnFormat.isEmpty)
            // 格式串必须真的带占位符，否则 String(format:) 会原样返回
            XCTAssertTrue(strings.providerModeDirectActiveFormat.contains("%@"))
            XCTAssertTrue(strings.providerModeAggregationOffJoinableFormat.contains("%ld"))
            XCTAssertTrue(strings.providerModeAggregationOnFormat.contains("%ld"))
            XCTAssertTrue(strings.providerModeAggregationOnFormat.contains("%@"))
        }
    }

    /// 模式两行的无障碍标识（UI 测试 / 自动化探针定位用），替代原分段行标识。
    func test_modeRowAccessibilityIDs_areDistinct() {
        let ids = [
            SettingsAccessibilityID.providerModeDirectRow,
            SettingsAccessibilityID.providerModeAggregationRow,
        ]
        XCTAssertEqual(Set(ids.map(\.rawValue)).count, ids.count)
    }
}
