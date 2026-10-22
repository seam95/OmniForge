import AppKit
import KeyboardShortcuts
import SwiftUI

// MARK: - 实用工具详情页（翻译管理）

/// 翻译管理页（控制中心实用工具详情，compact 平面分区）：
/// header（徽章 + 历史数量 + 新建 CTA）→ 历史列表 / 空态 → 快捷设置，
/// 分区之间发丝线分隔，行平铺白底（背景由控制中心持有）。
///
/// 打开浮窗的动作由 manager 完成（`newSession` / `openHistory` 内部会驱动
/// `TranslationWindowPresenting`）；随后调用 `onNewTranslation` 让宿主收起控制中心，
/// 避免控制中心与翻译浮窗争抢键盘焦点（SPEC §3.1）。
@MainActor
struct TranslationUtilityDetailView: View {
    @ObservedObject var manager: TranslationManager
    @ObservedObject var preferences: TranslationPreferences
    let strings: Strings
    /// 录键冲突检测与注册；nil 时降级为直接写偏好（无冲突检测）。
    let hotkeyManager: TranslationHotkeyManager?
    /// 新建或从历史打开浮窗后通知宿主收起控制中心。
    let onNewTranslation: () -> Void
    /// 「更多设置…」→ 设置窗口翻译 tab。
    let onOpenSettings: () -> Void
    /// 录键变更后的附加通知（宿主可刷新展示）。
    let onHotkeyChanged: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var entryPendingDeletion: TranslationHistoryEntry?
    @State private var isClearConfirmationPresented = false
    @State private var hotkeyError: String?
    /// 刚复制过的历史条目：短暂显示对勾，反馈行内复制成功。
    @State private var copiedEntryID: UUID?

    init(
        manager: TranslationManager,
        preferences: TranslationPreferences,
        strings: Strings,
        hotkeyManager: TranslationHotkeyManager? = nil,
        onNewTranslation: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onHotkeyChanged: @escaping () -> Void = {}
    ) {
        self.manager = manager
        self.preferences = preferences
        self.strings = strings
        self.hotkeyManager = hotkeyManager
        self.onNewTranslation = onNewTranslation
        self.onOpenSettings = onOpenSettings
        self.onHotkeyChanged = onHotkeyChanged
    }

    private var tint: Color { TranslationPresentation.tint }
    private var l10n: L10n { L10n(userDefaults: .standard) }
    private var primaryText: Color { MonitorOverviewPalette.primary(colorScheme) }
    private var secondaryText: Color { MonitorOverviewPalette.secondary(colorScheme) }
    private let destructiveRed = Color(red: 0.95, green: 0.35, blue: 0.32)

    private var hotkeyDisplayText: String {
        preferences.hotkey?.displayString ?? strings.translationHotkeyUnset
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            FlatHairline()

            if manager.historyError != nil {
                historyErrorRow
            }

            if manager.history.isEmpty {
                emptyState
            } else {
                historySection
            }

            FlatHairline()

            settingsSection
        }
        .alert(
            strings.translationHistoryDeleteConfirmTitle,
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            )
        ) {
            Button(strings.translationHistoryDelete, role: .destructive) {
                if let entry = entryPendingDeletion {
                    Task { await manager.deleteHistory(id: entry.id) }
                }
                entryPendingDeletion = nil
            }
            Button(role: .cancel) {} label: { Text(strings.translationCancel) }
        } message: {
            Text(strings.translationHistoryDeleteConfirmMessage)
        }
        .alert(
            strings.translationHistoryClearConfirmTitle,
            isPresented: $isClearConfirmationPresented
        ) {
            Button(strings.translationHistoryDelete, role: .destructive) {
                Task { await manager.clearHistory() }
            }
            Button(role: .cancel) {} label: { Text(strings.translationCancel) }
        } message: {
            Text(
                String(
                    format: strings.translationHistoryClearConfirmMessageFormat,
                    manager.history.count
                )
            )
        }
    }

    // MARK: - 头部

    /// 头部：图标徽章 + 名称 + 历史数量 + 全宽「新建翻译」（附当前快捷键）。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: TranslationPresentation.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Stats.ram)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(strings.featureHubNameTranslation)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(primaryText)
                    Text(
                        String(
                            format: strings.translationHistoryCountFormat,
                            manager.history.count
                        )
                    )
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(secondaryText)
                }

                Spacer()
            }

            Button {
                // 新建空白会话并聚焦输入；不读取其他应用选区（SPEC §3.2）。
                manager.newSession()
                onNewTranslation()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text(strings.utilityTranslationNew)
                    Text("(\(hotkeyDisplayText))")
                        .font(Theme.Stats.font11Regular)
                        .opacity(0.8)
                }
                .font(Theme.Stats.font13SemiBold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 历史

    /// 历史读取 / 写入失败提示：不把「读取失败」伪装成「暂无记录」。
    private var historyErrorRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(Color.orange)
            Text(strings.translationHistoryUnavailable)
                .font(Theme.Stats.font10Regular)
                .foregroundStyle(secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.translationHistorySection, accent: tint) {
                clearHistoryButton
            }

            VStack(spacing: 0) {
                ForEach(Array(manager.history.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        rowSeparator
                    }
                    historyRow(entry)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 清空历史：一次确认（含条数）；只删除历史数据，不影响当前会话。
    private var clearHistoryButton: some View {
        Button {
            isClearConfirmationPresented = true
        } label: {
            Text(strings.translationHistoryClear)
                .font(Theme.Stats.font11Regular)
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .foregroundStyle(destructiveRed)
        .help(strings.translationHistoryClear)
    }

    /// 历史行：整行可点 = 在浮窗查看已保存内容（不重新翻译）。
    /// 右侧删除按钮为嵌套按钮，自行拦截点击。
    private func historyRow(_ entry: TranslationHistoryEntry) -> some View {
        Button {
            manager.openHistory(entry)
            onNewTranslation()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(TranslationPresentation.summary(entry.request.text))
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        Text(TranslationPresentation.historyTime(entry.completedAt))
                            .font(Theme.Stats.font10Regular)
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                    }

                    Text(TranslationPresentation.summary(entry.result.text))
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(metaText(for: entry))
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(secondaryText.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // 行内复制译文：直接写系统剪贴板，不切换当前会话、不触发重新翻译。
                IconButton(
                    systemImage: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc",
                    tint: nil,
                    help: strings.translationCopy,
                    action: { copyTranslation(entry) }
                )

                IconButton(
                    systemImage: "trash",
                    tint: destructiveRed,
                    help: strings.translationHistoryDelete,
                    action: { entryPendingDeletion = entry }
                )
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strings.translationOpenHistory)
    }

    /// 复制历史译文的纯文本；成功后短暂显示对勾。
    private func copyTranslation(_ entry: TranslationHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(entry.result.text, forType: .string) else { return }
        copiedEntryID = entry.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedEntryID == entry.id {
                copiedEntryID = nil
            }
        }
    }

    private func metaText(for entry: TranslationHistoryEntry) -> String {
        TranslationPresentation.metaText(
            languageDirection: TranslationPresentation.languageDirection(
                source: entry.result.sourceLanguage,
                target: entry.result.targetLanguage,
                strings: strings
            ),
            engine: entry.result.engine,
            strings: strings
        )
    }

    /// 空态：标题 + 快捷键使用提示；未设置快捷键时提示改用上方按钮。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: TranslationPresentation.symbolName)
                .font(.system(size: 24))
                .foregroundStyle(Color.secondary.opacity(0.5))

            Text(strings.utilityTranslationHistoryEmpty)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(Color.secondary.opacity(0.7))

            Text(emptyStateHint)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(Color.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
    }

    private var emptyStateHint: String {
        guard let hotkey = preferences.hotkey else {
            return strings.translationEmptyHintNoHotkey
        }
        return String(format: strings.utilityTranslationHistoryEmptyHint, hotkey.displayString)
    }

    // MARK: - 快捷设置

    /// 底部快捷设置：录键、默认引擎、保存历史开关、更多设置入口。
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.translationSettingsSection, accent: tint)

            VStack(spacing: 0) {
                HStack {
                    Text(strings.translationHotkeyTitle)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(primaryText)
                    Spacer()
                    HotkeyRecorderView(
                        displayText: preferences.hotkey?.displayString ?? "",
                        onShortcutChanged: { shortcut in
                            applyHotkey(shortcut)
                        },
                        l10n: l10n,
                        style: .keycaps
                    )
                }
                .padding(.vertical, 8)

                rowSeparator

                HStack {
                    Text(strings.translationDefaultEngine)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(primaryText)
                    Spacer()
                    Picker("", selection: engineBinding) {
                        Text(
                            TranslationPresentation.engineLabel(
                                .system,
                                strings: strings,
                                systemUnavailable: !TranslationPreferences.isSystemTranslationSupported
                            )
                        )
                        .tag(TranslationEngineID.system)
                        Text(strings.translationEngineAI)
                            .tag(TranslationEngineID.ai)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                .padding(.vertical, 8)

                rowSeparator

                Toggle(
                    strings.translationSaveHistory,
                    isOn: Binding(
                        get: { preferences.saveHistory },
                        set: { preferences.saveHistory = $0 }
                    )
                )
                .font(Theme.Stats.font11Regular)
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.vertical, 8)

                if let hotkeyError {
                    rowSeparator
                    Text(hotkeyError)
                        .font(Theme.Stats.font10Regular)
                        .foregroundStyle(destructiveRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                rowSeparator

                HStack {
                    Button(strings.translationMoreSettings) {
                        onOpenSettings()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 默认引擎绑定存储偏好：macOS 14 选择 system 时保留偏好，
    /// 本次运行由 manager 解析为 AI 并在浮窗提示降级。
    private var engineBinding: Binding<TranslationEngineID> {
        Binding(
            get: { preferences.engine },
            set: { manager.selectEngine($0) }
        )
    }

    /// 录键回调：冲突时不写偏好，保留上一份有效绑定并给出冲突提示。
    private func applyHotkey(_ shortcut: KeyboardShortcuts.Shortcut?) {
        hotkeyError = nil
        // 录制被取消 / 为空：不静默禁用，保持已持久化绑定（与便签管理页一致）。
        guard let definition = HotkeyDefinition(shortcut: shortcut) else { return }
        do {
            if let hotkeyManager {
                try hotkeyManager.setHotkey(definition)
            } else {
                preferences.setHotkey(definition)
            }
            onHotkeyChanged()
        } catch {
            hotkeyError = TranslationPresentation.hotkeyErrorText(for: error, strings: strings)
        }
    }
}

// MARK: - 行分隔线

private extension TranslationUtilityDetailView {
    /// 列表行间分隔线（区别于分区发丝线）。
    var rowSeparator: some View {
        Rectangle()
            .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
