import Foundation

/// 编辑器快照（用于 undo/redo）。
///
/// 参照 capcap `EditorSnapshot`（`EditCanvasView.swift` L431-434）：
/// annotations 为值类型深拷贝，numberCounter 与标注一同回滚，保证
/// 下一个编号徽章在 undo/redo 后继续递增。
struct EditorSnapshot: Equatable {
    let annotations: [AnyAnnotation]
    let numberCounter: Int

    init(annotations: [AnyAnnotation], numberCounter: Int = 1) {
        self.annotations = annotations
        self.numberCounter = numberCounter
    }
}

/// 类型擦除的标注值类型。
///
/// 协议带有关联值/存在容器语义，无法直接进数组；用 `AnyAnnotation`
/// 包一层并按 `uuid` 判等，便于在快照数组中比较身份。
struct AnyAnnotation: Equatable {
    let annotation: Annotation

    var uuid: UUID { annotation.uuid }

    init(annotation: Annotation) {
        self.annotation = annotation
    }

    static func == (lhs: AnyAnnotation, rhs: AnyAnnotation) -> Bool {
        lhs.annotation.uuid == rhs.annotation.uuid
    }
}

/// 标注文档：管理对象栈 + undo/redo 快照。
///
/// 重写为 capcap 式三段式 undo（`EditCanvasView.swift` L416-538）：
/// - `recordUndo()`：瞬时变更前调用，压栈并清 redo。
/// - `captureUndoForPending()` / `commitPendingUndo()` / `discardPendingUndo()`：
///   拖拽式操作的三段式——按下时捕获、真正移动时提交、仅点击时丢弃。
/// - `undo()` / `redo()`：弹出栈顶并交换。
/// - 橡皮擦连续删除用 pending 机制 + `didDelete` 标志合并为单 undo 步。
///
/// 文档本身只持有标注数据与历史；选中状态、工具、绘图预览等交互态
/// 由 `AnnotationCanvasView` 维护，文档通过 `onHistoryStateChanged`
/// 把 undo/redo 可用性回传给画布/控制器。
@MainActor
final class AnnotationDocument {
    /// 当前标注栈（按绘制顺序，顶层在后）。
    private(set) var annotations: [AnyAnnotation] = []
    /// 下一个编号徽章的编号，与标注一同进入快照参与 undo/redo。
    private(set) var numberCounter: Int = 1

    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    /// 拖拽/文字编辑的待定快照。在变更开始前捕获，按下后若真正发生
    /// 改变则提交（`commitPendingUndo`），否则丢弃（`discardPendingUndo`）。
    private var pendingSnapshot: EditorSnapshot?

    /// undo/redo 可用性变化时触发，参数为 (canUndo, canRedo)。
    var onHistoryStateChanged: ((Bool, Bool) -> Void)?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    /// 是否有待定的拖拽/编辑快照尚未提交或丢弃。
    var hasPendingSnapshot: Bool { pendingSnapshot != nil }

    // MARK: - 直接变更（瞬时）

    /// 记录一个直接变更：压入当前快照并清空 redo 栈。
    /// 必须在任何**瞬时**变更（新增/删除/原子样式变更）**之前**调用。
    func recordUndo() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        notifyHistoryStateChanged()
    }

    /// 追加一个标注（调用方应先 `recordUndo()`）。
    func append(_ annotation: Annotation) {
        annotations.append(AnyAnnotation(annotation: annotation))
        syncNumberCounterAfterAdding(annotation)
    }

    /// 替换指定索引处的标注（用于原子样式变更、handle 拖拽提交）。
    /// 调用方负责 `recordUndo()` / `captureUndoForPending()` 的时机。
    func replace(at index: Int, with annotation: Annotation) {
        guard annotations.indices.contains(index) else { return }
        let original = annotations[index].annotation
        annotations[index] = AnyAnnotation(annotation: annotation)
        syncNumberCounterAfterMutation(from: original, to: annotation)
    }

    /// 删除指定索引集合的标注（逆序删除以保持索引稳定）。
    /// 调用方负责 `recordUndo()`。
    func remove(atIndexes indexes: [Int]) {
        for idx in indexes.sorted(by: >) where annotations.indices.contains(idx) {
            annotations.remove(at: idx)
        }
        resetNumberCounterIfNumberAnnotationsAreGone()
    }

    /// 清空全部标注。调用方负责 `recordUndo()`。
    func removeAllKeepingHistory() {
        annotations.removeAll()
        numberCounter = 1
    }

    // MARK: - 原位变更（保留既有 undo/redo 历史）

    /// 以下方法直接改写标注栈**但不触碰 undo/redo 栈**——用于在已
    /// `recordUndo()`/`captureUndoForPending()` 之后、由画布交互层
    /// 自行管理历史时机的批量操作（橡皮擦删除、文字编辑期间移除/
    /// 回插原标注）。调用方负责保证历史已被正确捕获。
    ///
    /// 用新栈整体替换（橡皮擦删除）。索引语义由调用方保证。
    func replaceAnnotationsPreservingHistory(_ newAnnotations: [AnyAnnotation]) {
        annotations = newAnnotations
    }

    /// 移除指定索引的标注（文字编辑开始时移除原标注）。
    func removeAnnotationsAtIndicesPreservingHistory(_ indexes: [Int]) {
        for idx in indexes.sorted(by: >) where annotations.indices.contains(idx) {
            annotations.remove(at: idx)
        }
    }

    /// 在指定索引插入标注（文字编辑 commit/cancel 回插或替换原标注）。
    func insertAnnotationAtPreservingHistory(_ annotation: Annotation, at index: Int) {
        let safeIdx = min(max(0, index), annotations.count)
        annotations.insert(AnyAnnotation(annotation: annotation), at: safeIdx)
    }

    /// 删除所有编号徽章后由画布触发，把计数器重置为 1。
    func resetNumberCounterIfNeeded() {
        if !annotations.contains(where: { $0.annotation is NumberAnnotation }) {
            numberCounter = 1
        }
    }

    // MARK: - 拖拽/编辑三段式

    /// 捕获当前状态为待定快照。用于拖拽、handle 拖拽、文字编辑等
    /// 「按下时不知是否会真正改变」的操作。与 `commitPendingUndo()`
    /// （真正改变）/ `discardPendingUndo()`（仅点击/取消）配对。
    func captureUndoForPending() {
        pendingSnapshot = currentSnapshot()
    }

    /// 提交待定快照到 undo 栈并清空 redo。拖拽真正移动、文字编辑
    /// 产生净变更时调用。
    func commitPendingUndo() {
        guard let snap = pendingSnapshot else { return }
        pendingSnapshot = nil
        undoStack.append(snap)
        redoStack.removeAll()
        notifyHistoryStateChanged()
    }

    /// 丢弃待定快照。点击未拖动、文字编辑取消时调用，避免无谓的
    /// undo 条目。
    func discardPendingUndo() {
        pendingSnapshot = nil
    }

    // MARK: - undo / redo

    /// 撤销一步。返回是否真的执行了撤销。
    @discardableResult
    func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(currentSnapshot())
        apply(prev)
        notifyHistoryStateChanged()
        return true
    }

    /// 重做一步。返回是否真的执行了重做。
    @discardableResult
    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(currentSnapshot())
        apply(next)
        notifyHistoryStateChanged()
        return true
    }

    // MARK: - 内部

    private func apply(_ snapshot: EditorSnapshot) {
        annotations = snapshot.annotations
        numberCounter = snapshot.numberCounter
    }

    private func currentSnapshot() -> EditorSnapshot {
        EditorSnapshot(annotations: annotations, numberCounter: numberCounter)
    }

    private func notifyHistoryStateChanged() {
        onHistoryStateChanged?(canUndo, canRedo)
    }

    /// 新增编号徽章后推进计数器。
    private func syncNumberCounterAfterAdding(_ annotation: Annotation) {
        guard let number = annotation as? NumberAnnotation else { return }
        numberCounter = max(numberCounter, number.number + 1)
    }

    /// 编号徽章编号被改变（+/- 步进）后推进计数器。
    private func syncNumberCounterAfterMutation(from original: Annotation, to updated: Annotation) {
        guard
            let oldNumber = original as? NumberAnnotation,
            let newNumber = updated as? NumberAnnotation,
            oldNumber.number != newNumber.number
        else { return }
        numberCounter = max(numberCounter, newNumber.number + 1)
    }

    /// 所有编号徽章都被删除后重置计数器为 1。
    private func resetNumberCounterIfNumberAnnotationsAreGone() {
        if !annotations.contains(where: { $0.annotation is NumberAnnotation }) {
            numberCounter = 1
        }
    }
}
