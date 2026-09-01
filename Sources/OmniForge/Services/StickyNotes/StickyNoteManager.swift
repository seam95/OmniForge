import AppKit
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// 桌面便签「新建便签」全局快捷键；UserDefaults 为真源，此 Name 为运行时镜像。
    static let stickyNoteNewNote = Self(
        "stickyNoteNewNote",
        default: HotkeyDefinition.defaultStickyNoteNewNote.keyboardShortcut
    )
}

/// KeyboardShortcuts 可注入写面（对齐 ScreenshotKeyboardShortcutsClient 模式，便于测试断言注册/注销）。
protocol StickyNoteHotkeyClient: AnyObject {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name)
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void)
}

final class LiveStickyNoteHotkeyClient: StickyNoteHotkeyClient {
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.setShortcut(shortcut, for: name)
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        KeyboardShortcuts.onKeyUp(for: name, action: action)
    }
}

/// 便签提醒设置错误；View 层负责映射文案。
enum StickyNoteReminderError: Error, Equatable {
    case noteNotFound
    case pastTime
}

/// 桌面便签领域服务：数据、动作、提醒双通道调度与全局快捷键。
/// 重接线 feature（对齐截图模式）：install 时 `restoreOnInstall()`，teardown 时 `teardown()`。
@MainActor
final class StickyNoteManager: ObservableObject {
    @Published private(set) var notes: [StickyNote] = []
    /// 状态栏保存指示：true = 有防抖中的未落库编辑。
    @Published private(set) var isSaving = false

    private let store: StickyNoteStore
    private let reminderScheduler: StickyNoteReminderScheduling
    private let windowPresenter: StickyNoteWindowPresenting
    private let hotkeyClient: StickyNoteHotkeyClient
    private let now: () -> Date
    private let userDefaults: UserDefaults
    private let isFeatureAvailable: () -> Bool
    private let visibleScreensProvider: () -> [CGRect]
    private let stringsProvider: () -> Strings
    /// 编辑 / frame 防抖落库间隔；测试注入短间隔。
    private let persistDebounce: TimeInterval

    private var persistTasks: [UUID: Task<Void, Never>] = [:]
    private var isHotkeyListening = false
    private var hasRegisteredHotkeyOnKeyUpHandler = false

    init(
        store: StickyNoteStore,
        reminderScheduler: StickyNoteReminderScheduling,
        windowPresenter: StickyNoteWindowPresenting,
        hotkeyClient: StickyNoteHotkeyClient = LiveStickyNoteHotkeyClient(),
        userDefaults: UserDefaults = .standard,
        isFeatureAvailable: (() -> Bool)? = nil,
        visibleScreensProvider: @escaping () -> [CGRect] = {
            NSScreen.screens.map(\.visibleFrame)
        },
        stringsProvider: @escaping () -> Strings = { L10n(userDefaults: .standard).s },
        now: @escaping () -> Date = Date.init,
        persistDebounce: TimeInterval = 0.5
    ) {
        self.store = store
        self.reminderScheduler = reminderScheduler
        self.windowPresenter = windowPresenter
        self.hotkeyClient = hotkeyClient
        self.now = now
        self.userDefaults = userDefaults
        // 默认参数表达式是 nonisolated 上下文，不能调用 MainActor 方法，改为 init 内兜底。
        self.isFeatureAvailable = isFeatureAvailable
            ?? { FeatureRuntime.shared.isAvailable(.stickyNotes) }
        self.visibleScreensProvider = visibleScreensProvider
        self.stringsProvider = stringsProvider
        self.persistDebounce = persistDebounce
        notes = store.loadNotes()
    }

    deinit {
        for task in persistTasks.values {
            task.cancel()
        }
    }

    // MARK: - 新建

    /// 新建便签：位置 = 最近创建便签级联（越界回落主屏默认位），颜色继承最近使用色。
    @discardableResult
    func create() -> StickyNote? {
        let screens = visibleScreensProvider()
        let lastCreated = notes.max { $0.createdAt < $1.createdAt }
        let frame: CGRect
        if let lastCreated {
            frame = StickyNoteGeometry.cascadeFrame(
                lastCreatedFrame: lastCreated.frame,
                visibleScreens: screens
            )
        } else {
            frame = StickyNoteGeometry.defaultFrame(on: screens)
        }
        let timestamp = now()
        let note = StickyNote(
            content: "",
            color: lastCreated?.color ?? .yellow,
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        notes.append(note)
        store.saveNote(note)
        windowPresenter.show(note: note)
        return note
    }

    // MARK: - 编辑与状态动作

    /// 即输即存的正文更新：立即更新内存与保存指示，防抖落库。
    func updateContent(id: UUID, content: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].content != content else { return }
        notes[index].content = content
        notes[index].updatedAt = now()
        isSaving = true
        schedulePersist(id: id)
    }

    func setColor(id: UUID, color: StickyNoteColor) {
        mutate(id) { $0.color = color }
        syncWindow(id: id)
    }

    func togglePin(id: UUID) {
        mutate(id) { $0.pinned.toggle() }
        syncWindow(id: id)
    }

    /// 折叠（正文收起为工具栏条，窗口保留可见）/ 展开。
    /// `frame` 恒存展开态尺寸；折叠条的窗口 frame 由窗口层换算。
    func setCollapse(id: UUID, collapsed: Bool) {
        mutate(id) { $0.collapsed = collapsed }
        syncWindow(id: id)
    }

    /// 便签窗口「折叠 / 展开」按钮回调（对齐 togglePin 先例）。
    func toggleCollapse(id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        setCollapse(id: id, collapsed: !note.collapsed)
    }

    /// 设置正文字号（工具栏 Aa 档位面板）：仅接受档位表内的值。
    func setFontSize(id: UUID, fontSize: Double) {
        guard StickyNote.fontSizeSteps.contains(fontSize),
              let note = notes.first(where: { $0.id == id }),
              note.fontSize != fontSize else { return }
        mutate(id) { $0.fontSize = fontSize }
        syncWindow(id: id)
    }

    /// 完成便签：标记完成并隐藏；事项已办，提醒一并撤销。
    /// 空白便签（误新建、未写内容）没有归档价值：完成动作退化为物理删除，
    /// 免去「先完成进归档、再去已完成区删一次」的两步操作。
    func complete(id: UUID) {
        if let note = notes.first(where: { $0.id == id }), note.isBlank {
            delete(id: id)
            return
        }
        clearReminderChannels(id: id)
        mutate(id) { note in
            note.completed = true
            note.hidden = true
            note.reminderAt = nil
            note.reminderFiredAt = nil
        }
        windowPresenter.hide(id: id)
    }

    /// 取消完成：恢复为进行中并显示。
    func uncomplete(id: UUID) {
        mutate(id) { note in
            note.completed = false
            note.hidden = false
        }
        syncWindow(id: id)
        windowPresenter.bringToFront(id: id)
    }

    /// 管理页「定位显示」：恢复显示并前置。
    func restoreVisible(id: UUID) {
        mutate(id) { $0.hidden = false }
        syncWindow(id: id)
        windowPresenter.bringToFront(id: id)
    }

    /// 硬删除：移除数据并撤销提醒与窗口。
    func delete(id: UUID) {
        persistTasks[id]?.cancel()
        persistTasks[id] = nil
        clearReminderChannels(id: id)
        notes.removeAll { $0.id == id }
        store.deleteNote(id: id)
        windowPresenter.dismiss(id: id)
        updateSavingIndicator()
    }

    /// 管理页已完成区「清空…」：物理删除全部已完成便签（View 层负责确认弹窗）。
    func deleteCompleted() {
        for id in notes.filter(\.completed).map(\.id) {
            delete(id: id)
        }
    }

    /// 托盘「显示所有便签」：未完成便签全部恢复显示并前置——
    /// 收起的重新显示；可见但被其他窗口盖住的（如最大化前台 app）强制前置。
    /// 已完成便签只能经管理页处理。
    func showAll() {
        for note in notes where !note.completed {
            if note.hidden {
                mutate(note.id) { $0.hidden = false }
                if let updated = notes.first(where: { $0.id == note.id }) {
                    windowPresenter.show(note: updated)
                }
            } else {
                windowPresenter.bringToFront(id: note.id)
            }
        }
    }

    /// 状态栏右键「隐藏所有便签」：全部隐藏（含置顶）；空白便签顺带物理回收。
    func hideAll() {
        recycleBlankNotes()
        for note in notes where !note.completed && !note.hidden {
            mutate(note.id) { $0.hidden = true }
        }
        windowPresenter.hideAll()
    }

    /// 窗口拖动 / 缩放回调：更新内存并防抖落库。
    func updateFrame(id: UUID, frame: CGRect) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard notes[index].frame != frame else { return }
        notes[index].frame = frame
        notes[index].updatedAt = now()
        schedulePersist(id: id)
    }

    // MARK: - 提醒

    /// 设置提醒；仅允许未来时间。首次设置时懒申请通知权限（被拒不影响提醒本身）。
    @discardableResult
    func setReminder(id: UUID, date: Date) -> Result<Void, StickyNoteReminderError> {
        guard notes.contains(where: { $0.id == id }) else { return .failure(.noteNotFound) }
        guard date > now() else { return .failure(.pastTime) }
        reminderScheduler.requestAuthorizationIfNeeded()
        // 修改提醒 = 撤销旧通道后重挂。
        clearReminderChannels(id: id)
        mutate(id) { note in
            note.reminderAt = date
            note.reminderFiredAt = nil
        }
        scheduleReminderChannels(id: id, at: date)
        return .success(())
    }

    func clearReminder(id: UUID) {
        clearReminderChannels(id: id)
        mutate(id) { note in
            note.reminderAt = nil
            note.reminderFiredAt = nil
        }
        // 提醒状态变化需刷新便签状态栏（铃铛 / 「提醒已到」）。
        syncWindow(id: id)
    }

    /// 内部定时器到点回调；也作为测试的直接触发入口。重复触发被拒绝（防重）。
    func handleReminderFired(id: UUID) {
        guard let note = notes.first(where: { $0.id == id }),
              note.reminderAt != nil,
              note.reminderFiredAt == nil else { return }
        fireReminder(id: id, at: now())
    }

    // MARK: - 安装 / 卸载生命周期

    /// install 时调用：恢复未完成未隐藏便签的窗口 + 提醒扫描。
    /// 过期未触发的提醒 → 标记已触发并唤起（不补发系统通知，避免开机轰炸）；
    /// 未来提醒 → 重挂定时器 + 重排通知请求。
    func restoreOnInstall() {
        // 误新建未写内容的空白便签先回收，避免其隐藏残留于数据库与管理页。
        recycleBlankNotes()
        for note in notes where !note.completed && !note.hidden {
            windowPresenter.show(note: note)
        }
        let current = now()
        for note in notes {
            guard note.reminderAt != nil, note.reminderFiredAt == nil else { continue }
            if note.completed {
                // 已完成便签的残留提醒（complete 正常路径已清，此处兜底）：清除字段并撤销通道。
                clearReminder(id: note.id)
            } else if let reminderAt = note.reminderAt, reminderAt <= current {
                fireReminder(id: note.id, at: current)
            } else if let reminderAt = note.reminderAt {
                scheduleReminderChannels(id: note.id, at: reminderAt)
            }
        }
    }

    /// teardown：关全部窗口、失效定时器、撤销全部通知请求、注销快捷键。
    func teardown() {
        for task in persistTasks.values {
            task.cancel()
        }
        persistTasks.removeAll()
        isSaving = false
        windowPresenter.dismissAll()
        for note in notes {
            reminderScheduler.cancelTimer(id: note.id)
        }
        reminderScheduler.cancelAllNotifications()
        unregisterHotkey()
    }

    // MARK: - 快捷键（UserDefaults 真源 + 运行时镜像）

    /// 当前「新建便签」快捷键（供 recorder 展示）。
    var hotkey: HotkeyDefinition {
        Self.loadHotkey(from: userDefaults)
    }

    /// recorder 回调：持久化新绑定并按可用性重挂。
    func handleRecorderChange(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard let definition = HotkeyDefinition(shortcut: shortcut) else {
            // 无效 / 清空的录制：恢复已持久化绑定，避免 recorder 显示与真源脱节。
            hotkeyClient.setShortcut(hotkey.keyboardShortcut, for: .stickyNoteNewNote)
            return
        }
        userDefaults.set(definition.keyCode, forKey: UserDefaultsKeys.stickyNoteHotkeyKeyCode)
        userDefaults.set(definition.modifiers.rawValue, forKey: UserDefaultsKeys.stickyNoteHotkeyModifiers)
        objectWillChange.send()
        syncHotkeyWithAvailability()
    }

    /// 功能可用性变化时由 FeatureRuntime bindings / composition root 调用。
    func syncHotkeyWithAvailability() {
        if isFeatureAvailable() {
            registerHotkey()
        } else {
            unregisterHotkey()
        }
    }

    private func registerHotkey() {
        hotkeyClient.setShortcut(hotkey.keyboardShortcut, for: .stickyNoteNewNote)
        isHotkeyListening = true
        guard !hasRegisteredHotkeyOnKeyUpHandler else { return }
        hotkeyClient.onKeyUp(for: .stickyNoteNewNote) { [weak self] in
            Task { @MainActor in
                guard let self, self.isHotkeyListening, self.isFeatureAvailable() else { return }
                self.create()
            }
        }
        hasRegisteredHotkeyOnKeyUpHandler = true
    }

    private func unregisterHotkey() {
        // 注销 = 清运行时镜像并停回调；UserDefaults 真源保留，重新可用时恢复注册。
        isHotkeyListening = false
        hotkeyClient.setShortcut(nil, for: .stickyNoteNewNote)
    }

    static func loadHotkey(from userDefaults: UserDefaults) -> HotkeyDefinition {
        guard userDefaults.object(forKey: UserDefaultsKeys.stickyNoteHotkeyKeyCode) != nil,
              userDefaults.object(forKey: UserDefaultsKeys.stickyNoteHotkeyModifiers) != nil else {
            return .defaultStickyNoteNewNote
        }
        let keyCode = userDefaults.integer(forKey: UserDefaultsKeys.stickyNoteHotkeyKeyCode)
        let modifiersRaw = userDefaults.integer(forKey: UserDefaultsKeys.stickyNoteHotkeyModifiers)
        return HotkeyDefinition(keyCode: keyCode, modifiers: HotkeyModifiers(rawValue: modifiersRaw))
    }

    // MARK: - private

    /// 物理回收未完成的空白便签（先取 ID 再删，避免遍历中变动 notes）。
    private func recycleBlankNotes() {
        for id in notes.filter({ !$0.completed && $0.isBlank }).map(\.id) {
            delete(id: id)
        }
    }

    /// 唤起到屏幕上方安全位置并标记已触发；已完成便签只落标记不唤起（4.7）。
    private func fireReminder(id: UUID, at firedAt: Date) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.reminderFiredAt = firedAt
        note.updatedAt = firedAt
        if !note.completed {
            note.hidden = false
            note.frame = awakenFrame(for: note)
        }
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index] = note
        }
        store.saveNote(note)
        if !note.completed {
            windowPresenter.show(note: note)
            windowPresenter.bringToFront(id: id)
        }
    }

    /// 唤起位置：便签当前所在屏（判定完全包含）的上方居中，无匹配屏时主屏。
    private func awakenFrame(for note: StickyNote) -> CGRect {
        let screens = visibleScreensProvider()
        let current = note.frame
        let target = screens.first { StickyNoteGeometry.isFullyContained(current, in: [$0]) }
            ?? screens.first
        guard let target else { return current }
        return StickyNoteGeometry.awakenFrame(size: current.size, on: target)
    }

    /// 挂双通道：内部定时器（唤起）+ 系统通知（横幅）。
    private func scheduleReminderChannels(id: UUID, at date: Date) {
        reminderScheduler.scheduleTimer(id: id, at: date) { [weak self] in
            self?.handleReminderFired(id: id)
        }
        guard let note = notes.first(where: { $0.id == id }) else { return }
        reminderScheduler.scheduleNotification(
            id: id,
            title: stringsProvider().stickyNoteNotificationTitle,
            body: notificationBody(for: note),
            at: date
        )
    }

    private func clearReminderChannels(id: UUID) {
        reminderScheduler.cancelTimer(id: id)
        reminderScheduler.cancelNotification(id: id)
    }

    private func notificationBody(for note: StickyNote) -> String {
        let summary = note.summary
        guard !summary.isEmpty else { return stringsProvider().stickyNotePlaceholder }
        return String(summary.prefix(80))
    }

    /// 单条更新内存 + 立即落库的统一入口。
    private func mutate(_ id: UUID, _ transform: (inout StickyNote) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        transform(&note)
        note.updatedAt = now()
        notes[index] = note
        store.saveNote(note)
    }

    /// 将最新状态同步到窗口（颜色换肤 / 置顶层级 / 正文等）。
    private func syncWindow(id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        if note.completed || note.hidden {
            windowPresenter.hide(id: id)
        } else {
            windowPresenter.show(note: note)
        }
    }

    private func schedulePersist(id: UUID) {
        persistTasks[id]?.cancel()
        let delay = persistDebounce
        persistTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPersist(id: id)
        }
    }

    private func flushPersist(id: UUID) {
        persistTasks[id] = nil
        guard let note = notes.first(where: { $0.id == id }) else { return }
        store.saveNote(note)
        // 落库后同步窗口，驱动状态栏「保存中…」复位。
        syncWindow(id: id)
        updateSavingIndicator()
    }

    private func updateSavingIndicator() {
        if persistTasks.isEmpty {
            isSaving = false
        }
    }
}
