import Combine
import Foundation
import Translation

// MARK: - 语言可用性

/// 系统语言对可用状态。与 `LanguageAvailability.Status` 对应，便于测试注入固定结果。
@available(macOS 15.0, *)
enum AppleTranslationLanguagePairStatus: Equatable, Sendable {
    /// 语言模型已安装，可直接设备端翻译。
    case installed
    /// 语言对受支持但模型未安装，首次翻译由系统引导下载。
    case supported
    /// 语言对不受支持，不能进入准备与下载流程。
    case unsupported
}

/// 语言可用性查询边界：生产实现使用系统 `LanguageAvailability`，测试注入固定结果。
@available(macOS 15.0, *)
protocol AppleTranslationAvailabilityProviding: Sendable {
    /// 查询语言对状态。系统未下载但受支持时返回 `.supported`，由系统准备流程负责下载。
    func status(sourceLanguage: String, targetLanguage: String) async -> AppleTranslationLanguagePairStatus

    /// 系统支持的语言标识（BCP 47）。
    func supportedLanguageCodes() async -> [String]
}

/// 使用 macOS 15 `LanguageAvailability` 的生产实现。
@available(macOS 15.0, *)
struct SystemTranslationAvailabilityProvider: AppleTranslationAvailabilityProviding {
    func status(sourceLanguage: String, targetLanguage: String) async -> AppleTranslationLanguagePairStatus {
        // 查询本身不触发下载；只有 .supported / .installed 才允许进入系统准备流程。
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: sourceLanguage),
            to: Locale.Language(identifier: targetLanguage)
        )
        switch status {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported
        @unknown default:
            // 未来新增状态按不可用处理，避免把未知状态当作可翻译。
            return .unsupported
        }
    }

    func supportedLanguageCodes() async -> [String] {
        let languages = await LanguageAvailability().supportedLanguages
        return languages.map(\.minimalIdentifier)
    }
}

// MARK: - 系统会话操作

/// 一次系统翻译会话的执行结果。
///
/// 只回交纯值：`TranslationSession` 不能跨隔离边界携带有状态引用。
@available(macOS 15.0, *)
struct AppleTranslationSessionOutcome: Equatable, Sendable {
    /// 系统返回的译文。
    let text: String
    /// 系统会话实际使用的源语言（BCP 47）；nil 表示沿用请求中的源语言。
    let sourceLanguage: String?
    /// 系统会话实际使用的目标语言（BCP 47）；nil 表示沿用请求中的目标语言。
    let targetLanguage: String?
}

/// 会话操作抽象：把「准备语言模型 + 翻译」从真实 `TranslationSession` 中抽出。
///
/// 生产环境由 `SystemTranslationSessionDriver` 包装 SwiftUI `.translationTask` 提供的会话；
/// 测试注入假实现，不依赖真实系统会话与模型下载。
@available(macOS 15.0, *)
protocol AppleTranslationSessionDriving: Sendable {
    /// 会话创建时的源语言标识；nil 表示未知（测试假实现或系统未提供）。
    var sourceLanguage: String? { get }
    /// 会话创建时的目标语言标识；nil 表示未知。
    var targetLanguage: String? { get }

    /// 触发系统语言准备；用户拒绝下载或系统内部失败时抛错。
    func prepareTranslation() async throws

    /// 执行一次翻译并回交纯值结果。
    func translate(_ text: String) async throws -> AppleTranslationSessionOutcome
}

/// 包装真实 `TranslationSession` 的驱动实现。
@available(macOS 15.0, *)
final class SystemTranslationSessionDriver: AppleTranslationSessionDriving, @unchecked Sendable {
    private let session: TranslationSession

    init(session: TranslationSession) {
        self.session = session
    }

    /// 会话语言对：宿主用它校验会话是否仍对应当前请求，防止迟到的旧会话领取新请求。
    var sourceLanguage: String? { session.sourceLanguage?.minimalIdentifier }
    var targetLanguage: String? { session.targetLanguage?.minimalIdentifier }

    func prepareTranslation() async throws {
        try await session.prepareTranslation()
    }

    func translate(_ text: String) async throws -> AppleTranslationSessionOutcome {
        let response = try await session.translate(text)
        // 系统返回的 Language.minimalIdentifier 会丢弃书写系统（zh-Hans 归一为 zh），
        // 结果语言统一由 bridge 从请求回填，避免历史记录出现残缺语言标识。
        return AppleTranslationSessionOutcome(
            text: response.targetText,
            sourceLanguage: nil,
            targetLanguage: nil
        )
    }
}

// MARK: - 桥接

/// macOS 15+ 系统翻译桥接。
///
/// 设计约束：macOS 15 不提供可直接构造的 `TranslationSession`（仅 macOS 26 的
/// `init(installedSource:target:)` 例外），系统会话只能由视图上的 `.translationTask`
/// 在任务闭包内提供。因此本类承担三件事：
/// 1. 发布待执行请求与 `TranslationSession.Configuration`，由 `AppleTranslationTaskHost`
///    取得会话后执行，结果回交统一完成入口；
/// 2. 统一管理 continuation 与请求令牌，保证恰好恢复一次、迟到响应丢弃；
/// 3. 查询语言可用性并映射系统错误。
@available(macOS 15.0, *)
@MainActor
final class AppleTranslationBridge: ObservableObject, TranslationEngine {
    /// 当前待执行任务配置；nil 表示没有待执行系统翻译任务。宿主的 `.translationTask` 观察它。
    @Published private(set) var configuration: TranslationSession.Configuration?

    /// 系统翻译任务宿主是否已挂载。任务 4 在发起请求前据此确认会话来源存在。
    @Published private(set) var isTaskHostAttached = false

    /// 待执行请求；宿主 task action 读取后调用 `runSession(_:)`。
    private(set) var pendingRequest: TranslationRequest?

    private let availability: any AppleTranslationAvailabilityProviding

    /// 等待中的调用。所有 continuation 只从这里取出，取出后置空即保证单次恢复。
    private var pendingCall: PendingCall?

    /// 最近一次发布的配置：同语言对重试时用于显式失效。
    private var lastIssuedConfiguration: TranslationSession.Configuration?

    /// 一次等待中的系统翻译调用。
    private struct PendingCall {
        let token: UUID
        let request: TranslationRequest
        var continuation: CheckedContinuation<TranslationResult, Error>?
    }

    init(availability: any AppleTranslationAvailabilityProviding = SystemTranslationAvailabilityProvider()) {
        self.availability = availability
    }

    // MARK: TranslationEngine

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        // 新请求到达即失效旧令牌：旧等待者以取消结束，旧响应之后按令牌丢弃。
        cancelPending()

        // 令牌在挂起前创建，供调用方 Task 取消时精确匹配，避免误取消后续新请求。
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startPendingCall(token: token, for: request, continuation: continuation)
            }
        } onCancel: {
            // 调用方 Task 被取消时也要结束等待，不能留下挂起的 continuation。
            Task { @MainActor [weak self] in
                self?.cancelPending(token: token)
            }
        }
    }

    func cancel() {
        cancelPending()
    }

    // MARK: 宿主接口

    /// 宿主视图出现。
    func hostDidAppear() {
        isTaskHostAttached = true
    }

    /// 宿主视图移除：系统会话随之失效，必须结束等待，不能让调用方永久挂起。
    func hostDidDisappear() {
        isTaskHostAttached = false
        // 窗口收起后 SwiftUI 树不保证销毁，宿主移除本身就是会话失效信号。
        cancelPending()
    }

    /// 宿主取得系统会话后执行的统一入口；测试用假驱动直接调用同一入口。
    ///
    /// 调用时若无待执行请求（迟到或重复触发的任务），直接返回。
    func runSession(_ driver: any AppleTranslationSessionDriving) async {
        // 配置变化后 SwiftUI 会取消旧任务并重建；旧闭包仍可能被调度。
        // 已取消的宿主任务不得领取新请求（否则新正文会被旧会话处理）。
        guard !Task.isCancelled else { return }
        guard let call = pendingCall else { return }
        // 会话语言对必须与当前请求一致：迟到的旧会话不能跨语言对翻译新正文。
        guard Self.session(driver, matches: call.request) else { return }
        let token = call.token
        let request = call.request

        // 语言对门控：系统不支持时直接失败，不进入准备与下载流程。
        let status = await availability.status(
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage
        )
        guard isCurrent(token) else { return }
        guard status != .unsupported else {
            finish(
                token: token,
                with: .failure(
                    TranslationError.unsupportedLanguagePair(
                        source: request.sourceLanguage,
                        target: request.targetLanguage
                    )
                )
            )
            return
        }

        do {
            try await driver.prepareTranslation()
            // 宿主任务被 SwiftUI 取消（窗口隐藏等）时结束等待，不继续翻译。
            try Task.checkCancellation()
            let outcome = try await driver.translate(request.textForTranslation)
            try Task.checkCancellation()
            guard isCurrent(token) else { return }
            let result = TranslationResult(
                text: outcome.text,
                sourceLanguage: outcome.sourceLanguage ?? request.sourceLanguage,
                targetLanguage: outcome.targetLanguage ?? request.targetLanguage,
                engine: .system
            )
            finish(token: token, with: .success(result))
        } catch is CancellationError {
            guard isCurrent(token) else { return }
            if Task.isCancelled {
                // 宿主任务被系统取消：保持取消语义。
                finish(token: token, with: .failure(CancellationError()))
            } else {
                // 令牌仍有效且调用方未取消，说明是系统准备流程被取消（如下载确认被关闭）：
                // 按「模型未准备」反馈，原文保留可重试。
                finish(token: token, with: .failure(TranslationError.modelNotPrepared))
            }
        } catch {
            guard isCurrent(token) else { return }
            finish(token: token, with: .failure(Self.mapSessionError(error, request: request)))
        }
    }

    // MARK: 内部

    private func startPendingCall(
        token: UUID,
        for request: TranslationRequest,
        continuation: CheckedContinuation<TranslationResult, Error>
    ) {
        pendingCall = PendingCall(token: token, request: request, continuation: continuation)
        pendingRequest = request
        publishConfiguration(for: request)
    }

    /// 发布新配置。
    ///
    /// 同语言对的 Configuration 相等时 SwiftUI 不会重新执行 translationTask，因此：
    /// 先置空再赋值让宿主观察到任务结束与重新开始；对相同语言对显式 `invalidate()`
    /// 让版本变化，确保能重新取得系统会话并再次触发准备流程。
    private func publishConfiguration(for request: TranslationRequest) {
        var next = TranslationSession.Configuration(
            source: Locale.Language(identifier: request.sourceLanguage),
            target: Locale.Language(identifier: request.targetLanguage)
        )
        if let lastIssuedConfiguration, lastIssuedConfiguration == next {
            next.invalidate()
        }
        configuration = nil
        configuration = next
        lastIssuedConfiguration = next
    }

    /// 统一完成入口：取出并置空 continuation，保证恰好恢复一次。
    ///
    /// 令牌失效（新请求已接管，或调用已被取消）时丢弃迟到响应，不恢复任何等待者。
    private func finish(token: UUID, with result: Result<TranslationResult, Error>) {
        guard let call = pendingCall, call.token == token else { return }
        pendingCall = nil
        pendingRequest = nil
        configuration = nil
        call.continuation?.resume(with: result)
    }

    /// 结束当前等待：以取消语义恢复唯一等待者，并清空发布状态。
    ///
    /// - Parameter token: 传入时只在令牌仍匹配时取消，避免迟到的取消失效新请求。
    private func cancelPending(token: UUID? = nil) {
        if let token, pendingCall?.token != token {
            return
        }
        let call = pendingCall
        pendingCall = nil
        pendingRequest = nil
        configuration = nil
        call?.continuation?.resume(throwing: CancellationError())
    }

    private func isCurrent(_ token: UUID) -> Bool {
        pendingCall?.token == token
    }

    /// 宿主会话的语言对是否仍对应当前请求。
    ///
    /// 按主语言比较：系统 `minimalIdentifier` 会丢弃书写系统（zh-Hans → zh），
    /// 因此简繁差异在此放宽为匹配；不同主语言则明确拒绝，交由正确会话处理。
    private static func session(
        _ driver: any AppleTranslationSessionDriving,
        matches request: TranslationRequest
    ) -> Bool {
        if let source = driver.sourceLanguage,
           TranslationLanguage.primaryLanguage(of: source)
            != TranslationLanguage.primaryLanguage(of: request.sourceLanguage) {
            return false
        }
        if let target = driver.targetLanguage,
           TranslationLanguage.primaryLanguage(of: target)
            != TranslationLanguage.primaryLanguage(of: request.targetLanguage) {
            return false
        }
        return true
    }

    /// 系统错误映射。
    ///
    /// - 语言对/语言识别类错误：转换为 `unsupportedLanguagePair`，界面可提示更换语言。
    /// - 其余（下载被拒、模型缺失、系统内部失败）：统一为可重试的 `modelNotPrepared`，
    ///   原文保留，用户可再次提交触发系统准备流程。
    private static func mapSessionError(_ error: Error, request: TranslationRequest) -> Error {
        if Translation.TranslationError.unsupportedLanguagePairing ~= error
            || Translation.TranslationError.unsupportedSourceLanguage ~= error
            || Translation.TranslationError.unsupportedTargetLanguage ~= error
            || Translation.TranslationError.unableToIdentifyLanguage ~= error {
            return TranslationError.unsupportedLanguagePair(
                source: request.sourceLanguage,
                target: request.targetLanguage
            )
        }
        return TranslationError.modelNotPrepared
    }
}
