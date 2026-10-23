import XCTest
@testable import OmniForge

final class StringsTranslationTests: XCTestCase {
    func test_english_allPropertiesNonEmpty() {
        let s = Strings.en
        let mirror = Mirror(reflecting: s)
        for child in mirror.children {
            guard let label = child.label, let value = child.value as? String else { continue }
            XCTAssertFalse(value.isEmpty, "英文翻译为空: \(label)")
        }
    }

    func test_chinese_allPropertiesNonEmpty() {
        let s = Strings.zhHans
        let mirror = Mirror(reflecting: s)
        for child in mirror.children {
            guard let label = child.label, let value = child.value as? String else { continue }
            XCTAssertFalse(value.isEmpty, "中文翻译为空: \(label)")
        }
    }

    func test_bothLanguagesHaveSamePropertyCount() {
        let enMirror = Mirror(reflecting: Strings.en)
        let zhMirror = Mirror(reflecting: Strings.zhHans)
        XCTAssertEqual(enMirror.children.count, zhMirror.children.count)
    }

    func test_english_knownValues() {
        let s = Strings.en
        XCTAssertEqual(s.appTitle, "OmniForge")
        XCTAssertEqual(s.actionUnlock, "Unlock")
        XCTAssertEqual(s.clipboardTitle, "Clipboard History")
    }

    func test_chinese_knownValues() {
        let s = Strings.zhHans
        XCTAssertEqual(s.actionUnlock, "解锁")
        XCTAssertEqual(s.actionLock, "锁定")
        XCTAssertEqual(s.clipboardTitle, "剪贴板历史")
    }

    /// 中英文均不得再暴露快速操作属性；工作台冻屏失败文案仍在。
    func test_translations_excludeRetiredResultPanel_andRetainCaptureAnnotationFreeze() {
        let bannedFragments = [
            "Quick" + "Access",
            "quick" + "Access",
            "screenshot" + "Quick" + "Access",
        ]
        for source in [Strings.en, Strings.zhHans] {
            for child in Mirror(reflecting: source).children {
                guard let label = child.label else { continue }
                for fragment in bannedFragments {
                    XCTAssertFalse(label.contains(fragment), "残留本地化属性: \(label)")
                }
            }
            XCTAssertFalse(source.captureAnnotationErrorFreeze.isEmpty)
        }
    }

    /// 聚合模式字符串键在英文侧必须全部声明（中文侧由数量一致性测试兜底）。
    func test_bothLanguagesDeclareTheSameAggregationStrings() {
        let names = Set(Mirror(reflecting: Strings.en).children.compactMap { $0.label })
        for key in ["providerModeDirect", "providerModeAggregation", "providerAggregationStatusLead",
                    "providerAggregationStatusValueFormat", "providerAggregationEnter", "providerAggregationExit",
                    "providerAggregationConfirmStack", "providerAggregationConfirmDirect",
                    "providerAggregationNoteDefault", "providerAggregationNoteMembersFormat", "providerAggregationNoteEmpty",
                    "providerAggregationNoteNoFailover", "providerAggregationNoteRestartCodex",
                    "providerAggregationOfficialNote", "providerAggregationOfficialReason",
                    "providerAggregationSectionDefault", "providerAggregationSectionAddedFormat",
                    "providerAggregationSectionAvailableFormat", "providerAggregationAdd", "providerAggregationRemove",
                    "providerAggregationSetDefault", "providerAggregationEnteredClaude", "providerAggregationEnteredCodex",
                    "providerAggregationExitedFormat", "providerAggregationUndo", "providerAggregationCacheHint",
                    "providerAggregationProxyDown", "providerAggregationStartService", "providerAggregationAttachFailed",
                    "providerAggregationDirectLockedReason",
                    "providerAggregationStaleDaemonTitle", "providerAggregationStaleDaemonBody",
                    "providerAggregationStaleOthersBody", "providerAggregationStaleLoginTitle",
                    "providerAggregationStaleUnverifiedTitle",
                    "providerAggregationRestartDaemon",
                    "providerAggregationRestartDaemonConfirmTitle", "providerAggregationRestartDaemonConfirmMessage",
                    "providerAggregationDaemonRestarted", "providerAggregationDaemonNotRunning",
                    "providerMissStackOff", "providerMissUnknown", "providerMissRemoved", "providerMissDeleted"] {
            XCTAssertTrue(names.contains(key), "missing \(key)")
        }
    }

    /// 聚合成员模型编辑（Claude stackModels 行 / Codex 显示名行）字符串键在英文侧必须全部声明
    /// （中文侧由数量一致性测试兜底）。
    func test_bothLanguagesDeclareTheSameStackModelStrings() {
        let names = Set(Mirror(reflecting: Strings.en).children.compactMap { $0.label })
        for key in ["providerStackModelsSectionTitle", "providerStackModelsAdd", "providerStackModelsDelete",
                    "providerStackModelsDisplayNamePlaceholder", "providerStackModelsModelPlaceholder",
                    "providerStackModelsOneM", "providerStackModelsEmptyHint",
                    "providerCodexModelDisplayNamePlaceholder"] {
            XCTAssertTrue(names.contains(key), "missing \(key)")
        }
    }

    /// 聚合/直连模式切换已改为无确认框直切（开关与面板按钮点击即执行，结果由 toast 反馈）：
    /// 确认框标题键必须已移除，防止回退到弹窗确认流程。
    func test_translations_excludeRetiredAggregationConfirmTitle() {
        let names = Set(Mirror(reflecting: Strings.en).children.compactMap { $0.label })
        XCTAssertFalse(names.contains("providerAggregationConfirmTitle"), "残留本地化属性: providerAggregationConfirmTitle")
    }

    func test_accessibilityIDs_areDistinct() {
        let ids: [SettingsAccessibilityID] = [.providerModeDirectRow, .providerModeAggregationRow,
                                              .providerAggregationEnter,
                                              .providerAggregationExit, .providerAggregationRestartDaemon]
        XCTAssertEqual(Set(ids.map(\.rawValue)).count, ids.count)
    }
}
