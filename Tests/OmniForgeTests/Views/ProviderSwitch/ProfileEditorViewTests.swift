import XCTest
import SwiftUI
import AppKit
@testable import OmniForge

final class ProfileEditorViewTests: XCTestCase {
    func test_layout_maxHeightRespectsSmallAndLargeScreens() {
        XCTAssertEqual(ProfileEditorLayout.maxHeight(for: 600), 536)
        XCTAssertEqual(ProfileEditorLayout.maxHeight(for: 900), 720)
        XCTAssertEqual(ProfileEditorLayout.maxHeight(for: 300), 300)
    }

    func test_layout_scrollViewportReservesFixedFooter() {
        let visibleScreenHeight: CGFloat = 600
        let maxHeight = ProfileEditorLayout.maxHeight(for: visibleScreenHeight)
        let scrollHeight = ProfileEditorLayout.scrollViewportHeight(for: visibleScreenHeight)

        XCTAssertEqual(
            maxHeight - scrollHeight,
            ProfileEditorLayout.footerHeight + ProfileEditorLayout.separatorHeight
        )
        XCTAssertLessThan(scrollHeight, maxHeight)
    }

    func test_brandVisual_knownBrands() {
        let glm = ProviderBrandVisual.visual(name: "GLM 智谱", baseURL: "https://open.bigmodel.cn/api/anthropic")
        XCTAssertEqual(glm.letter, "G")
        XCTAssertEqual(glm.logo, ProviderLogoAssets.glm)

        let kimi = ProviderBrandVisual.visual(name: "Kimi 月之暗面", baseURL: "https://api.kimi.com/coding")
        XCTAssertEqual(kimi.letter, "K")
        XCTAssertEqual(kimi.logo, ProviderLogoAssets.kimi)

        let deepseek = ProviderBrandVisual.visual(name: "DeepSeek", baseURL: "https://api.deepseek.com/anthropic")
        XCTAssertEqual(deepseek.letter, "D")
        XCTAssertEqual(deepseek.logo, ProviderLogoAssets.deepseek)

        let minimax = ProviderBrandVisual.visual(name: "MiniMax", baseURL: "https://api.minimaxi.com/anthropic")
        XCTAssertEqual(minimax.letter, "M")
        XCTAssertEqual(minimax.logo, ProviderLogoAssets.miniMax)

        let anthropic = ProviderBrandVisual.visual(name: "My Relay", baseURL: "https://example.com/anthropic")
        XCTAssertEqual(anthropic.logo, ProviderLogoAssets.claude)

        let custom = ProviderBrandVisual.visual(name: "MyCustomProvider", baseURL: "https://example.com")
        XCTAssertEqual(custom.letter, "M")
        XCTAssertNil(custom.logo)
    }

    /// 新入库的 GLM / MiniMax logo path 含相对弧线命令，必须能被 SVGPathParser 完整解析；
    /// 并断言全部锚点落在 viewBox 0 0 24 24 附近（flag 解析错误会导致弧线终点大幅漂移出界）。
    func test_brandVisual_newLogoPathsParseIntoCommands() {
        let assets: [[ProviderLogoLayer]] = [ProviderLogoAssets.glm, ProviderLogoAssets.miniMax]
        for layers in assets {
            for layer in layers {
                var parser = SVGPathParser(data: layer.pathData)
                let commands = parser.parse()
                XCTAssertFalse(commands.isEmpty, "logo path 必须解析出至少一条命令")

                var points: [CGPoint] = []
                for case let SVGPathCommand.cubicTo(c1, c2, end) in commands {
                    points.append(contentsOf: [c1, c2, end])
                }
                for case let SVGPathCommand.lineTo(p) in commands { points.append(p) }
                for case let SVGPathCommand.moveTo(p) in commands { points.append(p) }
                for p in points {
                    XCTAssertTrue(p.x >= -2 && p.x <= 26 && p.y >= -2 && p.y <= 26,
                                  "logo 锚点 (\(p.x), \(p.y)) 超出 viewBox 附近范围，弧线解析可能出错")
                }
            }
        }
    }

    func test_localizationStrings() {
        let zh = Strings.zhHans
        XCTAssertFalse(zh.providerPresetSectionTitle.isEmpty)
        XCTAssertFalse(zh.providerPresetHint.isEmpty)
        XCTAssertFalse(zh.providerBasicInfoSectionTitle.isEmpty)
        XCTAssertFalse(zh.providerModelMappingDefaultHint.isEmpty)
        XCTAssertFalse(zh.providerModelFallbackLabel.isEmpty)
        XCTAssertFalse(zh.providerModelMappingRoleHint.isEmpty)
        XCTAssertFalse(zh.providerModelCustomDisplayNames.isEmpty)

        let en = Strings.en
        XCTAssertFalse(en.providerPresetSectionTitle.isEmpty)
        XCTAssertFalse(en.providerPresetHint.isEmpty)
        XCTAssertFalse(en.providerBasicInfoSectionTitle.isEmpty)
        XCTAssertFalse(en.providerModelMappingDefaultHint.isEmpty)
        XCTAssertFalse(en.providerModelFallbackLabel.isEmpty)
        XCTAssertFalse(en.providerModelMappingRoleHint.isEmpty)
        XCTAssertFalse(en.providerModelCustomDisplayNames.isEmpty)
    }

    @MainActor
    func test_renderSnapshot_claudeCode() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileEditorViewTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let claudeDir = tmp.appendingPathComponent("claude_profiles")
        let codexDir = tmp.appendingPathComponent("codex_profiles")
        let backupDir = tmp.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let claudeConfigURL = tmp.appendingPathComponent("settings.json")
        let codexConfigURL = tmp.appendingPathComponent("config.toml")

        let profileStore = ProviderProfileStore(claudeProfileDirectory: claudeDir, codexProfileDirectory: codexDir)
        let backupStore = ProviderBackupStore(backupDirectory: backupDir)
        let claudeStore = ClaudeSettingsStore(settingsURL: claudeConfigURL)
        let codexStore = CodexConfigStore(configURL: codexConfigURL)

        let manager = ProviderSwitchManager(
            claudeStore: claudeStore,
            codexStore: codexStore,
            backupStore: backupStore,
            profileStore: profileStore,
            claudeConfigURL: claudeConfigURL,
            codexConfigURL: codexConfigURL
        )

        let view = ProfileEditorView(manager: manager, strings: Strings.zhHans, tool: .claudeCode)
            .frame(width: 520)

        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize
        XCTAssertLessThanOrEqual(
            size.height,
            720,
            "新增供应商表单不能按全部内容无限撑高，否则小屏幕下底部操作栏不可见"
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        if let pngData = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            let outURL = URL(fileURLWithPath: "/Users/seam/.gemini/antigravity-cli/brain/76f258aa-b3ae-4f8e-83e0-949d382a5590/scratch/rendered_swiftui.png")
            try? pngData.write(to: outURL)
        }
    }

    @MainActor
    func test_renderSnapshot_withProfile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileEditorViewTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let claudeDir = tmp.appendingPathComponent("claude_profiles")
        let codexDir = tmp.appendingPathComponent("codex_profiles")
        let backupDir = tmp.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let claudeConfigURL = tmp.appendingPathComponent("settings.json")
        let codexConfigURL = tmp.appendingPathComponent("config.toml")

        let profileStore = ProviderProfileStore(claudeProfileDirectory: claudeDir, codexProfileDirectory: codexDir)
        let backupStore = ProviderBackupStore(backupDirectory: backupDir)
        let claudeStore = ClaudeSettingsStore(settingsURL: claudeConfigURL)
        let codexStore = CodexConfigStore(configURL: codexConfigURL)

        let manager = ProviderSwitchManager(
            claudeStore: claudeStore,
            codexStore: codexStore,
            backupStore: backupStore,
            profileStore: profileStore,
            claudeConfigURL: claudeConfigURL,
            codexConfigURL: codexConfigURL
        )

        let existing = ProviderProfile(
            id: "glm",
            name: "GLM 智谱",
            tool: .claudeCode,
            baseURL: "https://open.bigmodel.cn/api/anthropic",
            token: "sk-test-secret-key-123456",
            modelOverride: "glm-5.3",
            modelMapping: ProviderModelMapping(
                sonnet: "glm-5.3",
                sonnetName: "GLM-Sonnet",
                opus: "glm-5.3",
                opusName: "GLM-Opus",
                fable: "glm-5.3",
                fableName: nil,
                haiku: "glm-5.3-flash",
                haikuName: "GLM-Haiku",
                subagent: "glm-5.3"
            ),
            extraEnv: [:],
            managedBy: "omniforge"
        )

        let view = ProfileEditorView(manager: manager, strings: Strings.zhHans, tool: .claudeCode, profile: existing)
            .frame(width: 520)

        let hostingView = NSHostingView(rootView: view)
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        if let pngData = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            let outURL = URL(fileURLWithPath: "/Users/seam/.gemini/antigravity-cli/brain/76f258aa-b3ae-4f8e-83e0-949d382a5590/scratch/rendered_swiftui_edit.png")
            try? pngData.write(to: outURL)
        }
    }
}
