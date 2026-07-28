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
}
