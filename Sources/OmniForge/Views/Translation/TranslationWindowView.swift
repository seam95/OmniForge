import AppKit
import SwiftUI

// MARK: - 浮窗主视图

/// 翻译浮窗内容（SPEC §4）：标题与置顶 → 引擎与语言 → 原文 → 翻译操作 → 译文与复制。
///
/// 视图只读 manager 的会话状态并调用其动作，不直接发请求、不读数据库、不写剪贴板。
/// 原文与译文上下排列、各自滚动；过期译文保留展示但复制禁用。
///
/// 顶栏与系统红绿灯共用一行（窗口使用 fullSizeContentView）：左侧 76pt 为
/// 红绿灯让位，标题只出现一次，避免与系统标题栏重复。
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
    /// AI 配置 / 引擎降级时进入设置页；nil 时隐藏该入口（仅保留文案提示）。
    let onOpenSettings: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    /// 原文编辑区是否处于中文输入法组合态；组合期间隐藏占位符。
    @State private var editorHasMarkedText = false
    /// 原文编辑区焦点：聚焦时卡片描边高亮。
    @State private var isEditorFocused = false

    private var strings: Strings { stringsProvider() }
    private var primaryText: Color { MonitorOverviewPalette.primary(colorScheme) }
    private var secondaryText: Color { MonitorOverviewPalette.secondary(colorScheme) }
    private var auxiliaryText: Color { MonitorOverviewPalette.auxiliary(colorScheme) }
    private var hairline: Color { MonitorOverviewPalette.hairline(colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            FlatHairline()
            sourceSection
            actionBar
            resultSection
            noticeArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay(alignment: .topLeading) { systemTranslationHost }
        // Esc 兜底：原文编辑器的 Esc 已被输入法 / 本视图拦截；焦点在其它控件时
        // 由窗口层的取消动作走到这里（文本编辑器 doCommandBy 优先于本回调）。
        .onExitCommand(perform: onRequestClose)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : .white
    }

    /// 系统翻译任务宿主：macOS 15 以下不挂载，避免调用不可用 API。
    @ViewBuilder
    private var systemTranslationHost: some View {
        if #available(macOS 15.0, *), let translationTaskHost {
            translationTaskHost()
        }
    }

    // MARK: - 标题行

    /// 与系统红绿灯同一行：左侧留出红绿灯宽度，右侧为置顶。
    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: TranslationPresentation.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TranslationPresentation.tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(TranslationPresentation.tint.opacity(0.12))
                )

            Text(strings.translationTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryText)

            Spacer(minLength: 8)

            Button(action: onTogglePin) {
                Image(systemName: windowState.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(windowState.isPinned ? Color.white : secondaryText)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(windowState.isPinned ? TranslationPresentation.tint : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(windowState.isPinned ? strings.translationUnpin : strings.translationPin)
        }
        .padding(.leading, 76)
        .padding(.trailing, 12)
        .frame(height: 36)
    }

    // MARK: - 引擎与语言

    /// 工具条：左侧引擎分段、右侧语言对胶囊；控件高度统一，整行只占 24pt。
    private var toolbar: some View {
        HStack(spacing: 8) {
            PanelSegmentedControl(
                options: [
                    .init(tag: TranslationEngineID.system, title: strings.translationEngineSystem),
                    .init(tag: TranslationEngineID.ai, title: strings.translationEngineAI),
                ],
                selection: engineBinding,
                style: .capsule(isFullWidth: false)
            )
            .layoutPriority(1)

            Spacer(minLength: 8)

            languageControls
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var languageControls: some View {
        TranslationControlGroup {
            TranslationPickMenu(
                options: sourceLanguageOptions,
                title: sourceLanguageTitle,
                selection: sourceLanguageBinding,
                help: strings.translationSourceLanguage
            )

            TranslationSwapButton(
                isEnabled: preferences.sourceLanguage != nil,
                help: strings.translationSwapLanguages,
                action: { manager.swapLanguages() }
            )

            TranslationPickMenu(
                options: targetOptions,
                title: targetTitle,
                selection: targetBinding,
                help: strings.translationTargetLanguage
            )
        }
    }

    /// 引擎选择绑定「本次运行实际引擎」：macOS 14 上存储 system 会解析为 AI，
    /// 选择 system 时偏好仍写 system，但界面继续显示当前实际引擎并提示降级。
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
        guard let code = preferences.sourceLanguage else { return strings.translationLanguageAuto }
        return TranslationPresentation.languageName(for: code, strings: strings)
    }

    private var targetTitle: String {
        switch preferences.target {
        case .automatic:
            return strings.translationTargetAuto
        case .language(let code):
            return TranslationPresentation.languageName(for: code, strings: strings)
        }
    }

    // MARK: - 原文

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: strings.translationSourceTextLabel,
                trailing: AnyView(characterCount)
            )

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
                        .font(.system(size: 12.5))
                        .foregroundStyle(auxiliaryText.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            .background(cardFill(isFocused: isEditorFocused))
            .overlay(cardBorder(isFocused: isEditorFocused))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .frame(maxHeight: .infinity)
    }

    private var characterCount: some View {
        Text(
            String(
                format: strings.translationCharacterCountFormat,
                manager.sourceText.count,
                TranslationTextValidator.defaultMaxLength
            )
        )
        .font(.system(size: 10, weight: .regular))
        .monospacedDigit()
        .foregroundStyle(isTextTooLong ? Color.orange : auxiliaryText)
    }

    private var sourceTextBinding: Binding<String> {
        Binding(
            get: { manager.sourceText },
            set: { manager.updateText($0) }
        )
    }

    // MARK: - 卡片外观

    /// 输入/输出共用卡片底：浅色近白、深色低透明白；聚焦时提升到纯白并加描边。
    private func cardFill(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color.white.opacity(isFocused ? 0.06 : 0.045)
                    : (isFocused
                        ? Color.white
                        : Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0))
            )
    }

    private func cardBorder(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .strokeBorder(
                isFocused
                    ? TranslationPresentation.tint.opacity(0.5)
                    : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)),
                lineWidth: isFocused ? 1 : 0.5
            )
    }

    // MARK: - 翻译操作

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button {
                manager.submit()
            } label: {
                HStack(spacing: 5) {
                    if manager.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(manager.isTranslating ? strings.translationTranslating : strings.translationTranslate)
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .frame(minWidth: 64)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isTranslateDisabled)

            // 快捷键提示使用系统键盘符号（非本地化文案）；实际按键由原文编辑器
            // 的 doCommandBy 处理，避免 SwiftUI 快捷键在输入法组合态抢先提交。
            Text("⌘↩")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(auxiliaryText)

            Spacer(minLength: 8)

            if isTextTooLong {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(
                        String(
                            format: strings.translationErrorTextTooLongFormat,
                            TranslationTextValidator.defaultMaxLength
                        )
                    )
                    .font(.system(size: 10, weight: .regular))
                }
                .foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var isTextTooLong: Bool {
        manager.sourceText.count > TranslationTextValidator.defaultMaxLength
    }

    /// 空文本禁用翻译（SPEC §4）；翻译进行中避免重复提交。
    /// 超长不静默截断，按钮保留可点，点击后由语言解析层给出明确错误。
    private var isTranslateDisabled: Bool {
        manager.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || manager.isTranslating
    }

    // MARK: - 译文

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                title: strings.translationResultLabel,
                trailing: AnyView(copyControl)
            )

            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    // 过期提示放在译文内容上方而不是标题行：中英文长句都不会挤压复制按钮。
                    if manager.isResultStale {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text(strings.translationResultStale)
                                .font(.system(size: 10, weight: .regular))
                        }
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }

                    ScrollView {
                        Text(displayedResultText)
                            .font(.system(size: 13))
                            .foregroundStyle(resultTextColor)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }

                if manager.result == nil {
                    if manager.isTranslating {
                        VStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text(strings.translationTranslating)
                                .font(.system(size: 11))
                                .foregroundStyle(auxiliaryText)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 17, weight: .light))
                            Text(strings.translationResultPlaceholder)
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(auxiliaryText.opacity(0.75))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(cardFill(isFocused: false))
            .overlay(cardBorder(isFocused: false))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity)
    }

    private var displayedResultText: String {
        manager.result?.text ?? ""
    }

    private var resultTextColor: Color {
        manager.result == nil ? secondaryText.opacity(0.55) : primaryText
    }

    /// 复制控件：过期译文保留展示但禁用复制；已复制显示短暂确认文案。
    private var copyControl: some View {
        let isEnabled = manager.canCopyResult
        let isCopied = manager.didCopyResult

        return Button {
            manager.copyResult()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5))
                Text(isCopied ? strings.translationCopied : strings.translationCopy)
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(
                isCopied
                    ? Color.green
                    : (isEnabled ? secondaryText : auxiliaryText.opacity(0.75))
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - 错误与提示

    /// 提示区：普通提示为轻量说明行，失败才用 tint 横幅。
    /// 与「失败」区分的 notice 不显示为错误色，避免把权限问题渲染成网络错误。
    @ViewBuilder
    private var noticeArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = manager.notice {
                hintRow(
                    icon: notice == .accessibilityRequired ? "lock.circle" : "text.cursor",
                    tint: .orange,
                    text: noticeMessage(notice),
                    actionTitle: notice == .accessibilityRequired ? strings.translationOpenSettings : nil,
                    action: notice == .accessibilityRequired
                        ? { Permissions.shared.openAccessibilitySettings() }
                        : nil
                )
            }

            if case .failed(let error) = manager.phase {
                bannerRow(
                    icon: "xmark.circle.fill",
                    tint: Color(red: 0.95, green: 0.35, blue: 0.32),
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
        .padding(.bottom, hasNoticeContent ? 10 : 0)
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
        case .accessibilityRequired: return strings.translationNoticeAccessibility
        case .noSelection: return strings.translationNoticeNoSelection
        }
    }

    /// 轻量提示行：无底色，只用来补充信息或提供设置入口。
    private func hintRow(
        icon: String,
        tint: Color,
        text: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)

            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
    }

    /// 失败横幅：tint 低透明底 + 圆角，与普通提示区分。
    private func bannerRow(
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
                .foregroundStyle(primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.08))
        )
    }

    // MARK: - 区块头

    private func sectionHeader(title: String, trailing: AnyView) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(secondaryText)
            Spacer(minLength: 8)
            trailing
        }
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
