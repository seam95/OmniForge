import Foundation

/// 翻译引擎标识。rawValue 为持久化值，不得重命名。
enum TranslationEngineID: String, Codable, Equatable, CaseIterable {
    /// macOS 15+ 的设备端系统翻译（Apple Translation）。
    case system
    /// OpenAI 兼容 Chat Completions 接口。
    case ai
}

/// 目标语言策略。
///
/// `automatic` 表示跟随原文语言：中文译英语，其他已识别语言译简体中文。
/// 固定语言使用 BCP 47 标识（如 `zh-Hans`、`en`）。
enum TranslationTarget: Equatable, Codable {
    case automatic
    case language(String)

    /// 偏好持久化字符串：`automatic` 或 BCP 47。
    var storageValue: String {
        switch self {
        case .automatic: return Self.automaticStorageValue
        case .language(let code): return code
        }
    }

    static let automaticStorageValue = "automatic"

    init(storageValue: String) {
        let trimmed = storageValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.automaticStorageValue {
            self = .automatic
        } else {
            self = .language(trimmed)
        }
    }

    // 单值编码：存储和网络都不需要保留枚举分支对象结构。
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(storageValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

// MARK: - 请求与结果

/// 一次已解析的翻译请求：进入引擎前源/目标语言都已确定为具体 BCP 47 标识。
struct TranslationRequest: Equatable, Codable {
    let id: UUID
    let text: String
    let sourceLanguage: String
    let targetLanguage: String

    init(id: UUID = UUID(), text: String, sourceLanguage: String, targetLanguage: String) {
        self.id = id
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

/// 引擎成功的翻译结果。
struct TranslationResult: Equatable, Codable {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
    let engine: TranslationEngineID
    /// 仅 AI 引擎记录模型名；系统引擎为 nil。
    let model: String?

    init(
        text: String,
        sourceLanguage: String,
        targetLanguage: String,
        engine: TranslationEngineID,
        model: String? = nil
    ) {
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.engine = engine
        self.model = model
    }
}

/// 一条成功翻译历史。成功记录的 `id` 与请求 `id` 相同，同一次请求只保存一次。
struct TranslationHistoryEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let request: TranslationRequest
    let result: TranslationResult
    let completedAt: Date

    init(id: UUID, request: TranslationRequest, result: TranslationResult, completedAt: Date) {
        self.id = id
        self.request = request
        self.result = result
        self.completedAt = completedAt
    }

    /// 成功记录直接沿用请求 id，便于"同一次请求只保存一次"的幂等判断。
    init(request: TranslationRequest, result: TranslationResult, completedAt: Date = Date()) {
        self.init(id: request.id, request: request, result: result, completedAt: completedAt)
    }
}

// MARK: - 错误

/// 翻译失败类别。取消使用 `CancellationError`，不在此枚举内，避免把取消显示成网络错误。
enum TranslationError: Error, Equatable {
    case emptyInput
    case textTooLong(limit: Int)
    /// 自动检测不可靠，必须手动指定源语言。
    case sourceLanguageUncertain
    /// 源与目标为同一语言。
    case sameLanguage(String)
    /// 当前系统版本不支持系统翻译（macOS 14）。
    case systemTranslationUnavailable
    /// 系统翻译不支持该语言对。
    case unsupportedLanguagePair(source: String, target: String)
    /// 系统语言模型未准备完成（用户拒绝下载等）。
    case modelNotPrepared
    /// AI 接口地址或模型为空，未完成配置。
    case configurationIncomplete
    /// 读取 Keychain 失败（区别于"没有配置 Key"）。
    case credentialReadFailed
    case network
    case timedOut
    case unauthorized
    case rateLimited
    case serverError(statusCode: Int)
    case invalidResponse
    /// 译文成功但历史落库失败。
    case historyWriteFailed
}

// MARK: - 引擎协议

/// 翻译引擎边界。请求完成后由调用方校验任务有效性，引擎不感知 UI 状态。
@MainActor
protocol TranslationEngine: AnyObject {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
    /// 取消当前进行中的请求；无进行中请求时为幂等空操作。
    func cancel()
}

/// AI 引擎配置。只在内存中构造；API Key 不进入历史、不写日志。
struct AITranslationConfiguration: Equatable {
    let baseURL: String
    let model: String
    let apiKey: String?

    init(baseURL: String, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

// MARK: - 存储协议

/// 历史存储边界。实现负责事务完整性：插入与裁剪在同一事务内完成。
protocol TranslationHistoryStoring: AnyObject {
    func load(limit: Int) async throws -> [TranslationHistoryEntry]
    func insertAndPrune(_ entry: TranslationHistoryEntry, limit: Int) async throws
    func delete(id: UUID) async throws
    func deleteAll() async throws
}

/// 本功能独立 API Key 存取边界。
protocol TranslationAPIKeyStoring: AnyObject {
    /// 条目不存在返回 nil；Keychain 不可读时抛错。
    func readAPIKey() throws -> String?
    func writeAPIKey(_ value: String) throws
    func deleteAPIKey() throws
}

// MARK: - 窗口协议

/// 窗口展示边界：manager 通过它驱动浮窗前/后置，controller 回绑弱引用。
@MainActor
protocol TranslationWindowPresenting: AnyObject {
    var isKeyWindow: Bool { get }
    func show(focusInput: Bool)
    func hide()
}

// MARK: - 语言检测与解析

/// 语言检测结果。`language == nil` 表示检测不可靠（置信度不足或候选接近）。
struct TranslationLanguageDetection: Equatable {
    let language: String?
    let confidence: Double

    init(language: String?, confidence: Double) {
        self.language = language
        self.confidence = confidence
    }

    /// 检测不可靠：调用方应要求用户手动选择源语言。
    static let uncertain = TranslationLanguageDetection(language: nil, confidence: 0)
}

/// 语言检测边界。生产实现使用 NaturalLanguage，测试注入固定结果。
protocol TranslationLanguageDetecting {
    func detect(_ text: String) -> TranslationLanguageDetection
}

/// 解析后的源/目标语言（均为具体 BCP 47 标识）。
struct ResolvedTranslationLanguages: Equatable {
    let source: String
    let target: String
}

/// 语言解析边界：输入校验、自动方向与同语言拦截都在此完成。
protocol TranslationLanguageResolving {
    /// - Parameters:
    ///   - text: 原文。
    ///   - source: 源语言；nil 表示自动检测。
    ///   - target: 目标策略。
    /// - Throws: `TranslationError`。
    func resolve(
        text: String,
        source: String?,
        target: TranslationTarget
    ) throws -> ResolvedTranslationLanguages
}

// MARK: - 语言常量与规范化

/// 翻译语言常量与 BCP 47 规范化工具。
enum TranslationLanguage {
    static let simplifiedChinese = "zh-Hans"
    static let traditionalChinese = "zh-Hant"
    static let english = "en"
    static let japanese = "ja"
    static let korean = "ko"
    static let french = "fr"
    static let german = "de"
    static let spanish = "es"
    static let russian = "ru"

    /// AI 引擎首版支持的目标语言（顺序即界面展示顺序）。
    static let aiTargetLanguageCodes: [String] = [
        simplifiedChinese,
        traditionalChinese,
        english,
        japanese,
        korean,
        french,
        german,
        spanish,
        russian,
    ]

    /// 源语言手动选择项：auto 由界面单独提供，这里只列固定语言。
    static let selectableLanguageCodes: [String] = aiTargetLanguageCodes

    /// 取主语言子标签（`en-US` → `en`，`zh-Hans` → `zh`）。
    static func primaryLanguage(of code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map(String.init)?.lowercased() ?? normalized.lowercased()
    }

    /// 取书写系统子标签（`zh-Hans` → `hans`）；无脚本返回 nil。
    ///
    /// BCP 47 的 script 为 4 位字母子标签；`zh-CN` 这类地区变体没有脚本子标签。
    static func script(of code: String) -> String? {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        for component in normalized.split(separator: "-").dropFirst() {
            let part = String(component)
            guard part.count == 4, part.allSatisfy({ $0.isLetter }) else { continue }
            return part.lowercased()
        }
        return nil
    }

    /// 是否为简体中文（显式 Hans 或未标注脚本的 zh）。
    static func isSimplifiedChinese(_ code: String) -> Bool {
        guard primaryLanguage(of: code) == "zh" else { return false }
        return script(of: code) != "hant"
    }

    /// 是否为繁体中文。
    static func isTraditionalChinese(_ code: String) -> Bool {
        primaryLanguage(of: code) == "zh" && script(of: code) == "hant"
    }

    /// 同语言判定：主语言不同即不同；中文简繁按书写系统区分；其余同主语言视为同一语言。
    ///
    /// 地区变体（`en-US` / `en-GB`）视为同一语言，避免用户被要求翻译同一种语言。
    static func isSameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let leftPrimary = primaryLanguage(of: lhs)
        let rightPrimary = primaryLanguage(of: rhs)
        guard leftPrimary == rightPrimary else { return false }
        if leftPrimary == "zh" {
            return isTraditionalChinese(lhs) == isTraditionalChinese(rhs)
        }
        return true
    }
}

// MARK: - 输入校验

/// 原文输入校验：按 Swift Character（扩展字形簇）计长，不静默截断。
enum TranslationTextValidator {
    static let defaultMaxLength = 10_000

    /// 校验非空且不超过上限。
    ///
    /// 仅去除首尾空白判断有效性，不修改正文格式。
    static func validate(_ text: String, maxLength: Int = defaultMaxLength) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.emptyInput
        }
        guard text.count <= maxLength else {
            throw TranslationError.textTooLong(limit: maxLength)
        }
    }
}
