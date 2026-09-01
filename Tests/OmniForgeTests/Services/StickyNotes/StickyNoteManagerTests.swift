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

    // MARK: - 3.1 字号档位（状态栏 A-/A+）

    func test_nextFontSize_stepsBetweenAdjacentLevels() {
        var note = StickyNote(content: "a")
        note.fontSize = 13
        XCTAssertEqual(note.nextFontSize(larger: true), 15)
        XCTAssertEqual(note.nextFontSize(larger: false), 11)
        note.fontSize = 24
        XCTAssertNil(note.nextFontSize(larger: true), "最大档再升应返回 nil 供 UI 置灰")
        note.fontSize = 11
        XCTAssertNil(note.nextFontSize(larger: false), "最小档再降应返回 nil 供 UI 置灰")
    }

    func test_nextFontSize_alignsOffLevelValuesToNearestStep() {
        var note = StickyNote(content: "a")
        note.fontSize = 14
        XCTAssertEqual(note.nextFontSize(larger: true), 15, "间隙值升档到上沿")
        XCTAssertEqual(note.nextFontSize(larger: false), 13, "间隙值降档到下沿")
        note.fontSize = 30
        XCTAssertNil(note.nextFontSize(larger: true))
        XCTAssertEqual(note.nextFontSize(larger: false), 24, "超最大值降档收敛回最大档")
        note.fontSize = 5
        XCTAssertNil(note.nextFontSize(larger: false))
        XCTAssertEqual(note.nextFontSize(larger: true), 11, "低于最小值升档收敛回最小档")
    }

    func test_create_defaultsToStandardFontSize() {
        let manager = makeManager()

        let note = manager.create()!

        XCTAssertEqual(note.fontSize, StickyNote.defaultFontSize)
    }

    func test_adjustFontSize_stepsLevelPersistsAndSyncsWindow() {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()
        presenter.resetRecording()

        manager.adjustFontSize(id: note.id, larger: true)

        XCTAssertEqual(manager.notes[0].fontSize, 15)
        XCTAssertEqual(store.savedNotes.last?.fontSize, 15)
        XCTAssertEqual(presenter.shownNotes.last?.fontSize, 15, "字号变化需同步窗口刷新 NSTextView")

        manager.adjustFontSize(id: note.id, larger: false)
        XCTAssertEqual(manager.notes[0].fontSize, 13)
    }

    func test_adjustFontSize_clampsAtBoundariesWithoutPersisting() {
        let manager = makeManager()
        let note = manager.create()!
        store.resetRecording()

        for _ in 0..<10 { manager.adjustFontSize(id: note.id, larger: false) }
        XCTAssertEqual(manager.notes[0].fontSize, StickyNote.fontSizeSteps.first)
        for _ in 0..<10 { manager.adjustFontSize(id: note.id, larger: true) }
        XCTAssertEqual(manager.notes[0].fontSize, StickyNote.fontSizeSteps.last)

        // 有效步进仅 1 次降档（13→11）+ 5 次升档（→24）；边界 no-op 不落库
        XCTAssertEqual(store.saveCallCount, 6)
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

    func loadNotes() -> [StickyNote] { stubbedNotes }

    func saveNote(_ note: StickyNote) {
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
    var hiddenIDs: [UUID] = []
    var dismissedIDs: [UUID] = []
    private(set) var hideAllCount = 0
    private(set) var dismissAllCount = 0
    var frontedIDs: [UUID] = []

    /// 清空调用记录。
    func resetRecording() {
        shownNotes = []
        hiddenIDs = []
        dismissedIDs = []
        frontedIDs = []
    }

    func show(note: StickyNote) { shownNotes.append(note) }
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
