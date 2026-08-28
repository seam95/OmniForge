import SwiftUI

/// 桌面便签管理页（实用工具详情，compact 布局）：
/// 进行中 / 已完成两区 + 设置区（新建快捷键 recorder + 通知授权状态）。
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
            ContentUnavailableView(strings.stickyNoteNoNotes, systemImage: "note.text")
                .padding(.vertical, 24)
        }
    }
}

@MainActor
private struct StickyNotesContent: View {
    let strings: Strings
    @ObservedObject var manager: StickyNoteManager
    @ObservedObject private var permissions = Permissions.shared
    @State private var notePendingDeletion: StickyNote?
    @Environment(\.colorScheme) private var colorScheme

    private var l10n: L10n { L10n(userDefaults: .standard) }

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                newNoteButton
                if activeNotes.isEmpty && completedNotes.isEmpty {
                    ContentUnavailableView(strings.stickyNoteNoNotes, systemImage: "note.text")
                        .padding(.vertical, 20)
                } else {
                    section(title: strings.stickyNoteSectionActive) {
                        ForEach(activeNotes) { note in
                            activeRow(note: note)
                        }
                    }
                    if !completedNotes.isEmpty {
                        section(title: strings.stickyNoteSectionCompleted) {
                            ForEach(completedNotes) { note in
                                completedRow(note: note)
                            }
                        }
                    }
                }
                settingsSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
    }

    // MARK: - 区块

    /// 头部：图标徽章 + 标题 + 进行中/已完成统计（设计稿 03）。
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: UtilityTool.stickyNotes.symbolName())
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Stats.ram)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(UtilityTool.stickyNotes.tintColor.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(strings.featureHubNameStickyNotes)
                    .font(Theme.Stats.font13SemiBold)
                    .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                Text(String(format: strings.stickyNoteCountsFormat, activeNotes.count, completedNotes.count))
                    .font(Theme.Stats.font11Regular)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
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

    @ViewBuilder
    private func section(title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                rows()
            }
            .background(StickyListCardBackground())
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
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
                        note.summary.isEmpty ? Color.secondary
                            : (colorScheme == .light ? Theme.Stats.text1 : Color.primary)
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
            .padding(.horizontal, 10)
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
                .foregroundStyle(Color.secondary)
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
        .padding(.horizontal, 10)
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
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(isDestructive ? Color(red: 0.95, green: 0.35, blue: 0.32) : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - 设置区

    /// 设置卡片：新建快捷键（键帽 recorder）+ 系统通知权限状态（设计稿 03）。
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(strings.stickyNoteSectionSettings)
                .font(Theme.Stats.font12Medium)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                HStack {
                    Text(strings.stickyNoteHotkeyTitle)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                Rectangle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Theme.Stats.separator)
                    .frame(height: 0.5)
                    .padding(.leading, 10)

                HStack {
                    Text(strings.stickyNoteNotificationPermission)
                        .font(Theme.Stats.font11Regular)
                        .foregroundStyle(colorScheme == .light ? Theme.Stats.text1 : Color.primary)
                    Spacer()
                    if permissions.notifications {
                        notificationGrantedBadge
                    } else {
                        Text(strings.stickyNoteNotificationDenied)
                            .font(Theme.Stats.font11Regular)
                            .foregroundStyle(Color.secondary)
                        Button(strings.permissionOpenSettings) {
                            Permissions.shared.requestNotifications()
                        }
                        .controlSize(.small)
                        .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(StickyListCardBackground())
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
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

private extension StickyNote {
    /// 已完成区排序键：完成时刻近似取 updatedAt。
    var completedAtForSorting: Date { updatedAt }
}

/// 列表卡片背景（对齐实用工具页样式）。
private struct StickyListCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                Color.white.opacity(0.08)
            } else {
                Theme.Stats.cardBackground
            }
        }
    }
}
