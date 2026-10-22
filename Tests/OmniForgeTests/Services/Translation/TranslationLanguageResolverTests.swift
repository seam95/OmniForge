import XCTest
@testable import OmniForge

/// 语言解析定向测试：输入校验、自动方向、检测不确定、同语言拦截与手动源语言绕过检测。
final class TranslationLanguageResolverTests: XCTestCase {
    /// 可注入的假检测器：返回固定检测结果并记录调用，避免依赖 NaturalLanguage 的模型行为。
    private final class StubDetector: TranslationLanguageDetecting {
        var detection: TranslationLanguageDetection
        private(set) var detectedTexts: [String] = []

        init(detection: TranslationLanguageDetection) {
            self.detection = detection
        }

        func detect(_ text: String) -> TranslationLanguageDetection {
            detectedTexts.append(text)
            return detection
        }
    }

    private func makeResolver(
        detection: TranslationLanguageDetection
    ) -> (resolver: TranslationLanguageResolver, detector: StubDetector) {
        let detector = StubDetector(detection: detection)
        return (TranslationLanguageResolver(detector: detector), detector)
    }

    // MARK: - 自动方向

    func test_automaticDirection_mapsChineseToEnglishAndEnglishToSimplifiedChinese() throws {
        let (chineseResolver, _) = makeResolver(
            detection: TranslationLanguageDetection(language: "zh-Hans", confidence: 0.99)
        )
        XCTAssertEqual(
            try chineseResolver.resolve(text: "你好", source: nil, target: .automatic),
            ResolvedTranslationLanguages(source: "zh-Hans", target: "en")
        )

        let (englishResolver, _) = makeResolver(
            detection: TranslationLanguageDetection(language: "en", confidence: 0.99)
        )
        XCTAssertEqual(
            try englishResolver.resolve(text: "hello", source: nil, target: .automatic),
            ResolvedTranslationLanguages(source: "en", target: "zh-Hans")
        )

        // 繁体中文同样按中文方向译为英语；其他语言统一译为简体中文。
        let (traditionalResolver, _) = makeResolver(
            detection: TranslationLanguageDetection(language: "zh-Hant", confidence: 0.99)
        )
        XCTAssertEqual(
            try traditionalResolver.resolve(text: "你好", source: nil, target: .automatic),
            ResolvedTranslationLanguages(source: "zh-Hant", target: "en")
        )
        let (japaneseResolver, _) = makeResolver(
            detection: TranslationLanguageDetection(language: "ja", confidence: 0.99)
        )
        XCTAssertEqual(
            try japaneseResolver.resolve(text: "こんにちは", source: nil, target: .automatic),
            ResolvedTranslationLanguages(source: "ja", target: "zh-Hans")
        )

        // 手动源语言也遵循同一自动方向。
        let resolved = try chineseResolver.resolve(text: "你好", source: "zh-Hans", target: .automatic)
        XCTAssertEqual(resolved.source, "zh-Hans")
        XCTAssertEqual(resolved.target, "en")
    }

    func test_fixedTarget_isUsedVerbatimAndBlankSourceFallsBackToDetection() throws {
        let (resolver, detector) = makeResolver(
            detection: TranslationLanguageDetection(language: "ja", confidence: 0.99)
        )

        // 固定目标直接使用，不按自动方向改写。
        let fixed = try resolver.resolve(text: "hola", source: "es", target: .language("fr"))
        XCTAssertEqual(fixed, ResolvedTranslationLanguages(source: "es", target: "fr"))
        XCTAssertTrue(detector.detectedTexts.isEmpty)

        // 手工传入空白源语言属于防御场景：视为未指定并回到自动检测。
        let automatic = try resolver.resolve(text: "hola", source: "   ", target: .language("fr"))
        XCTAssertEqual(automatic, ResolvedTranslationLanguages(source: "ja", target: "fr"))
        XCTAssertEqual(detector.detectedTexts, ["hola"])
    }

    // MARK: - 输入校验

    func test_validation_countsExtendedGraphemeClusters() throws {
        // 家庭 emoji 是单个扩展字形簇；用它验证限长按 Character 而不是 UTF-16/Unicode 标量计数。
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1, "家庭 emoji 必须是单个 Swift Character")

        let (resolver, detector) = makeResolver(
            detection: TranslationLanguageDetection(language: "ja", confidence: 0.99)
        )

        // 恰好 10,000 个扩展字形簇可提交；手动源语言避免多余检测。
        let atLimit = String(repeating: family, count: 10_000)
        XCTAssertEqual(atLimit.count, 10_000)
        _ = try resolver.resolve(text: atLimit, source: "en", target: .automatic)
        XCTAssertTrue(detector.detectedTexts.isEmpty)

        // 10,001 个超限：抛出精确上限，供界面提示。
        let overLimit = String(repeating: family, count: 10_001)
        do {
            _ = try resolver.resolve(text: overLimit, source: "en", target: .automatic)
            XCTFail("超过 10,000 个字符应被拒绝")
        } catch {
            XCTAssertEqual(error as? TranslationError, .textTooLong(limit: 10_000))
        }

        // 纯空白（含换行与制表符）拒绝；不静默裁剪后提交。
        for whitespace in ["", "   ", "\n\t \r"] {
            do {
                _ = try resolver.resolve(text: whitespace, source: nil, target: .automatic)
                XCTFail("空白输入 \(whitespace.debugDescription) 应被拒绝")
            } catch {
                XCTAssertEqual(error as? TranslationError, .emptyInput)
            }
        }
    }

    // MARK: - 检测不可靠

    func test_uncertainDetection_requiresExplicitSource() throws {
        let (resolver, detector) = makeResolver(detection: .uncertain)

        do {
            _ = try resolver.resolve(text: "hello", source: nil, target: .automatic)
            XCTFail("检测不可靠且未手动指定源语言时应拒绝")
        } catch {
            XCTAssertEqual(error as? TranslationError, .sourceLanguageUncertain)
        }
        XCTAssertEqual(detector.detectedTexts, ["hello"])

        // 手动指定源语言后可以继续，且不再依赖检测结果。
        let resolved = try resolver.resolve(text: "hello", source: "en", target: .automatic)
        XCTAssertEqual(resolved, ResolvedTranslationLanguages(source: "en", target: "zh-Hans"))
        XCTAssertEqual(detector.detectedTexts, ["hello"], "手动源语言不应再次触发检测")
    }

    // MARK: - 同语言与手动源语言

    func test_samePrimaryLanguage_isRejected() throws {
        let (resolver, _) = makeResolver(
            detection: TranslationLanguageDetection(language: "en", confidence: 0.99)
        )

        // 同主语言的地区变体视为同一种语言，提示更换目标。
        do {
            _ = try resolver.resolve(text: "hello", source: "en-US", target: .language("en-GB"))
            XCTFail("en-US → en-GB 应判定为同语言")
        } catch {
            XCTAssertEqual(error as? TranslationError, .sameLanguage("en-US"))
        }

        // 中文简繁书写系统不同，不能被误判为同一种语言。
        let resolved = try resolver.resolve(
            text: "你好",
            source: "zh-Hans",
            target: .language("zh-Hant")
        )
        XCTAssertEqual(resolved, ResolvedTranslationLanguages(source: "zh-Hans", target: "zh-Hant"))
    }

    func test_manualSourceBypassesDetection() throws {
        let (resolver, detector) = makeResolver(
            detection: TranslationLanguageDetection(language: "en", confidence: 0.99)
        )

        let resolved = try resolver.resolve(text: "こんにちは", source: "ja", target: .automatic)
        XCTAssertEqual(resolved, ResolvedTranslationLanguages(source: "ja", target: "zh-Hans"))
        XCTAssertTrue(detector.detectedTexts.isEmpty, "手动源语言不应调用语言检测")

        // 未指定时检测器参与解析。
        _ = try resolver.resolve(text: "hello", source: nil, target: .automatic)
        XCTAssertEqual(detector.detectedTexts, ["hello"])
    }

    // MARK: - 生产检测器

    func test_naturalLanguageDetector_returnsUncertainForUninformativeText() {
        // 空文本没有可识别语言：必须返回不确定，而不是猜一个语言。
        XCTAssertEqual(NaturalLanguageTranslationLanguageDetector().detect(""), .uncertain)
    }
}
