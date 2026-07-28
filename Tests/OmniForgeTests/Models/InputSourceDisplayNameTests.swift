import XCTest
@testable import OmniForge

final class InputSourceDisplayNameTests: XCTestCase {
    func test_scimPinyin_idMapsToChineseWhenAppIsZhHans() {
        let name = InputSourceDisplayName.resolve(
            id: "com.apple.inputmethod.SCIM.ITABC",
            fallback: "Pinyin - Simplified",
            language: .zhHans
        )
        XCTAssertEqual(name, "简体拼音")
    }

    func test_englishFallbackNameMapsWhenIdUnknown() {
        let name = InputSourceDisplayName.resolve(
            id: "com.example.unknown.pinyin",
            fallback: "Pinyin - Simplified",
            language: .zhHans
        )
        XCTAssertEqual(name, "简体拼音")
    }

    func test_chineseNameMapsToEnglishWhenAppIsEn() {
        let name = InputSourceDisplayName.resolve(
            id: "com.example.unknown",
            fallback: "简体拼音",
            language: .en
        )
        XCTAssertEqual(name, "Pinyin - Simplified")
    }

    func test_unknownSourceKeepsFallback() {
        let name = InputSourceDisplayName.resolve(
            id: "com.tencent.inputmethod.wetype.pinyin",
            fallback: "微信输入法",
            language: .zhHans
        )
        XCTAssertEqual(name, "微信输入法")
    }

    func test_idSuffixMatchForModeVariants() {
        let name = InputSourceDisplayName.resolve(
            id: "com.apple.inputmethod.SCIM.ITABC.variant",
            fallback: "Something",
            language: .zhHans
        )
        XCTAssertEqual(name, "简体拼音")
    }

    func test_localizedHelperPreservesNonNameFields() {
        let source = InputSource(
            id: "com.apple.inputmethod.SCIM.ITABC",
            name: "Pinyin - Simplified",
            isSelectable: true,
            isEnabled: false,
            icon: nil
        )
        let localized = InputSourceDisplayName.localized(source, language: .zhHans)
        XCTAssertEqual(localized.id, source.id)
        XCTAssertEqual(localized.name, "简体拼音")
        XCTAssertEqual(localized.isSelectable, true)
        XCTAssertEqual(localized.isEnabled, false)
    }
}
