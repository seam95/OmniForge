import Foundation

/// 便签窗口呈现生产实现：按便签 id 持有窗口控制器（字典强引用，对齐贴图 Registry）。
@MainActor
final class StickyNoteWindowRegistry: StickyNoteWindowPresenting {
    /// Manager 在 Factory 装配完成后回填；weak 避免循环持有。
    weak var manager: StickyNoteManager?

    private let stringsProvider: () -> Strings
    private var controllers: [UUID: StickyNoteWindowController] = [:]

    init(stringsProvider: @escaping () -> Strings) {
        self.stringsProvider = stringsProvider
    }

    func show(note: StickyNote) {
        let controller = controller(for: note)
        controller.apply(note: note)
        controller.show()
    }

    func hide(id: UUID) {
        controllers[id]?.hide()
    }

    func dismiss(id: UUID) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.close()
    }

    func hideAll() {
        for controller in controllers.values {
            controller.hide()
        }
    }

    func dismissAll() {
        let all = controllers
        controllers.removeAll()
        for controller in all.values {
            controller.close()
        }
    }

    func bringToFront(id: UUID) {
        controllers[id]?.bringToFront()
    }

    /// 窗口侧动作集合：从 Manager 绑定；Manager 未就绪时安全降级为 no-op。
    private func makeActions() -> StickyNoteViewActions {
        guard let manager else { return .noop }
        return StickyNoteViewActions(
            onContentChanged: { id, content in
                manager.updateContent(id: id, content: content)
            },
            onColorSelected: { id, color in
                manager.setColor(id: id, color: color)
            },
            onTogglePin: { id in
                manager.togglePin(id: id)
            },
            onToggleCollapse: { id in
                manager.toggleCollapse(id: id)
            },
            onAdjustFontSize: { id, larger in
                manager.adjustFontSize(id: id, larger: larger)
            },
            onComplete: { id in
                manager.complete(id: id)
            },
            onCreateNew: {
                manager.create()
            },
            onSetReminder: { id, date in
                manager.setReminder(id: id, date: date)
            },
            onClearReminder: { id in
                manager.clearReminder(id: id)
            }
        )
    }

    private func controller(for note: StickyNote) -> StickyNoteWindowController {
        if let existing = controllers[note.id] {
            return existing
        }
        let actionsProvider = { [weak self] in
            self?.makeActions() ?? .noop
        }
        let controller = StickyNoteWindowController(
            note: note,
            actionsProvider: actionsProvider,
            stringsProvider: stringsProvider
        )
        controller.onFrameChanged = { [weak self] id, frame in
            self?.manager?.updateFrame(id: id, frame: frame)
        }
        controllers[note.id] = controller
        return controller
    }
}
