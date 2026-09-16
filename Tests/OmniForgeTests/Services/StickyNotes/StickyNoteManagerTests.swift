import XCTest
@testable import OmniForge
import KeyboardShortcuts

@MainActor
final class StickyNoteManagerTests: XCTestCase {
    /// 固定「当前时间」：2027-01-15 12:00 UTC。
    private let nowDate = Date(timeIntervalSince1970: 1_800_000_000)
    /// 1920×1045 主屏可视区（AppKit 全局坐标）。
    private let screens = [CGRect(x: 0, y: 0, width: 1920, height: 1045)]

    private var store: FakeStickyNoteStore!
    private var scheduler: FakeReminderScheduler!
    private var presenter: FakeStickyNotePresenter!
    private var hotkeyClient: FakeStickyNoteHotkeyClient!
    private var isFeatureAvailable = true
    private var userDefaults: UserDefaults!
    private var defaultsSuiteName = ""

    override func setUp() {
        super.setUp()
        store = FakeStickyNoteStore()
        scheduler = FakeReminderScheduler()
        presenter = FakeStickyNotePresenter()
        hotkeyClient = FakeStickyNoteHotkeyClient()
        isFeatureAvailable = true
        defaultsSuiteName = "StickyNoteManagerTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - teardown flush（审查 R12：防抖不再是退出丢数据窗口）

    /// 编辑后立即 teardown（不等防抖）：最新内容必须同步落库。
    func test_teardownFlushesPendingEditsImmediately() {
        let manager = makeManager()
        let note = manager.create()!

        manager.updateContent(id: note.id, content: "退出前最后编辑")
        let allSaved = manager.teardown()

        XCTAssertTrue(allSaved)
        let saved = store.savedNotes.first { $0.id == note.id }
        XCTAssertEqual(saved?.content, "退出前最后编辑", "teardown 同步 flush 待保存正文")
    }

    /// flush 保存失败：teardown 返回 false，不得清成成功。
    func test_teardownPersistFailureReturnsFalse() {
        let manager = makeManager()
        let note = manager.create()!

        store.saveError = GRDBStickyNoteStore.StoreError.databaseUnavailable
        manager.updateContent(id: note.id, content: "会丢的内容")
        let allSaved = manager.teardown()

        XCTAssertFalse(allSaved, "保存失败不得报告成功")
        XCTAssertNotNil(manager.lastPersistError, "失败必须可观察")
    }

    /// dirty 标记后条目被删除：flush 跳过（不得复活已删除便签）。
    func test_teardownSkipsDeletedDirtyNotes() {
        let manager = makeManager()
        let note = manager.create()!

        manager.updateContent(id: note.id, content: "马上删")
        manager.delete(id: note.id)
        store.resetRecording()
        let allSaved = manager.teardown()

        XCTAssertTrue(allSaved)
        XCTAssertTrue(store.savedNotes.filter { $0.id == note.id }.isEmpty, "已删除条目不得被 flush 复活")
    }

    private func makeManager() -> StickyNoteManager {
        StickyNoteManager(
            store: store,
            reminderScheduler: scheduler,
            windowPresenter: presenter,
            hotkeyClient: hotkeyClient,
            userDefaults: userDefaults,
            isFeatureAvailable: { [weak self] in self?.isFeatureAvailable ?? false },
            visibleScreensProvider: { [screens] in screens },
            stringsProvider: { .en },
            now: { [nowDate] in nowDate },
            persistDebounce: 0.05
        )
    }

    // MARK: - 1 新建

    func test_create_setsDefaultFieldsPersistsAndShows() {
        let manager = makeManager()

        let note = manager.create()

        XCTAssertNotNil(note)
        XCTAssertEqual(note?.color, .yellow)
        XCTAssertEqual(note?.pinned, false)
        XCTAssertEqual(note?.hidden, false)
        XCTAssertEqual(note?.completed, false)
        XCTAssertEqual(note?.width, StickyNoteGeometry.defaultSize.width)
        XCTAssertEqual(note?.height, StickyNoteGeometry.defaultSize.height)
        XCTAssertEqual(manager.notes.count, 1)
        XCTAssertEqual(store.savedNotes.count, 1)
        XCTAssertEqual(presenter.shownNotes.count, 1)
    }

    func test_create_cascadesFromMostRecentlyCreated() {
        let manager = makeManager()
        let first = manager.create()!

        let second = manager.create()!

        XCTAssertEqual(second.x, first.x + 28, accuracy: 0.001)
        XCTAssertEqual(second.y, first.y - 28, accuracy: 0.001)
    }

    func test_create_cascadeBeyondScreensFallsBackToDefaultPosition() {
        // 预置最近便签贴主屏右缘：级联候选必越界 → 回落主屏默认位置（左上角）。
        store.stubbedNotes = [
            StickyNote(
                content: "旧",
                color: .blue,
                x: 1700,
                y: 800,
                width: 320,
                height: 260,
                createdAt: nowDate.addingTimeInterval(-60),
                updatedAt: nowDate.addingTimeInterval(-60)
            )
        ]
        let manager = makeManager()

        let created = manager.create()!

        XCTAssertEqual(created.x, screens[0].minX + 16, accuracy: 0.001)
        XCTAssertEqual(created.y, screens[0].maxY - 260 - 16, accuracy: 0.001)
    }

    func test_create_inheritsMostRecentlyUsedColor() {
        store.stubbedNotes = [
            StickyNote(
                content: "粉色便签",
                color: .pink,
                createdAt: nowDate.addingTimeInterval(-60),
                updatedAt: nowDate.addingTimeInterval(-60)
            )
        ]
        let manager = makeManager()

        let created = manager.create()!

        XCTAssertEqual(created.color, .pink)
    }

    // MARK: - 2 编辑防抖与状态更新

    func test_updateContent_updatesMemoryImmediatelyAndDebouncesPersist() async throws {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()

        manager.updateContent(id: note.id, content: "第一句")
        XCTAssertTrue(manager.isSaving)
        XCTAssertEqual(manager.notes[0].content, "第一句")
        manager.updateContent(id: note.id, content: "第一句第二句")

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(store.savedNotes.count, 1)
        XCTAssertEqual(store.savedNotes[0].content, "第一句第二句")
        XCTAssertFalse(manager.isSaving)
    }

    func test_setColor_togglesPin_updateRoundTripAndSyncWindow() {
        let manager = makeManager()
        let note = manager.create()!
        presenter.resetRecording()

        manager.setColor(id: note.id, color: .mint)
        manager.togglePin(id: note.id)

        XCTAssertEqual(manager.notes[0].color, .mint)
        XCTAssertTrue(manager.notes[0].pinned)
        XCTAssertEqual(store.savedNotes.last?.color, .mint)
        XCTAssertTrue(store.savedNotes.last?.pinned ?? false)
        XCTAssertEqual(presenter.shownNotes.count, 2)
        XCTAssertEqual(presenter.shownNotes.last?.color, .mint)
        XCTAssertEqual(presenter.shownNotes.last?.pinned, true)
    }

    func test_updateFrame_updatesAndDebouncesPersist() async throws {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()

        manager.updateFrame(id: note.id, frame: CGRect(x: 10, y: 20, width: 400, height: 300))
        XCTAssertEqual(manager.notes[0].x, 10)
        XCTAssertEqual(manager.notes[0].width, 400)

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.savedNotes.count, 1)
        XCTAssertEqual(store.savedNotes[0].height, 300)
    }

    // MARK: - 3 收起 / 完成 / 恢复

    func test_showAll_restoresOnlyUncompletedNotes() {
        store.stubbedNotes = [
            StickyNote(
                content: "已完成且隐藏",
                hidden: true,
                completed: true,
                createdAt: nowDate.addingTimeInterval(-30),
                updatedAt: nowDate.addingTimeInterval(-30)
            )
        ]
        let manager = makeManager()
        let active = manager.create()!
        // 空白便签会被 hideAll 顺带回收，本用例聚焦隐藏语义，先写入内容。
        manager.updateContent(id: active.id, content: "进行中")
        manager.hideAll()
        presenter.resetRecording()

        manager.showAll()

        XCTAssertEqual(manager.notes.first(where: { $0.id == active.id })?.hidden, false)
        XCTAssertEqual(manager.notes.first(where: { $0.content == "已完成且隐藏" })?.hidden, true)
        XCTAssertEqual(presenter.shownNotes.map(\.id), [active.id])
        // 已完成便签既不显示也不前置
        let completedID = manager.notes.first(where: { $0.content == "已完成且隐藏" })!.id
        XCTAssertFalse(presenter.frontedIDs.contains(completedID))
        XCTAssertFalse(presenter.shownNotes.contains { $0.id == completedID })
    }

    func test_showAll_bringToFrontVisibleNotes() {
        let manager = makeManager()
        let first = manager.create()!
        let second = manager.create()!
        presenter.resetRecording()

        manager.showAll()

        // 可见但被其他窗口盖住的便签：不重走 show，直接前置
        XCTAssertTrue(presenter.shownNotes.isEmpty)
        XCTAssertEqual(presenter.frontedIDs, [first.id, second.id])
    }

    func test_uncomplete_clearsHiddenAndShows() {
        let manager = makeManager()
        let note = manager.create()!
        manager.updateContent(id: note.id, content: "待办")
        manager.complete(id: note.id)
        presenter.resetRecording()

        manager.uncomplete(id: note.id)

        XCTAssertEqual(manager.notes[0].completed, false)
        XCTAssertEqual(manager.notes[0].hidden, false)
        XCTAssertEqual(presenter.shownNotes.map(\.id), [note.id])
        XCTAssertEqual(presenter.frontedIDs, [note.id])
    }

    func test_setCollapse_keepsWindowVisibleAndPersistsCollapsed() {
        let manager = makeManager()
        let note = manager.create()!
        presenter.resetRecording()

        manager.setCollapse(id: note.id, collapsed: true)

        // 折叠 = 正文收起为工具栏条：窗口仍可见（不隐藏），状态独立于 hidden 落库
        XCTAssertEqual(manager.notes[0].collapsed, true)
        XCTAssertEqual(manager.notes[0].hidden, false)
        XCTAssertTrue(presenter.hiddenIDs.isEmpty)
        XCTAssertEqual(store.savedNotes.last?.collapsed, true)
        // 折叠不改尺寸：frame 恒存展开态
        XCTAssertEqual(manager.notes[0].height, StickyNoteGeometry.defaultSize.height)
    }

    func test_toggleCollapse_flipsCollapsedState() {
        let manager = makeManager()
        let note = manager.create()!

        manager.toggleCollapse(id: note.id)
        XCTAssertEqual(manager.notes[0].collapsed, true)
        manager.toggleCollapse(id: note.id)
        XCTAssertEqual(manager.notes[0].collapsed, false)
    }

    // MARK: - 3.1 字号档位（工具栏 Aa 面板）

    func test_create_defaultsToStandardFontSize() {
        let manager = makeManager()

        let note = manager.create()!

        XCTAssertEqual(note.fontSize, StickyNote.defaultFontSize)
    }

    func test_setFontSize_updatesPersistsAndSyncsWindow() {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()
        presenter.resetRecording()

        manager.setFontSize(id: note.id, fontSize: 20)

        XCTAssertEqual(manager.notes[0].fontSize, 20)
        XCTAssertEqual(store.savedNotes.last?.fontSize, 20)
        XCTAssertEqual(presenter.shownNotes.last?.fontSize, 20, "字号变化需同步窗口刷新 NSTextView")
    }

    func test_setFontSize_sameLevelOrInvalidValue_isNoop() {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()

        manager.setFontSize(id: note.id, fontSize: StickyNote.defaultFontSize)
        manager.setFontSize(id: note.id, fontSize: 14)  // 非档位值
        manager.setFontSize(id: note.id, fontSize: 99)  // 非档位值

        XCTAssertEqual(manager.notes[0].fontSize, StickyNote.defaultFontSize)
        XCTAssertEqual(store.saveCallCount, 0, "同档重复设置与非法档位值均不落库")
    }

    /// 新建走聚焦呈现：显示窗口并聚焦正文，新建后可直接输入。
    func test_create_presentsWithFocus() {
        let manager = makeManager()

        let note = manager.create()!

        XCTAssertEqual(presenter.focusedNotes.count, 1, "新建必须走 showAndFocus 聚焦正文")
        XCTAssertEqual(presenter.focusedNotes.first?.id, note.id)
    }

    /// 启动恢复等普通 show 路径不得抢焦点：未隐藏存量只前置、不触发聚焦呈现。
    func test_showAll_restoresWithoutFocus() {
        store.stubbedNotes = [StickyNote(content: "存量", color: .yellow)]
        let manager = makeManager()

        manager.showAll()

        XCTAssertTrue(presenter.focusedNotes.isEmpty, "恢复显示不聚焦，避免批量抢焦点")
        XCTAssertEqual(presenter.frontedIDs.count, 1)
    }

    // MARK: - 3.2 行高档位（工具栏 Aa 面板）

    func test_create_defaultsToDefaultLineHeight() {
        let manager = makeManager()

        let note = manager.create()!

        XCTAssertEqual(note.lineHeight, StickyNote.defaultLineHeight)
    }

    func test_setLineHeight_updatesPersistsAndSyncsWindow() {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()
        presenter.resetRecording()

        manager.setLineHeight(id: note.id, lineHeight: 1.5)

        XCTAssertEqual(manager.notes[0].lineHeight, 1.5)
        XCTAssertEqual(store.savedNotes.last?.lineHeight, 1.5)
        XCTAssertEqual(presenter.shownNotes.last?.lineHeight, 1.5, "行高变化需同步窗口刷新 NSTextView")
    }

    func test_setLineHeight_sameLevelOrInvalidValue_isNoop() {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()

        manager.setLineHeight(id: note.id, lineHeight: StickyNote.defaultLineHeight)
        manager.setLineHeight(id: note.id, lineHeight: 1.3)  // 非档位值
        manager.setLineHeight(id: note.id, lineHeight: 3)    // 非档位值

        XCTAssertEqual(manager.notes[0].lineHeight, StickyNote.defaultLineHeight)
        XCTAssertEqual(store.saveCallCount, 0, "同档重复设置与非法档位值均不落库")
    }

    // MARK: - 3.3 默认排版持久化（最后使用即默认，新建便签继承，重启保留）

    /// 调整某张便签字号后，之后新建的便签继承该字号。
    func test_setFontSize_becomesDefaultForNewNotes() {
        let manager = makeManager()
        let first = manager.create()!

        manager.setFontSize(id: first.id, fontSize: 20)
        let second = manager.create()!

        XCTAssertEqual(second.fontSize, 20, "新建便签须沿用最近调整的字号")
        XCTAssertEqual(second.lineHeight, StickyNote.defaultLineHeight, "未调整过的行高保持默认")
    }

    /// 调整某张便签行高后，之后新建的便签继承该行高。
    func test_setLineHeight_becomesDefaultForNewNotes() {
        let manager = makeManager()
        let first = manager.create()!

        manager.setLineHeight(id: first.id, lineHeight: 1.8)
        let second = manager.create()!

        XCTAssertEqual(second.lineHeight, 1.8, "新建便签须沿用最近调整的行高")
        XCTAssertEqual(second.fontSize, StickyNote.defaultFontSize, "未调整过的字号保持默认")
    }

    /// 新 Manager 实例（模拟应用重启）读到同一 UserDefaults：默认排版仍然生效。
    func test_defaultTypography_survivesManagerRecreation() {
        let firstManager = makeManager()
        let note = firstManager.create()!
        firstManager.setFontSize(id: note.id, fontSize: 17)
        firstManager.setLineHeight(id: note.id, lineHeight: 1.5)

        let secondManager = makeManager()
        let revived = secondManager.create()!

        XCTAssertEqual(revived.fontSize, 17, "重启后新建便签须继承持久化字号")
        XCTAssertEqual(revived.lineHeight, 1.5, "重启后新建便签须继承持久化行高")
    }

    /// 持久化值不在档位表内（旧版本残留 / 档位表调整）：回落静态默认，不得直接采用。
    func test_defaultTypography_invalidStoredValues_fallBackToStaticDefaults() {
        userDefaults.set(14.0, forKey: UserDefaultsKeys.stickyNoteDefaultFontSize)  // 非档位
        userDefaults.set(1.3, forKey: UserDefaultsKeys.stickyNoteDefaultLineHeight)  // 非档位
        let manager = makeManager()

        let note = manager.create()!

        XCTAssertEqual(note.fontSize, StickyNote.defaultFontSize)
        XCTAssertEqual(note.lineHeight, StickyNote.defaultLineHeight)
    }

    /// 调整默认值只影响之后新建的便签：存量便签的字号 / 行高保持不变。
    func test_setFontSize_doesNotRewriteExistingNotes() {
        let manager = makeManager()
        let first = manager.create()!
        let second = manager.create()!

        manager.setFontSize(id: second.id, fontSize: 24)

        XCTAssertEqual(manager.notes.first { $0.id == first.id }?.fontSize, StickyNote.defaultFontSize,
                       "存量便签字号不得被默认值变化改写")
        XCTAssertEqual(store.savedNotes.filter { $0.id == first.id }.last?.fontSize,
                       StickyNote.defaultFontSize,
                       "存量便签落库记录不得被默认值变化改写")
    }

    func test_complete_overridesCollapseAndHidesWindow() {
        let manager = makeManager()
        let note = manager.create()!
        manager.updateContent(id: note.id, content: "折叠中的待办")
        manager.setCollapse(id: note.id, collapsed: true)
        presenter.resetRecording()

        manager.complete(id: note.id)

        // 完成优先于折叠：隐藏窗口，折叠状态原样保留（下次恢复显示时仍是折叠条）
        XCTAssertEqual(manager.notes[0].completed, true)
        XCTAssertEqual(manager.notes[0].hidden, true)
        XCTAssertEqual(manager.notes[0].collapsed, true)
        XCTAssertEqual(presenter.hiddenIDs, [note.id])
    }

    func test_complete_marksCompletedHiddenClearsReminderAndCancelsChannels() {
        let manager = makeManager()
        let note = manager.create()!
        manager.updateContent(id: note.id, content: "有内容的待办")
        manager.setReminder(id: note.id, date: nowDate.addingTimeInterval(3600))
        scheduler.resetRecording()
        scheduler.resetRecording()

        manager.complete(id: note.id)

        XCTAssertEqual(manager.notes[0].completed, true)
        XCTAssertEqual(manager.notes[0].hidden, true)
        XCTAssertNil(manager.notes[0].reminderAt)
        XCTAssertEqual(scheduler.cancelledTimerIDs, [note.id])
        XCTAssertTrue(scheduler.cancelledNotificationIDs.contains(StickyNoteReminderRequestID.make(for: note.id)))
        XCTAssertEqual(presenter.hiddenIDs, [note.id])
    }

    // MARK: - 4 提醒设置

    func test_setReminder_withPastDateIsRejectedWithoutScheduling() {
        let manager = makeManager()
        let note = manager.create()!

        let result = manager.setReminder(id: note.id, date: nowDate.addingTimeInterval(-1))

        guard case .failure(.pastTime) = result else {
            return XCTFail("期望过去时间被拒绝，实际 \(result)")
        }
        XCTAssertTrue(scheduler.notifications.isEmpty)
        XCTAssertTrue(scheduler.timers.isEmpty)
        XCTAssertNil(manager.notes[0].reminderAt)
    }

    func test_setReminder_schedulesNotificationAndTimer() {
        let manager = makeManager()
        let note = manager.create()!
        let fireDate = nowDate.addingTimeInterval(900)

        let result = manager.setReminder(id: note.id, date: fireDate)

        guard case .success = result else {
            return XCTFail("期望设置成功，实际 \(result)")
        }
        XCTAssertEqual(manager.notes[0].reminderAt, fireDate)
        XCTAssertEqual(scheduler.timers[note.id]?.at, fireDate)
        let requestID = StickyNoteReminderRequestID.make(for: note.id)
        XCTAssertEqual(scheduler.notifications[requestID]?.at, fireDate)
        XCTAssertEqual(scheduler.notifications[requestID]?.title, Strings.en.stickyNoteNotificationTitle)
        XCTAssertEqual(scheduler.authorizationRequestCount, 1)
    }

    func test_setReminder_twiceCancelsOldRequestBeforeRescheduling() {
        let manager = makeManager()
        let note = manager.create()!
        let first = nowDate.addingTimeInterval(600)
        let second = nowDate.addingTimeInterval(1200)
        _ = manager.setReminder(id: note.id, date: first)

        _ = manager.setReminder(id: note.id, date: second)

        let requestID = StickyNoteReminderRequestID.make(for: note.id)
        XCTAssertTrue(scheduler.cancelledNotificationIDs.contains(requestID))
        XCTAssertEqual(scheduler.notifications[requestID]?.at, second)
        XCTAssertEqual(scheduler.timers[note.id]?.at, second)
    }

    func test_clearReminder_cancelsTimerAndNotification() {
        let manager = makeManager()
        let note = manager.create()!
        _ = manager.setReminder(id: note.id, date: nowDate.addingTimeInterval(600))
        scheduler.resetRecording()
        scheduler.resetRecording()

        manager.clearReminder(id: note.id)

        XCTAssertNil(manager.notes[0].reminderAt)
        XCTAssertNil(manager.notes[0].reminderFiredAt)
        XCTAssertEqual(scheduler.cancelledTimerIDs, [note.id])
        XCTAssertEqual(
            scheduler.cancelledNotificationIDs,
            [StickyNoteReminderRequestID.make(for: note.id)]
        )
    }

    // MARK: - 5 到点行为

    func test_handleReminderFired_marksFiredRestoresHiddenNoteAndMovesToTop() {
        let manager = makeManager()
        let note = manager.create()!
        manager.updateContent(id: note.id, content: "提醒事项")
        manager.hideAll()
        _ = manager.setReminder(id: note.id, date: nowDate.addingTimeInterval(60))
        presenter.resetRecording()

        scheduler.fireTimer(id: note.id)

        let updated = manager.notes[0]
        XCTAssertNotNil(updated.reminderFiredAt)
        XCTAssertEqual(updated.hidden, false)
        XCTAssertTrue(updated.isReminderFired)
        // 唤起位置：屏幕上方居中（顶部留 16pt 边距）
        XCTAssertEqual(updated.y + updated.height, screens[0].maxY - 16, accuracy: 0.001)
        XCTAssertEqual(updated.x + updated.width / 2, screens[0].midX, accuracy: 0.001)
        XCTAssertEqual(presenter.shownNotes.map(\.id), [note.id])
        XCTAssertEqual(presenter.frontedIDs, [note.id])
    }

    func test_handleReminderFired_firesOnlyOnce() {
        let manager = makeManager()
        let note = manager.create()!
        _ = manager.setReminder(id: note.id, date: nowDate.addingTimeInterval(60))
        presenter.resetRecording()

        scheduler.fireTimer(id: note.id)
        let firedAt = manager.notes[0].reminderFiredAt
        scheduler.fireTimer(id: note.id)

        XCTAssertEqual(manager.notes[0].reminderFiredAt, firedAt)
        XCTAssertEqual(presenter.shownNotes.count, 1)
    }

    // MARK: - 6 重启恢复

    func test_restoreOnInstall_expiredUnfiredReminderMarksAndAwakensWithoutNotification() {
        let expired = StickyNote(
            content: "过期提醒",
            x: 100,
            y: 100,
            width: 320,
            height: 260,
            hidden: true,
            reminderAt: nowDate.addingTimeInterval(-3600),
            createdAt: nowDate.addingTimeInterval(-7200),
            updatedAt: nowDate.addingTimeInterval(-7200)
        )
        store.stubbedNotes = [expired]
        let manager = makeManager()

        manager.restoreOnInstall()

        let restored = manager.notes[0]
        XCTAssertNotNil(restored.reminderFiredAt)
        XCTAssertEqual(restored.hidden, false)
        XCTAssertTrue(scheduler.notifications.isEmpty, "过期提醒不得补发系统通知")
        XCTAssertEqual(presenter.shownNotes.map(\.id), [expired.id])
        // 唤起到屏幕上方
        XCTAssertEqual(restored.y + restored.height, screens[0].maxY - 16, accuracy: 0.001)
    }

    func test_restoreOnInstall_futureReminderReschedulesTimerAndNotification() {
        let future = StickyNote(
            content: "未来提醒",
            reminderAt: nowDate.addingTimeInterval(1800),
            createdAt: nowDate.addingTimeInterval(-60),
            updatedAt: nowDate.addingTimeInterval(-60)
        )
        store.stubbedNotes = [future]
        let manager = makeManager()

        manager.restoreOnInstall()

        XCTAssertEqual(scheduler.timers[future.id]?.at, future.reminderAt)
        let requestID = StickyNoteReminderRequestID.make(for: future.id)
        XCTAssertEqual(scheduler.notifications[requestID]?.at, future.reminderAt)
    }

    func test_restoreOnInstall_completedNoteWithResidualReminder_clearsIt() {
        // complete() 正常路径会清提醒；此用例覆盖历史/异常数据的兜底。
        store.stubbedNotes = [
            StickyNote(
                content: "已完成残留提醒",
                hidden: true,
                completed: true,
                reminderAt: nowDate.addingTimeInterval(1800),
                createdAt: nowDate.addingTimeInterval(-60),
                updatedAt: nowDate.addingTimeInterval(-60)
            )
        ]
        let manager = makeManager()

        manager.restoreOnInstall()

        XCTAssertNil(manager.notes[0].reminderAt, "已完成便签的残留提醒应被清除")
        XCTAssertTrue(scheduler.notifications.isEmpty, "不得为已完成便签重挂通知")
        XCTAssertTrue(scheduler.timers.isEmpty, "不得为已完成便签重挂定时器")
    }

    func test_restoreOnInstall_showsOnlyVisibleUncompletedNotes() {
        store.stubbedNotes = [
            StickyNote(content: "可见", createdAt: nowDate.addingTimeInterval(-90), updatedAt: nowDate),
            StickyNote(content: "隐藏", hidden: true, createdAt: nowDate.addingTimeInterval(-80), updatedAt: nowDate),
            StickyNote(content: "完成", completed: true, createdAt: nowDate.addingTimeInterval(-70), updatedAt: nowDate)
        ]
        let manager = makeManager()

        manager.restoreOnInstall()

        XCTAssertEqual(presenter.shownNotes.map(\.content), ["可见"])
    }

    // MARK: - 7 删除

    func test_delete_removesNoteCancelsChannelsAndDismissesWindow() {
        let manager = makeManager()
        let note = manager.create()!
        _ = manager.setReminder(id: note.id, date: nowDate.addingTimeInterval(600))
        scheduler.resetRecording()
        scheduler.resetRecording()

        manager.delete(id: note.id)

        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertEqual(store.deletedIDs, [note.id])
        XCTAssertEqual(scheduler.cancelledTimerIDs, [note.id])
        XCTAssertEqual(
            scheduler.cancelledNotificationIDs,
            [StickyNoteReminderRequestID.make(for: note.id)]
        )
        XCTAssertEqual(presenter.dismissedIDs, [note.id])
    }

    // MARK: - 7.1 空白便签回收（误新建治理）

    func test_complete_blankNotePhysicallyDeletesInsteadOfArchiving() {
        let manager = makeManager()
        let note = manager.create()!  // 快捷键误新建：内容为空

        manager.complete(id: note.id)

        // 完成退化为物理删除：不进已完成归档，数据与窗口一并移除
        XCTAssertTrue(manager.notes.isEmpty)
        XCTAssertEqual(store.deletedIDs, [note.id])
        XCTAssertEqual(presenter.dismissedIDs, [note.id])
    }

    func test_complete_whitespaceOnlyNoteAlsoDeletes() {
        let manager = makeManager()
        let note = manager.create()!
        manager.updateContent(id: note.id, content: "  \n\t ")

        manager.complete(id: note.id)

        XCTAssertTrue(manager.notes.isEmpty, "空白字符内容同样视为空白便签")
        XCTAssertEqual(store.deletedIDs, [note.id])
    }

    func test_complete_noteWithContentStillArchives() {
        let manager = makeManager()
        let note = manager.create()!
        manager.updateContent(id: note.id, content: "真实待办")
        presenter.resetRecording()

        manager.complete(id: note.id)

        XCTAssertEqual(manager.notes.count, 1)
        XCTAssertEqual(manager.notes[0].completed, true)
        XCTAssertEqual(store.deletedIDs, [])
        XCTAssertEqual(presenter.hiddenIDs, [note.id])
    }

    func test_hideAll_recyclesBlankActiveNotesButKeepsContentOnes() {
        let manager = makeManager()
        let blank = manager.create()!
        let content = manager.create()!
        manager.updateContent(id: content.id, content: "保留我")
        store.resetRecording()

        manager.hideAll()

        // 空白便签被物理回收；有内容便签仅隐藏
        XCTAssertEqual(manager.notes.map(\.id), [content.id])
        XCTAssertEqual(store.deletedIDs, [blank.id])
        XCTAssertEqual(manager.notes[0].hidden, true)
        XCTAssertEqual(presenter.dismissedIDs, [blank.id])
        XCTAssertEqual(presenter.hideAllCount, 1)
    }

    func test_restoreOnInstall_recyclesBlankNotesAndShowsContentOnes() {
        store.stubbedNotes = [
            StickyNote(content: "", hidden: true, createdAt: nowDate.addingTimeInterval(-90), updatedAt: nowDate),
            StickyNote(content: "  ", createdAt: nowDate.addingTimeInterval(-80), updatedAt: nowDate),
            StickyNote(content: "可见", createdAt: nowDate.addingTimeInterval(-70), updatedAt: nowDate)
        ]
        let manager = makeManager()

        manager.restoreOnInstall()

        // 空白便签（含隐藏残留与纯空白字符）重启即回收，只剩有内容便签
        XCTAssertEqual(manager.notes.map(\.content), ["可见"])
        XCTAssertEqual(store.deletedIDs.count, 2)
        XCTAssertEqual(presenter.shownNotes.map(\.content), ["可见"])
    }

    // MARK: - 7.2 清空已完成

    func test_deleteCompleted_removesAllCompletedAndKeepsActive() {
        store.stubbedNotes = [
            StickyNote(
                content: "已完成 1", completed: true,
                createdAt: nowDate.addingTimeInterval(-90), updatedAt: nowDate.addingTimeInterval(-30)
            ),
            StickyNote(
                content: "已完成 2", hidden: true, completed: true,
                createdAt: nowDate.addingTimeInterval(-80), updatedAt: nowDate.addingTimeInterval(-20)
            ),
            StickyNote(content: "进行中", createdAt: nowDate.addingTimeInterval(-70), updatedAt: nowDate)
        ]
        let manager = makeManager()

        manager.deleteCompleted()

        XCTAssertEqual(manager.notes.map(\.content), ["进行中"])
        XCTAssertEqual(Set(store.deletedIDs), Set(store.stubbedNotes.filter(\.completed).map(\.id)))
    }

    // MARK: - 8 快捷键

    func test_syncHotkey_registersMirrorWhenAvailableAndClearsWhenUnavailable() {
        let manager = makeManager()

        manager.syncHotkeyWithAvailability()
        XCTAssertEqual(hotkeyClient.setShortcutCalls.compactMap(\.self).count, 1, "可用时挂运行时镜像")

        isFeatureAvailable = false
        manager.syncHotkeyWithAvailability()
        guard let lastCall = hotkeyClient.setShortcutCalls.last else {
            return XCTFail("缺少第二次 setShortcut 调用")
        }
        XCTAssertNil(lastCall, "不可用时清运行时镜像")
    }

    func test_hotkeyKeyUp_createsNoteOnlyWhenFeatureAvailable() async throws {
        let manager = makeManager()
        manager.syncHotkeyWithAvailability()

        hotkeyClient.fireKeyUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.notes.count, 1)

        isFeatureAvailable = false
        manager.syncHotkeyWithAvailability()
        hotkeyClient.fireKeyUp()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.notes.count, 1, "功能不可用时快捷键不新建")
    }

    func test_handleRecorderChange_persistsAndReRegisters() {
        let manager = makeManager()
        manager.syncHotkeyWithAvailability()

        manager.handleRecorderChange(
            KeyboardShortcuts.Shortcut(carbonKeyCode: 40, carbonModifiers: HotkeyModifiers.option.carbonModifiers)
        )

        XCTAssertEqual(
            userDefaults.integer(forKey: UserDefaultsKeys.stickyNoteHotkeyKeyCode), 40
        )
        let lastShortcut = hotkeyClient.setShortcutCalls.last.flatMap { $0 }
        XCTAssertEqual(lastShortcut?.carbonKeyCode, 40)
    }

    // MARK: - teardown

    func test_teardown_closesWindowsCancelsAllNotificationsAndUnregistersHotkey() {
        let manager = makeManager()
        manager.create()
        manager.syncHotkeyWithAvailability()

        manager.teardown()

        XCTAssertEqual(presenter.dismissAllCount, 1)
        XCTAssertEqual(scheduler.cancelAllNotificationsCount, 1)
        guard let lastCall = hotkeyClient.setShortcutCalls.last else {
            return XCTFail("缺少注销快捷键调用")
        }
        XCTAssertNil(lastCall)
    }
}

// MARK: - Fakes

private final class FakeStickyNoteStore: StickyNoteStore {
    var stubbedNotes: [StickyNote] = []
    private(set) var savedNotes: [StickyNote] = []  // internal write via resetRecording
    /// saveNote 调用次数；savedNotes 为 upsert 替换语义，不反映次数。
    private(set) var saveCallCount = 0
    private(set) var deletedIDs: [UUID] = []

    /// 清空调用记录（保留 stub 数据）。
    func resetRecording() {
        savedNotes = []
        saveCallCount = 0
        deletedIDs = []
    }

    /// 置非 nil 时 saveNote 抛错（失败路径注入）。
    var saveError: Error?

    func loadNotes() -> [StickyNote] { stubbedNotes }

    func saveNote(_ note: StickyNote) throws {
        if let saveError {
            throw saveError
        }
        saveCallCount += 1
        if let index = savedNotes.firstIndex(where: { $0.id == note.id }) {
            savedNotes[index] = note
        } else {
            savedNotes.append(note)
        }
    }

    func deleteNote(id: UUID) {
        deletedIDs.append(id)
        savedNotes.removeAll { $0.id == id }
    }

    func releaseMemory() {}
}

private final class FakeReminderScheduler: StickyNoteReminderScheduling {
    struct TimerEntry {
        let id: UUID
        let at: Date
        let fire: () -> Void
    }

    var timers: [UUID: TimerEntry] = [:]
    var notifications: [String: (id: UUID, title: String, body: String, at: Date)] = [:]
    var cancelledTimerIDs: [UUID] = []
    var cancelledNotificationIDs: [String] = []
    private(set) var cancelAllNotificationsCount = 0
    private(set) var authorizationRequestCount = 0

    /// 清空调用记录（保留已挂载的定时器与通知）。
    func resetRecording() {
        cancelledTimerIDs = []
        cancelledNotificationIDs = []
    }

    func scheduleTimer(id: UUID, at date: Date, fire: @escaping () -> Void) {
        timers[id] = TimerEntry(id: id, at: date, fire: fire)
    }

    /// 测试直接触发定时器（绕过真实等待）。
    func fireTimer(id: UUID) {
        timers[id]?.fire()
        timers[id] = nil
    }

    func cancelTimer(id: UUID) {
        cancelledTimerIDs.append(id)
        timers[id] = nil
    }

    func scheduleNotification(id: UUID, title: String, body: String, at date: Date) {
        notifications[StickyNoteReminderRequestID.make(for: id)] = (id, title, body, date)
    }

    func cancelNotification(id: UUID) {
        let requestID = StickyNoteReminderRequestID.make(for: id)
        cancelledNotificationIDs.append(requestID)
        notifications[requestID] = nil
    }

    func cancelAllNotifications() {
        cancelAllNotificationsCount += 1
        notifications.removeAll()
    }

    func requestAuthorizationIfNeeded() {
        authorizationRequestCount += 1
    }
}

private final class FakeStickyNotePresenter: StickyNoteWindowPresenting {
    var shownNotes: [StickyNote] = []
    var focusedNotes: [StickyNote] = []
    var hiddenIDs: [UUID] = []
    var dismissedIDs: [UUID] = []
    private(set) var hideAllCount = 0
    private(set) var dismissAllCount = 0
    var frontedIDs: [UUID] = []

    /// 清空调用记录。
    func resetRecording() {
        shownNotes = []
        focusedNotes = []
        hiddenIDs = []
        dismissedIDs = []
        frontedIDs = []
    }

    func show(note: StickyNote) { shownNotes.append(note) }
    /// 覆盖协议默认实现：记录聚焦呈现调用（新建路径专用）。
    func showAndFocus(note: StickyNote) {
        focusedNotes.append(note)
        show(note: note)
    }
    func hide(id: UUID) { hiddenIDs.append(id) }
    func dismiss(id: UUID) { dismissedIDs.append(id) }
    func hideAll() { hideAllCount += 1 }
    func dismissAll() { dismissAllCount += 1 }
    func bringToFront(id: UUID) { frontedIDs.append(id) }
}

private final class FakeStickyNoteHotkeyClient: StickyNoteHotkeyClient {
    private(set) var setShortcutCalls: [KeyboardShortcuts.Shortcut?] = []
    private var keyUpHandler: (() -> Void)?

    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for name: KeyboardShortcuts.Name) {
        setShortcutCalls.append(shortcut)
    }

    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        keyUpHandler = action
    }

    /// 测试模拟按下快捷键。
    func fireKeyUp() {
        keyUpHandler?()
    }
}
