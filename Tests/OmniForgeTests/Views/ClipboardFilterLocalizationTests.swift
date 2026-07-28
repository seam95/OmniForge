import XCTest
@testable import OmniForge

final class ClipboardFilterLocalizationTests: XCTestCase {
    func test_clipboardFilter_label_inEnglish() {
        let s = Strings.en
        XCTAssertEqual(ClipboardFilter.all.label(in: s), "All Types")
        XCTAssertEqual(ClipboardFilter.text.label(in: s), "Text")
        XCTAssertEqual(ClipboardFilter.image.label(in: s), "Image")
        XCTAssertEqual(ClipboardFilter.file.label(in: s), "File")
        XCTAssertEqual(ClipboardFilter.url.label(in: s), "Link")
        XCTAssertEqual(ClipboardFilter.rtf.label(in: s), "Rich Text")
    }

    func test_clipboardFilter_label_inChinese() {
        let s = Strings.zhHans
        XCTAssertEqual(ClipboardFilter.all.label(in: s), "全部类型")
        XCTAssertEqual(ClipboardFilter.text.label(in: s), "文本")
        XCTAssertEqual(ClipboardFilter.rtf.label(in: s), "富文本")
    }

    func test_clipboardSection_title_inEnglish() {
        let s = Strings.en
        XCTAssertEqual(ClipboardSection.today.title(in: s), "Today")
        XCTAssertEqual(ClipboardSection.yesterday.title(in: s), "Yesterday")
        XCTAssertEqual(ClipboardSection.thisYear.title(in: s), "This Year")
    }

    func test_clipboardSection_title_inChinese() {
        let s = Strings.zhHans
        XCTAssertEqual(ClipboardSection.today.title(in: s), "今天")
        XCTAssertEqual(ClipboardSection.thisYear.title(in: s), "今年")
    }

    func test_clipboardSection_sortOrder() {
        let order = ClipboardSection.sortOrder
        XCTAssertEqual(order.count, 6)
        XCTAssertEqual(order[0], .today)
        XCTAssertEqual(order[5], .thisYear)
    }

    func test_settingsToolbarTab_title_inEnglish() {
        let s = Strings.en
        XCTAssertEqual(SettingsToolbarTab.general.title(in: s), "General")
        XCTAssertEqual(SettingsToolbarTab.clipboard.title(in: s), "Clipboard")
        XCTAssertEqual(SettingsToolbarTab.performance.title(in: s), "Performance")
    }

    func test_settingsToolbarTab_title_inChinese() {
        let s = Strings.zhHans
        XCTAssertEqual(SettingsToolbarTab.general.title(in: s), "通用")
        XCTAssertEqual(SettingsToolbarTab.clipboard.title(in: s), "剪贴板")
        XCTAssertEqual(SettingsToolbarTab.performance.title(in: s), "性能")
    }
}
