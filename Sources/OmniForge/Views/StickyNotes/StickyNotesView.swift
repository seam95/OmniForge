import SwiftUI

/// 桌面便签管理页（实用工具详情，compact 布局，平面分区）：
/// header（徽章 + 统计 + 新建 CTA）→ 进行中 / 已完成 → 设置，
/// 分区之间发丝线分隔，行平铺白底（背景由转场层持有）。
@MainActor
struct StickyNotesView: View {
    let strings: Strings
    /// 详情页仅在功能可用时可达，正常非 nil；防御式留空态。
    private let manager: StickyNoteManager?

    init(strings: Strings, manager: StickyNoteManager? = nil) {
        self.strings = strings
        self.manager = manager
            ?? FeatureRuntime.shared.manager(for: .stickyNotes, as: StickyNoteManager.self)
    }

    var body: some View {
        if let manager {
            StickyNotesContent(strings: strings, manager: manager)
        } else {
            flatEmptyState(text: strings.stickyNoteNoNotes, icon: "note.text")
        }
    }
}

@MainActor
private struct StickyNotesContent: View {
    let strings: Strings
    @ObservedObject var manager: StickyNoteManager
    @ObservedObject private var permissions = Permissions.shared
    @State private var notePendingDeletion: StickyNote?
    @State private var isClearCompletedConfirmationPresented = false
    @Environment(\.colorScheme) private var colorScheme

    private var l10n: L10n { L10n(userDefaults: .standard) }

    private var tint: Color { UtilityTool.stickyNotes.tintColor }

    private var activeNotes: [StickyNote] {
        manager.notes
            .filter { !$0.completed }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var completedNotes: [StickyNote] {
        manager.notes
            .filter { $0.completed }
            .sorted { $0.completedAtForSorting > $1.completedAtForSorting }
    }

    /// 列表行间分隔线（区别于分区发丝线）。
    private var rowSeparator: some View {
        Rectangle()
            .fill(colorScheme == .light ? Theme.Stats.separator : Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    var body: some View {
        // 外层控制中心已提供 ScrollView；此处平面拼装，滚动由宿主承载。
        VStack(spacing: 0) {
            header

            FlatHairline()

            if activeNotes.isEmpty && completedNotes.isEmpty {
                flatEmptyState(text: strings.stickyNoteNoNotes, icon: "note.text")
            } else {
                noteSection(title: strings.stickyNoteSectionActive) {
                    ForEach(Array(activeNotes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { rowSeparator }
                        activeRow(note: note)
                    }
                }

                if !completedNotes.isEmpty {
                    FlatHairline()

                    noteSection(
                        title: strings.stickyNoteSectionCompleted,
                        trailing: { clearCompletedButton }
                    ) {
                        ForEach(Array(completedNotes.enumerated()), id: \.element.id) { index, note in
                            if index > 0 { rowSeparator }
                            completedRow(note: note)
                        }
                    }
                }
            }

            FlatHairline()

            settingsSection
        }
        .alert(
            strings.stickyNoteDeleteConfirmTitle,
            isPresented: Binding(
                get: { notePendingDeletion != nil },
                set: { if !$0 { notePendingDeletion = nil } }
            )
        ) {
            Button(strings.stickyNoteDelete, role: .destructive) {
                if let note = notePendingDeletion {
                    manager.delete(id: note.id)
                }
                notePendingDeletion = nil
            }
            Button(role: .cancel) {} label: { Text(strings.stickyNoteDeleteCancel) }
        } message: {
            Text(strings.stickyNoteDeleteConfirmMessage)
        }
        .alert(
            strings.stickyNoteClearCompletedConfirmTitle,
            isPresented: $isClearCompletedConfirmationPresented
        ) {
            Button(strings.stickyNoteDelete, role: .destructive) {
                manager.deleteCompleted()
            }
            Button(role: .cancel) {} label: { Text(strings.stickyNoteDeleteCancel) }
        } message: {
            Text(String(format: strings.stickyNoteClearCompletedConfirmMessage, completedNotes.count))
        }
    }

    // MARK: - 区块

    /// 头部：图标徽章 + 标题 + 进行中/已完成统计 + 新建 CTA。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: UtilityTool.stickyNotes.symbolName())
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Stats.ram)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tint.opacity(0.16))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(strings.featureHubNameStickyNotes)
                        .font(Theme.Stats.font13SemiBold)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    Text(String(format: strings.stickyNoteCountsFormat, activeNotes.count, completedNotes.count))
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.auxiliary(colorScheme))
                }
                Spacer()
            }

            newNoteButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var newNoteButton: some View {
        Button {
            manager.create()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text(strings.stickyNoteCreateButton)
                Text("(\(manager.hotkey.displayString))")
                    .font(Theme.Stats.font11Regular)
                    .opacity(0.8)
            }
            .font(Theme.Stats.font13SemiBold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
    }

    /// 便签分区：区头（tint 色块）+ 行平铺，行间 separator 分隔。
    private func noteSection(
        title: String,
        @ViewBuilder trailing: @escaping () -> some View = { EmptyView() },
        @ViewBuilder rows: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: title, accent: tint, trailing: trailing)
            VStack(spacing: 0) {
                rows()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 已完成区头部「清空…」：一次确认（含条数）物理删除全部已完成便签。
    private var clearCompletedButton: some View {
        Button {
            isClearCompletedConfirmationPresented = true
        } label: {
            Text(strings.stickyNoteClearCompleted)
                .font(Theme.Stats.font11Regular)
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .foregroundStyle(Color(red: 0.95, green: 0.35, blue: 0.32))
        .help(strings.stickyNoteClearCompleted)
    }

    /// 进行中行：整行可点选 = 定位显示（恢复显示并前置，可压过最大化前台 app）；
    /// 右侧操作按钮为嵌套按钮，各自拦截点击。
    private func activeRow(note: StickyNote) -> some View {
        Button {
            manager.restoreVisible(id: note.id)
        } label: {
            HStack(spacing: 8) {
                colorBar(for: note.color, faded: false)

                Text(note.summary.isEmpty ? strings.stickyNoteEmptyContent : note.summary)
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(
                        note.summary.isEmpty
                            ? MonitorOverviewPalette.secondary(colorScheme)
                            : MonitorOverviewPalette.primary(colorScheme)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)

                if note.hidden {
                    statusBadge(strings.stickyNoteBadgeHidden)
                }
                if note.isReminderFired {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Stats.ram)
                } else if note.reminderAt != nil {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Stats.ram)
                }

                Spacer(minLength: 4)

                rowButton(icon: "rectangle.and.arrow.up.2", label: strings.stickyNoteLocate) {
                    manager.restoreVisible(id: note.id)
                }
                rowButton(icon: "checkmark.circle", label: strings.stickyNoteComplete) {
                    manager.complete(id: note.id)
                }
                rowButton(icon: "trash", label: strings.stickyNoteDelete, isDestructive: true) {
                    notePendingDeletion = note
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(strings.stickyNoteLocate)
    }

    private func completedRow(note: StickyNote) -> some View {
        HStack(spacing: 8) {
            colorBar(for: note.color, faded: true)

            Text(note.summary.isEmpty ? strings.stickyNoteEmptyContent : note.summary)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                .strikethrough()
                .lineLimit(1)

            Spacer(minLength: 4)

            rowButton(icon: "arrow.uturn.backward", label: strings.stickyNoteRestore) {
                manager.uncomplete(id: note.id)
            }
            rowButton(icon: "trash", label: strings.stickyNoteDelete, isDestructive: true) {
                notePendingDeletion = note
            }
        }
        .padding(.vertical, 8)
    }

    /// 行首竖色条（设计稿 03）：宽 3.5、高 15、圆角 2；已完成行半透明。
    private func colorBar(for color: StickyNoteColor, faded: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(StickyNotePalette.palette(for: color).accent.opacity(faded ? 0.45 : 1))
            .frame(width: 3.5, height: 15)
    }

    private func statusBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(Color.secondary)
    }

    private func rowButton(
        icon: String,
        label: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        IconButton(
            systemImage: icon,
            tint: isDestructive ? Color(red: 0.95, green: 0.35, blue: 0.32) : nil,
            help: label,
            action: action
        )
    }

    // MARK: - 设置区

    /// 设置分区：新建快捷键（键帽 recorder）+ 系统通知权限状态。
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlatSectionHeader(title: strings.stickyNoteSectionSettings, accent: tint)

            VStack(spacing: 0) {
                HStack {
                    Text(strings.stickyNoteHotkeyTitle)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    Spacer()
                    HotkeyRecorderView(
                        displayText: manager.hotkey.displayString,
                        onShortcutChanged: { shortcut in
                            manager.handleRecorderChange(shortcut)
                        },
                        l10n: l10n,
                        style: .keycaps
                    )
                }
                .padding(.vertical, 8)

                rowSeparator

                HStack {
                    Text(strings.stickyNoteNotificationPermission)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(MonitorOverviewPalette.primary(colorScheme))
                    Spacer()
                    if permissions.notifications {
                        notificationGrantedBadge
                    } else {
                        Text(strings.stickyNoteNotificationDenied)
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(MonitorOverviewPalette.secondary(colorScheme))
                        Button(strings.permissionOpenSettings) {
                            Permissions.shared.requestNotifications()
                        }
                        .controlSize(.small)
                        .buttonStyle(.link)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 已授权状态胶囊：绿点 + 绿字浅绿底。
    private var notificationGrantedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.Stats.statusNormal)
                .frame(width: 5.5, height: 5.5)
            Text(strings.stickyNoteNotificationGranted)
                .font(Theme.Stats.font11Regular)
                .foregroundStyle(Theme.Stats.statusNormal)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Theme.Stats.statusNormal.opacity(0.10)))
    }
}

/// 平面空态：辅助色图标 + 12 medium 说明，居中且不小于面板空态下限。
@MainActor
private func flatEmptyState(text: String, icon: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: icon)
            .font(.system(size: 24))
            .foregroundStyle(Color.secondary.opacity(0.5))

        Text(text)
            .font(Theme.Stats.font12Medium)
            .foregroundStyle(Color.secondary.opacity(0.7))
            .multilineTextAlignment(.center)
    }
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, minHeight: ControlCenterContentMetrics.emptyContentMinHeight)
}

private extension StickyNote {
    /// 已完成区排序键：完成时刻近似取 updatedAt。
    var completedAtForSorting: Date { updatedAt }
}
