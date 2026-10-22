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

/// 生产语言检测器：使用 NaturalLanguage 识别主语言。
///
/// 系统识别在短文本、混合语言或符号较多时置信度不可靠，因此同时要求：
/// 最高候选置信度至少 0.6，且领先次候选至少 0.15；否则返回 `.uncertain`，
/// 由解析层要求用户手动选择源语言，而不是猜测后发出可能错误的请求。
struct NaturalLanguageTranslationLanguageDetector: TranslationLanguageDetecting {
    /// 最高候选可被采信的最小置信度。
    static let minimumConfidence = 0.6
    /// 最高候选相对次候选的最小领先幅度。
    static let minimumLead = 0.15

    func detect(_ text: String) -> TranslationLanguageDetection {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // 只关心前两名，避免为大字典做无意义排序。
        let ranked = recognizer
            .languageHypotheses(withMaximum: 2)
            .sorted { $0.value > $1.value }

        guard let best = ranked.first, best.value >= Self.minimumConfidence else {
            return .uncertain
        }
        // 存在次候选且差距不足：文本不足以可靠区分两种语言。
        if ranked.count > 1, best.value - ranked[1].value < Self.minimumLead {
            return .uncertain
        }
        return TranslationLanguageDetection(language: best.key.rawValue, confidence: best.value)
    }
}
