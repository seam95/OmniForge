import AppKit
import SwiftUI

// MARK: - 浮窗主视图

/// 翻译浮窗内容：统一紧凑顶栏（与系统红绿灯同行）→ 对称语言栏 → 原文卡片 → 译文卡片 → 按需状态横幅。
///
/// 视图只读 manager 的会话状态并调用其动作，不直接发请求、不读数据库、不写剪贴板。
/// 原文与译文上下双卡片各自滚动，快捷微操作（粘贴/清空/手动重译/复制）与语言方向内聚在卡片底栏。
@MainActor
struct TranslationWindowView: View {
    @ObservedObject var manager: TranslationManager
    @ObservedObject var preferences: TranslationPreferences
    @ObservedObject var windowState: TranslationWindowState
    let stringsProvider: () -> Strings
    /// macOS 15+ 的系统翻译会话挂载点；由 Lead 注入，视图不直接引用 Apple 桥接类型。
    let translationTaskHost: (() -> AnyView)?
    let onTogglePin: () -> Void
    let onRequestClose: () -> Void
    /// AI 配置 / 引擎降级 / 顶栏快捷入口进入设置页；nil 时隐藏该入口。
    let onOpenSettings: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    /// 原文编辑区是否处于中文输入法组合态；组合期间隐藏占位符。
    @State private var editorHasMarkedText = false
    /// 原文编辑区焦点：聚焦时卡片描边柔和提亮。
    @State private var isEditorFocused = false

    private var strings: Strings { stringsProvider() }
    private var primaryText: Color { MonitorOverviewPalette.primary(colorScheme) }
    private var secondaryText: Color { MonitorOverviewPalette.secondary(colorScheme) }
    private var auxiliaryText: Color { MonitorOverviewPalette.auxiliary(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            languageBar
            cardsArea
            if hasNoticeContent {
                noticeArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(canvasBackground)
        .ignoresSafeArea(.container, edges: .top)
        .omniNoFocusRing()
        .overlay(alignment: .topLeading) { systemTranslationHost }
        // Esc 兜底：原文编辑器的 Esc 已被输入法 / 本视图拦截；焦点在其它控件时
        // 由窗口层的取消动作走到这里（文本编辑器 doCommandBy 优先于本回调）。
        .onExitCommand(perform: onRequestClose)
    }

    private var canvasBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(red: 0xF5 / 255.0, green: 0xF6 / 255.0, blue: 0xF9 / 255.0)
    }

    /// 系统翻译任务宿主：macOS 15 以下不挂载，避免调用不可用 API。
    @ViewBuilder
    private var systemTranslationHost: some View {
        if #available(macOS 15.0, *), let translationTaskHost {
            translationTaskHost()
        }
    }

    // MARK: - 统一顶栏（控件中心线距窗口顶边 18pt，与系统红绿灯严格水平居中同行）

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: TranslationPresentation.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TranslationPresentation.tint)
                .frame(width: 21, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(TranslationPresentation.tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                )

            Text(strings.translationTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryText)
                .lineLimit(1)

            Spacer(minLength: 8)

            PanelSegmentedControl(
                options: [
                    .init(tag: TranslationEngineID.system, title: strings.translationEngineSystem),
                    .init(tag: TranslationEngineID.ai, title: strings.translationEngineAI),
                ],
                selection: engineBinding,
                style: .capsule(isFullWidth: false)
            )
            .layoutPriority(1)

            HStack(spacing: 3) {
                if let onOpenSettings {
                    TranslationTopBarIconButton(
                        systemName: "gearshape",
                        help: strings.translationOpenSettings,
                        action: onOpenSettings
                    )
                }

                TranslationTopBarIconButton(
                    systemName: windowState.isPinned ? "pin.fill" : "pin",
                    isActive: windowState.isPinned,
                    help: windowState.isPinned ? strings.translationUnpin : strings.translationPin,
                    action: onTogglePin
                )
            }
        }
        .frame(height: 28)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .padding(.leading, 78)
        .padding(.trailing, 14)
    }

    // MARK: - 对称语言栏

    private var languageBar: some View {
        HStack(spacing: 6) {
            TranslationPickMenu(
                options: sourceLanguageOptions,
                title: sourceLanguageTitle,
                selection: sourceLanguageBinding,
                help: strings.translationSourceLanguage,
                fillsAvailableWidth: true
            )

            TranslationSwapButton(
                isEnabled: manager.canSwapLanguages,
                help: strings.translationSwapLanguages,
                action: { manager.swapLanguages() }
            )

            TranslationPickMenu(
                options: targetOptions,
                title: targetTitle,
                selection: targetBinding,
                help: strings.translationTargetLanguage,
                fillsAvailableWidth: true
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// 引擎选择绑定「本次运行实际引擎」：macOS 14 上存储 system 会解析为 AI。
    private var engineBinding: Binding<TranslationEngineID> {
        Binding(
            get: { manager.displayedEngine },
            set: { manager.selectEngine($0) }
        )
    }

    private var sourceLanguageBinding: Binding<String?> {
        Binding(
            get: { preferences.sourceLanguage },
            set: { manager.selectSourceLanguage($0) }
        )
    }

    /// 目标语言用持久化字符串做选择值，避免 TranslationTarget 未实现 Hashable。
    private var targetBinding: Binding<String> {
        Binding(
            get: { preferences.target.storageValue },
            set: { manager.selectTarget(TranslationTarget(storageValue: $0)) }
        )
    }

    private var sourceLanguageOptions: [TranslationPickOption<String?>] {
        [TranslationPickOption(value: nil, title: strings.translationLanguageAuto)]
            + TranslationLanguage.selectableLanguageCodes.map { code in
                TranslationPickOption(
                    value: Optional(code),
                    title: TranslationPresentation.languageName(for: code, strings: strings)
                )
            }
    }

    private var targetOptions: [TranslationPickOption<String>] {
        [TranslationPickOption(value: TranslationTarget.automaticStorageValue, title: strings.translationTargetAuto)]
            + TranslationLanguage.aiTargetLanguageCodes.map { code in
                TranslationPickOption(
                    value: code,
                    title: TranslationPresentation.languageName(for: code, strings: strings)
                )
            }
    }

    private var sourceLanguageTitle: String {
        if let code = preferences.sourceLanguage {
            return TranslationPresentation.languageName(for: code, strings: strings)
        }
        if !manager.isResultStale, let result = manager.result {
            let detectedName = TranslationPresentation.languageName(for: result.sourceLanguage, strings: strings)
            return String(format: strings.translationLanguageAutoDetectedFormat, detectedName)
        }
        return strings.translationLanguageAuto
    }

    private var targetTitle: String {
        switch preferences.target {
        case .automatic:
            if !manager.isResultStale, let result = manager.result {
                let targetName = TranslationPresentation.languageName(for: result.targetLanguage, strings: strings)
                return String(format: strings.translationTargetAutoResolvedFormat, targetName)
            }
            return strings.translationTargetAuto
        case .language(let code):
            return TranslationPresentation.languageName(for: code, strings: strings)
        }
    }

    // MARK: - 双卡片主工作区

    private var cardsArea: some View {
        VStack(spacing: 10) {
            sourceCard
            resultCard
        }
        .padding(.horizontal, 14)
        .padding(.bottom, hasNoticeContent ? 8 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 原文卡片

    private var sourceCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TranslationTextEditor(
                    text: sourceTextBinding,
                    focusRequest: windowState.focusInputRequest,
                    onSubmit: { manager.submit() },
                    onEscape: onRequestClose,
                    onMarkedTextChange: { editorHasMarkedText = $0 },
                    onFocusChange: { isEditorFocused = $0 }
                )

                // 组合态期间占位符必须让位：marked text 由输入法绘制在文字层上，
                // 占位符照常渲染会与未确认拼音重叠。
                if manager.sourceText.isEmpty && !editorHasMarkedText {
                    Text(strings.translationSourcePlaceholder)
                        .font(.system(size: 13.5))
                        .foregroundStyle(auxiliaryText.opacity(0.88))
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            sourceCardFooter
        }
        .background(cardSurface(isFocused: isEditorFocused))
        .overlay(cardBorder(isFocused: isEditorFocused))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.0 : (isEditorFocused ? 0.05 : 0.025)),
            radius: isEditorFocused ? 6 : 3,
            x: 0,
            y: 1
        )
        .frame(maxHeight: .infinity)
    }

    private var sourceCardFooter: some View {
        HStack(spacing: 6) {
            if manager.sourceText.isEmpty {
                TranslationCardActionPill(
                    systemImage: "doc.on.clipboard",
                    title: strings.translationPaste,
                    tone: .neutral,
                    action: {
                        manager.pasteFromClipboard()
                        windowState.requestInputFocus()
                    }
                )
            } else {
                characterCountLabel

                if let splitPreview = identifierSplitPreview {
                    Text("·")
                        .font(.system(size: 10.5))
                        .foregroundStyle(auxiliaryText.opacity(0.7))

                    Text(String(format: strings.translationIdentifierSplitFormat, splitPreview))
                        .font(.system(size: 10.5))
                        .foregroundStyle(auxiliaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if !manager.sourceText.isEmpty {
                TranslationCardActionPill(
                    systemImage: "xmark",
                    title: strings.translationClear,
                    tone: .neutral,
                    action: {
                        manager.clearInput()
                        windowState.requestInputFocus()
                    }
                )
            }

            TranslationCardActionPill(
                systemImage: manager.isTranslating ? nil : "arrow.triangle.2.circlepath",
                title: manager.isTranslating ? strings.translationTranslating : strings.translationTranslate,
                shortcutHint: "⌘↩",
                tone: translateActionTone,
                isLoading: manager.isTranslating,
                isDisabled: isTranslateDisabled,
                action: { manager.submit() }
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var characterCountLabel: some View {
        HStack(spacing: 4) {
            if isTextTooLong {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
            }
            Text("\(manager.sourceText.count) / \(TranslationTextValidator.defaultMaxLength)")
                .font(.system(size: 10.5, weight: .regular))
                .monospacedDigit()
        }
        .foregroundStyle(isTextTooLong ? Color.orange : auxiliaryText)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var identifierSplitPreview: String? {
        TranslationIdentifierSplitter.splitIfSingleIdentifier(manager.sourceText)
    }

    private var sourceTextBinding: Binding<String> {
        Binding(
            get: { manager.sourceText },
            set: { manager.updateText($0) }
        )
    }

    private var isTextTooLong: Bool {
        manager.sourceText.count > TranslationTextValidator.defaultMaxLength
    }

    private var isTranslateDisabled: Bool {
        manager.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || manager.isTranslating
    }

    private var translateActionTone: TranslationCardActionPill.Tone {
        if isTranslateDisabled {
            return .neutral
        }
        if manager.result == nil || manager.isResultStale || currentError != nil {
            return .accent
        }
        return .neutral
    }

    // MARK: - 译文卡片

    private var resultCard: some View {
        VStack(spacing: 0) {
            ZStack {
                if manager.result != nil {
                    ScrollView {
                        Text(displayedResultText)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .foregroundStyle(primaryText.opacity(isResultDimmed ? 0.58 : 1.0))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                } else if manager.isTranslating {
                    VStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(strings.translationTranslating)
                            .font(.system(size: 11.5))
                            .foregroundStyle(auxiliaryText)
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 17, weight: .light))
                        Text(strings.translationResultPlaceholder)
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(auxiliaryText.opacity(0.75))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            resultCardFooter
        }
        .background(cardSurface(isFocused: false))
        .overlay(cardBorder(isFocused: false))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.0 : 0.025),
            radius: 3,
            x: 0,
            y: 1
        )
        .frame(maxHeight: .infinity)
    }

    private var resultCardFooter: some View {
        HStack(spacing: 6) {
            resultStatusLeading

            Spacer(minLength: 8)

            TranslationCardActionPill(
                systemImage: manager.didCopyResult ? "checkmark" : "doc.on.doc",
                title: manager.didCopyResult ? strings.translationCopied : strings.translationCopy,
                tone: manager.didCopyResult
                    ? .success
                    : (manager.canCopyResult ? .accent : .neutral),
                isDisabled: !manager.canCopyResult,
                action: { manager.copyResult() }
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var resultStatusLeading: some View {
        if isTextTooLong {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                Text(
                    String(
                        format: strings.translationErrorTextTooLongFormat,
                        TranslationTextValidator.defaultMaxLength
                    )
                )
                .font(.system(size: 10.5))
                .lineLimit(1)
            }
            .foregroundStyle(Color.orange)
        } else if manager.isResultStale && !manager.isTranslating {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9.5))
                Text(strings.translationResultStale)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.orange)
        } else if let result = manager.result {
            Text(TranslationPresentation.resultMetaText(for: result, strings: strings))
                .font(.system(size: 10.5))
                .foregroundStyle(auxiliaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var displayedResultText: String {
        manager.result?.text ?? ""
    }

    private var isResultDimmed: Bool {
        manager.isResultStale || (manager.isTranslating && manager.result != nil)
    }

    // MARK: - 卡片表面与描边

    private func cardSurface(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(isFocused ? 0.072 : 0.052)
                    : Color.white
            )
    }

    private func cardBorder(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(
                isFocused
                    ? TranslationPresentation.tint.opacity(colorScheme == .dark ? 0.48 : 0.40)
                    : (colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.065)),
                lineWidth: isFocused ? 1 : 0.6
            )
    }

    // MARK: - 按需提示栏（常态零高度）

    @ViewBuilder
    private var noticeArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = manager.notice {
                hintRow(
                    icon: "lock.circle",
                    tint: .orange,
                    text: noticeMessage(notice),
                    actionTitle: strings.translationOpenSettings,
                    action: { Permissions.shared.openAccessibilitySettings() }
                )
            }

            if case .failed(let error) = manager.phase {
                bannerRow(
                    icon: "xmark.circle.fill",
                    tint: Color(red: 0.92, green: 0.32, blue: 0.30),
                    text: TranslationPresentation.errorMessage(error, strings: strings),
                    actionTitle: error == .configurationIncomplete
                        ? strings.translationOpenSettings
                        : strings.translationRetry,
                    action: error == .configurationIncomplete ? onOpenSettings : { manager.submit() }
                )
            }

            if let historyError = manager.historyError {
                bannerRow(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: TranslationPresentation.errorMessage(historyError, strings: strings),
                    actionTitle: nil,
                    action: nil
                )
            }

            if manager.needsAIConfigurationHint, currentError != .configurationIncomplete {
                hintRow(
                    icon: "info.circle",
                    tint: TranslationPresentation.tint,
                    text: strings.translationAIConfigurationHint,
                    actionTitle: onOpenSettings == nil ? nil : strings.translationOpenSettings,
                    action: onOpenSettings
                )
            }

            if preferences.isSystemPreferenceDowngraded(), manager.displayedEngine == .ai {
                hintRow(
                    icon: "info.circle",
                    tint: TranslationPresentation.tint,
                    text: strings.translationEngineDowngradedHint,
                    actionTitle: nil,
                    action: nil
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var hasNoticeContent: Bool {
        if manager.notice != nil { return true }
        if currentError != nil { return true }
        if manager.historyError != nil { return true }
        if manager.needsAIConfigurationHint, currentError != .configurationIncomplete { return true }
        if preferences.isSystemPreferenceDowngraded(), manager.displayedEngine == .ai { return true }
        return false
    }

    private var currentError: TranslationError? {
        if case .failed(let error) = manager.phase { return error }
        return nil
    }

    private func noticeMessage(_ notice: TranslationManager.Notice) -> String {
        switch notice {
        case .accessibilityRequired:
            return strings.translationNoticeAccessibility
        }
    }

    private func hintRow(
        icon: String,
        tint: Color,
        text: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5))
                .foregroundStyle(tint)

            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func bannerRow(
        icon: String,
        tint: Color,
        text: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)

            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 0.5)
        )
    }
}

// MARK: - 展示层共用映射

/// 浮窗 / 管理页 / 设置页共用的展示映射：语言名、引擎名、错误文案、历史摘要。
///
/// 全部为纯映射，不持有状态；用户可见文案一律来自 `Strings`。
enum TranslationPresentation {
    /// 工具徽章图标（SPEC §3.1 建议 character.bubble）。
    static let symbolName = "character.bubble"
    /// 工具主题色：沿用系统蓝，与既有工具徽章风格一致。
    static let tint = Color.accentColor

    // MARK: - 语言

    /// 语言显示名：优先使用本功能本地化文案，未覆盖的语种回落到系统语言名。
    static func languageName(for code: String, strings: Strings) -> String {
        if TranslationLanguage.isSimplifiedChinese(code) {
            return strings.translationLanguageChineseSimplified
        }
        if TranslationLanguage.isTraditionalChinese(code) {
            return strings.translationLanguageChineseTraditional
        }
        switch TranslationLanguage.primaryLanguage(of: code) {
        case "en": return strings.translationLanguageEnglish
        case "ja": return strings.translationLanguageJapanese
        case "ko": return strings.translationLanguageKorean
        case "fr": return strings.translationLanguageFrench
        case "de": return strings.translationLanguageGerman
        case "es": return strings.translationLanguageSpanish
        case "ru": return strings.translationLanguageRussian
        default:
            return Locale.current.localizedString(forIdentifier: code)
                ?? Locale.current.localizedString(forLanguageCode: code)
                ?? code
        }
    }

    /// 语言方向文案，如「简体中文 → 英语」。
    static func languageDirection(source: String, target: String, strings: Strings) -> String {
        String(
            format: strings.translationLanguageDirectionFormat,
            languageName(for: source, strings: strings),
            languageName(for: target, strings: strings)
        )
    }

    // MARK: - 引擎

    static func engineLabel(
        _ engine: TranslationEngineID,
        strings: Strings,
        systemUnavailable: Bool = false
    ) -> String {
        switch engine {
        case .system:
            return systemUnavailable ? strings.translationEngineSystemUnavailable : strings.translationEngineSystem
        case .ai:
            return strings.translationEngineAI
        }
    }

    /// 译文卡片底栏展示的完整元信息：「英语 → 简体中文 · 系统翻译」（AI 优先展示具体模型名）。
    static func resultMetaText(for result: TranslationResult, strings: Strings) -> String {
        let direction = languageDirection(
            source: result.sourceLanguage,
            target: result.targetLanguage,
            strings: strings
        )
        let providerLabel: String
        if result.engine == .ai,
           let model = result.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            providerLabel = model
        } else {
            providerLabel = engineLabel(result.engine, strings: strings)
        }
        return String(format: strings.translationMetaFormat, direction, providerLabel)
    }

    // MARK: - 错误

    /// 翻译错误 → 可操作文案。网络、鉴权、超时等按类别区分，保留原文供重试。
    static func errorMessage(_ error: TranslationError, strings: Strings) -> String {
        switch error {
        case .emptyInput:
            return strings.translationErrorEmptyInput
        case .textTooLong(let limit):
            return String(format: strings.translationErrorTextTooLongFormat, limit)
        case .sourceLanguageUncertain:
            return strings.translationErrorSourceLanguageUncertain
        case .sameLanguage(let code):
            return String(
                format: strings.translationErrorSameLanguageFormat,
                languageName(for: code, strings: strings)
            )
        case .systemTranslationUnavailable:
            return strings.translationErrorSystemUnavailable
        case .unsupportedLanguagePair:
            return strings.translationErrorUnsupportedLanguagePair
        case .modelNotPrepared:
            return strings.translationErrorModelNotPrepared
        case .configurationIncomplete:
            return strings.translationErrorConfigurationIncomplete
        case .credentialReadFailed:
            return strings.translationErrorCredentialReadFailed
        case .network:
            return strings.translationErrorNetwork
        case .timedOut:
            return strings.translationErrorTimedOut
        case .unauthorized:
            return strings.translationErrorUnauthorized
        case .rateLimited:
            return strings.translationErrorRateLimited
        case .serverError(let statusCode):
            return String(format: strings.translationErrorServerFormat, statusCode)
        case .invalidResponse:
            return strings.translationErrorInvalidResponse
        case .historyWriteFailed:
            return strings.translationErrorHistoryNotSaved
        }
    }

    // MARK: - 快捷键

    /// 录键错误 → 本地化文案；冲突时带出被占用的键位，便于用户换键。
    static func hotkeyErrorText(for error: Error, strings: Strings) -> String {
        if case TranslationHotkeyError.conflict(let definition) = error {
            return String(format: strings.translationHotkeyConflictFormat, definition.displayString)
        }
        return strings.translationHotkeyUpdateFailed
    }

    // MARK: - 历史行

    /// 历史单行摘要：折叠换行并截断到固定长度，避免超长原文撑开面板。
    static func summary(_ text: String, limit: Int = 120) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// 历史时间：按系统区域设置展示日期与时间。
    static func historyTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 「语言方向 · 引擎」组合文案。
    static func metaText(
        languageDirection: String,
        engine: TranslationEngineID,
        strings: Strings
    ) -> String {
        String(
            format: strings.translationMetaFormat,
            languageDirection,
            engineLabel(engine, strings: strings)
        )
    }
}
