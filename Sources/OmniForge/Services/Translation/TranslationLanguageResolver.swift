import Foundation
import NaturalLanguage

/// 语言解析：输入校验、自动方向判定与同语言拦截。
///
/// 纯规则类型，不涉及网络与界面；语言检测通过注入的 `TranslationLanguageDetecting` 完成，
/// 测试可替换为固定结果，避免依赖 NaturalLanguage 的模型行为。
struct TranslationLanguageResolver: TranslationLanguageResolving {
    private let detector: any TranslationLanguageDetecting

    init(detector: any TranslationLanguageDetecting = NaturalLanguageTranslationLanguageDetector()) {
        self.detector = detector
    }

    func resolve(
        text: String,
        source: String?,
        target: TranslationTarget
    ) throws -> ResolvedTranslationLanguages {
        // 1. 输入校验：按 Swift Character（扩展字形簇）限长；仅去首尾空白判断有效性，不改写正文。
        try TranslationTextValidator.validate(text)

        // 2. 源语言：手动指定优先；自动检测不可靠时要求用户显式选择，不猜测源语言。
        let resolvedSource: String
        if let manualSource = Self.normalizedManualSource(source) {
            resolvedSource = manualSource
        } else {
            let detection = detector.detect(text)
            guard let detected = detection.language else {
                throw TranslationError.sourceLanguageUncertain
            }
            resolvedSource = detected
        }

        // 3. 目标语言：自动策略按源语言方向决定；固定目标直接使用。
        let resolvedTarget: String
        switch target {
        case .automatic:
            resolvedTarget = Self.automaticTarget(for: resolvedSource)
        case .language(let code):
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空标识防御为自动策略，避免把空 target 传给引擎。
            resolvedTarget = trimmed.isEmpty
                ? Self.automaticTarget(for: resolvedSource)
                : trimmed
        }

        // 4. 同语言拦截：地区变体视为同一语言，中文简繁按书写系统区分。
        //    关联值取源语言标识，便于界面提示具体是哪种语言与目标冲突。
        guard !TranslationLanguage.isSameLanguage(resolvedSource, resolvedTarget) else {
            throw TranslationError.sameLanguage(resolvedSource)
        }

        return ResolvedTranslationLanguages(source: resolvedSource, target: resolvedTarget)
    }

    /// 自动目标语言：与 `TranslationLanguage.automaticTarget(for:)` 单点同源。
    private static func automaticTarget(for source: String) -> String {
        TranslationLanguage.automaticTarget(for: source)
    }

    /// 手动源语言规范化：去首尾空白；空白视为未指定，回退到自动检测。
    private static func normalizedManualSource(_ source: String?) -> String? {
        guard let source else { return nil }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 生产语言检测器：使用 NaturalLanguage 识别主语言，并针对代码标识符与英文短词做归一化增强。
///
/// 识别策略：
/// 1. 不含任何字母字符（空白、纯数字、标点、符号）直接返回 `.uncertain`；
/// 2. 先对 `camelCase` / `snake_case` 等代码标识符做空格分词归一化，避免复合标识符被误判为小语种；
/// 3. 在常用受支持语种约束下取前候选：最高置信度 ≥ 0.6 且领先次候选 ≥ 0.15 时采信；
///    中文简繁因共用汉字分流置信度但合计 ≥ 0.80 时，采信排名更高的中文变体；
/// 4. 纯基础 ASCII 字母构成的短词/词组（未命中高置信度法/德/西语）兜底为英语 `en`；
/// 5. 含非 ASCII 字符的其他脚本保留高置信度（≥ 0.75 且领先 ≥ 0.20）无约束识别。
struct NaturalLanguageTranslationLanguageDetector: TranslationLanguageDetecting {
    /// 最高候选可被采信的最小置信度。
    static let minimumConfidence = 0.6
    /// 最高候选相对次候选的最小领先幅度。
    static let minimumLead = 0.15

    private static let constrainedLanguages: [NLLanguage] = [
        .simplifiedChinese,
        .traditionalChinese,
        .english,
        .japanese,
        .korean,
        .french,
        .german,
        .spanish,
        .russian,
    ]

    func detect(_ text: String) -> TranslationLanguageDetection {
        let letters = text.filter(\.isLetter)
        guard !letters.isEmpty else {
            return .uncertain
        }

        let probeText = TranslationIdentifierSplitter.normalizedForLanguageDetection(text)
        let isPureASCIILetters = letters.allSatisfy(\.isASCII)

        let constrained = NLLanguageRecognizer()
        constrained.languageConstraints = Self.constrainedLanguages
        constrained.processString(probeText)
        let constrainedHypotheses = constrained.languageHypotheses(withMaximum: 3)
        let ranked = constrainedHypotheses.sorted { $0.value > $1.value }

        if let best = ranked.first {
            if best.value >= Self.minimumConfidence,
               ranked.count == 1 || best.value - ranked[1].value >= Self.minimumLead {
                return TranslationLanguageDetection(language: best.key.rawValue, confidence: best.value)
            }

            // 简繁同形短词（如「窗口」「模型」）常把概率均分给 zh-Hans 与 zh-Hant，合计高置信度即可采信首位。
            if ranked.count >= 2,
               TranslationLanguage.primaryLanguage(of: best.key.rawValue) == "zh",
               TranslationLanguage.primaryLanguage(of: ranked[1].key.rawValue) == "zh",
               best.value + ranked[1].value >= 0.80 {
                return TranslationLanguageDetection(
                    language: best.key.rawValue,
                    confidence: min(1.0, best.value + ranked[1].value)
                )
            }
        }

        // 纯 ASCII 字母短词（如 apple、ctx、http server error）在未命中高置信度法/德/西语时归入英语。
        if isPureASCIILetters {
            let englishConfidence = constrainedHypotheses[.english] ?? Self.minimumConfidence
            return TranslationLanguageDetection(
                language: TranslationLanguage.english,
                confidence: max(englishConfidence, Self.minimumConfidence)
            )
        }

        // 非 ASCII 的其他语种脚本（如阿拉伯语、泰语、带变音符的拉丁语）保留高置信度无约束识别。
        let unconstrained = NLLanguageRecognizer()
        unconstrained.processString(probeText)
        let fallbackRanked = unconstrained
            .languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }
        if let best = fallbackRanked.first,
           best.value >= 0.75,
           fallbackRanked.count == 1 || best.value - fallbackRanked[1].value >= 0.20 {
            return TranslationLanguageDetection(language: best.key.rawValue, confidence: best.value)
        }

        return .uncertain
    }
}
